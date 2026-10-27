using System.Text;
using System.Text.RegularExpressions;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Services;

/// <summary>Physical packing only: each logical object keeps its existing authenticated ciphertext.</summary>
public class PackedSyncService(SyncService sync, IS3Service storage, IConfiguration configuration)
{
    public const int MaxEntries = 128;
    public const int MaxPayloadBytes = 4 * 1024 * 1024;
    private static readonly UTF8Encoding StrictUtf8 = new(false, true);

    public SyncBatchingCapabilities Capabilities => new()
    {
        CanUploadPacks = configuration.GetValue<bool>("Sync:PackingEnabled") &&
            PackTickets.TryGetOrigin(configuration, out _) && !string.IsNullOrEmpty(configuration["jwt:secret"])
    };

    private static void ValidateEntries<T>(List<T>? entries) where T : PackedDownloadRequestEntry
    {
        if (entries == null || entries.Count == 0 || entries.Count > MaxEntries)
            throw new ArgumentException("A batch must contain between 1 and 128 entries.");
        var identities = new HashSet<(string, string)>();
        foreach (var entry in entries)
        {
            if (entry == null || entry.BlobType is not ("person" or "place" or "object" or "connection"))
                throw new ArgumentException("Only individual metadata objects can be batched.");
            SyncService.GetBlobKey(Guid.Empty, entry.BlobType, entry.BlobId ?? "");
            if (!identities.Add((entry.BlobType, entry.BlobId!)))
                throw new ArgumentException("Batch identities must be unique.");
        }
    }

    public async Task UploadAsync(Guid owner, PackedUploadRequest request)
    {
        if (!Capabilities.CanUploadPacks) throw new InvalidOperationException("packing_disabled");
        ValidateEntries(request.Entries);
        // Validate the complete manifest before writing any bytes or logical commits.
        using var pack = new MemoryStream();
        var commits = new List<CommitEntry>();
        var packId = Guid.NewGuid().ToString("N");
        foreach (var entry in request.Entries)
        {
            if (!Regex.IsMatch(entry.Checksum ?? "", @"\A[0-9a-fA-F]{64}\z") ||
                entry.Data == null || !entry.Data.StartsWith("con:v1:", StringComparison.Ordinal) ||
                entry.Data.Length > MaxPayloadBytes)
                throw new ArgumentException("Each entry requires a checksum and an authenticated v1 ciphertext.");
            byte[] envelope;
            try { envelope = Convert.FromBase64String(entry.Data[7..]); }
            catch (FormatException) { throw new ArgumentException("Invalid ciphertext encoding."); }
            if (envelope.Length < 28 || Convert.ToBase64String(envelope) != entry.Data[7..])
                throw new ArgumentException("Invalid ciphertext envelope.");
            var data = StrictUtf8.GetBytes(entry.Data);
            if (pack.Length + data.Length > MaxPayloadBytes)
                throw new ArgumentException("Batch payload exceeds 4 MiB.");
            commits.Add(new CommitEntry
            {
                BlobType = entry.BlobType, BlobId = entry.BlobId,
                S3Key = new PackReference(packId, pack.Length, data.Length).ToString(),
                Checksum = entry.Checksum!, Size = data.Length, IsDeleted = entry.IsDeleted
            });
            await pack.WriteAsync(data);
        }
        pack.Position = 0;
        await storage.UploadAsync(new PackReference(packId, 0, pack.Length).PhysicalKey(owner), pack);
        // Publication is deliberately acknowledged only after every commit succeeds. A failed
        // request may have committed a prefix; callers retain all captured pending rows for retry.
        foreach (var commit in commits)
        {
            await sync.CommitPackedUploadAsync(owner, commit);
            // Let the real millisecond advance before publishing the next entry or returning.
            // A reader can observe a committed prefix and uses a strictly-greater cursor.
            var publishedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            do { await Task.Delay(1); }
            while (DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() <= publishedAt);
        }
    }

    public async Task<PackedDownloadResponse> DownloadAsync(Guid owner, PackedDownloadRequest request)
    {
        ValidateEntries(request.Entries);
        var response = new PackedDownloadResponse();
        var inline = new List<(SyncEntry Object, PackedDownloadEntry Response)>();
        long remaining = MaxPayloadBytes;
        foreach (var requested in request.Entries)
        {
            var current = await sync.GetEntryAsync(owner, requested.BlobType, requested.BlobId)
                ?? throw new KeyNotFoundException("A requested object no longer exists.");
            var result = new PackedDownloadEntry
            {
                BlobType = current.BlobType, BlobId = current.BlobId,
                Version = current.Version, IsDeleted = current.IsDeleted
            };
            response.Entries.Add(result);
            if (current.IsDeleted) continue;
            if (current.Size <= 0 || current.Size > remaining)
            {
                result.DownloadUrl = (await sync.GetDownloadUrlAsync(owner, current.BlobType, current.BlobId))?.DownloadUrl
                    ?? throw new KeyNotFoundException("A requested object no longer exists.");
                continue;
            }
            remaining -= current.Size;
            inline.Add((current, result));
        }
        // Read a physical pack once even when several requested logical objects share it.
        foreach (var group in inline.GroupBy(item => PackReference.TryParse(item.Object.S3Key, out var reference)
                     ? reference.PhysicalKey(owner) : item.Object.S3Key))
        {
            await using var source = await storage.DownloadAsync(group.Key)
                ?? throw new KeyNotFoundException("Blob data is missing.");
            var packed = PackReference.TryParse(group.First().Object.S3Key, out _);
            var bytes = await ReadBoundedAsync(source, packed ? MaxPayloadBytes : checked((int)group.First().Object.Size));
            foreach (var (current, result) in group)
            {
                if (PackReference.TryParse(current.S3Key, out var reference))
                {
                    if (reference.Offset + reference.Length > bytes.Length || reference.Length != current.Size)
                        throw new InvalidDataException("Packed object bounds do not match storage.");
                    result.Data = StrictUtf8.GetString(bytes, checked((int)reference.Offset), checked((int)reference.Length));
                }
                else
                {
                    if (bytes.Length != current.Size) throw new InvalidDataException("Object size does not match storage.");
                    result.Data = StrictUtf8.GetString(bytes);
                }
            }
        }
        return response;
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream source, int limit)
    {
        using var result = new MemoryStream();
        var buffer = new byte[81920];
        while (true)
        {
            var count = await source.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, limit + 1 - (int)result.Length)));
            if (count == 0) return result.ToArray();
            result.Write(buffer, 0, count);
            if (result.Length > limit) throw new InvalidDataException("Blob exceeds its download limit.");
        }
    }

    public Task<Stream?> DownloadTicketAsync(string ticket)
    {
        if (!PackTickets.TryRead(ticket, configuration["jwt:secret"] ?? "", DateTimeOffset.UtcNow,
                out var owner, out var reference)) return Task.FromResult<Stream?>(null);
        return storage.DownloadRangeAsync(reference.PhysicalKey(owner), reference.Offset, reference.Length);
    }
}
