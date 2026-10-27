using System.Text;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;
using RelationshipManager.Api.Services;
using RelationshipManager.Api.Tests.Fakes;

namespace RelationshipManager.Api.Tests;

public class PackedSyncServiceTests
{
    private readonly Guid _owner = Guid.NewGuid();
    private InMemorySyncStore _store = null!;
    private MemoryStorage _storage = null!;
    private IConfigurationRoot _configuration = null!;
    private SyncService _sync = null!;
    private PackedSyncService _service = null!;

    [SetUp]
    public void SetUp()
    {
        _store = new();
        _storage = new();
        _configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Sync:PackingEnabled"] = "true", ["jwt:issuer"] = "https://api.example.test",
            ["jwt:secret"] = "test-only-pack-ticket-secret-at-least-32-characters"
        }).Build();
        _sync = new(_store, _storage, NullLogger<SyncService>.Instance, _configuration);
        _service = new(_sync, _storage, _configuration);
    }

    private static PackedUploadEntry Entry(string id, string type = "person", int payloadSize = 40) => new()
    {
        BlobType = type, BlobId = id, Checksum = new string('a', 64),
        Data = "con:v1:" + Convert.ToBase64String(Enumerable.Repeat((byte)id[0], payloadSize).ToArray())
    };

    private static PackedDownloadRequest Request(params PackedUploadEntry[] entries) => new()
    {
        Entries = entries.Select(e => new PackedDownloadRequestEntry { BlobType = e.BlobType, BlobId = e.BlobId }).ToList()
    };

    [Test]
    public async Task UploadStoresOnePhysicalPackAndLogicalObjectsDownloadWithOneGet()
    {
        var a = Entry("alice");
        var b = Entry("berlin", "place");
        await _service.UploadAsync(_owner, new() { Entries = [a, b] });
        Assert.That(_storage.Objects, Has.Count.EqualTo(1));
        Assert.That(_storage.Uploads, Is.EqualTo(1));
        var physical = _storage.Objects.Single();
        Assert.That(physical.Key, Does.StartWith($"{_owner}/.packs/v1/"));
        Assert.That(Encoding.UTF8.GetString(physical.Value), Is.EqualTo(a.Data + b.Data));
        Assert.That(await _store.GetUserObjectsAsync(_owner), Has.Count.EqualTo(2));
        Assert.That((await _store.GetStorageLimitAsync(_owner))!.UsedBytes, Is.EqualTo(a.Data.Length + b.Data.Length));
        var downloaded = await _service.DownloadAsync(_owner, Request(a, b));
        Assert.That(_storage.Downloads, Is.EqualTo(1));
        Assert.That(downloaded.Entries.Select(e => e.Data), Is.EqualTo(new[] { a.Data, b.Data }));
        Assert.That(downloaded.Entries.All(e => e.Version > 0), Is.True);
    }

    [Test]
    public async Task PackedCommitVersionsAdvancePastAnyObservedPrefixCursor()
    {
        await _service.UploadAsync(_owner, new() { Entries = [Entry("alice"), Entry("berlin"), Entry("charlie")] });
        var entries = (await _store.GetSyncEntriesAsync(_owner)).OrderBy(e => e.Version).ToList();
        Assert.That(entries.Select(e => e.Version).Distinct().Count(), Is.EqualTo(3));
        var updates = await _sync.GetUpdatesAsync(_owner, new() { LastSyncVersion = entries[0].Version });
        Assert.That(updates.Entries.Select(e => e.BlobId), Is.EquivalentTo(entries.Skip(1).Select(e => e.BlobId)));
        Assert.That(entries.Last().Version, Is.LessThan(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()));
    }

    [Test]
    public async Task ExistingSingleBlobReaderGetsExactTicketSliceEvenWhenUploadsDisabled()
    {
        var a = Entry("alice");
        var b = Entry("berlin", "place");
        await _service.UploadAsync(_owner, new() { Entries = [a, b] });
        _configuration["Sync:PackingEnabled"] = "false";
        Assert.That(_service.Capabilities.CanUploadPacks, Is.False);
        var url = (await _sync.GetDownloadUrlAsync(_owner, b.BlobType, b.BlobId))!.DownloadUrl;
        Assert.That(url, Does.StartWith("https://api.example.test/api/sync/packed/"));
        await using var stream = await _service.DownloadTicketAsync(new Uri(url).Segments.Last());
        Assert.That(await new StreamReader(stream!).ReadToEndAsync(), Is.EqualTo(b.Data));
        Assert.That(await _service.DownloadTicketAsync("bad-ticket"), Is.Null);
        Assert.ThrowsAsync<KeyNotFoundException>(() => _service.DownloadAsync(Guid.NewGuid(), Request(a)));
        Assert.That(_storage.Downloads, Is.Zero, "A missing owned record must not read another owner's storage.");
    }

    [Test]
    public async Task TombstonesAndExistingLegacyObjectsRemainReadable()
    {
        var deleted = Entry("alice");
        deleted.IsDeleted = true;
        await _service.UploadAsync(_owner, new() { Entries = [deleted] });
        var legacy = Entry("berlin", "place");
        var key = $"{_owner}/place/berlin_123";
        _storage.Objects[key] = Encoding.UTF8.GetBytes(legacy.Data);
        await _sync.CommitUploadAsync(_owner, new()
        {
            BlobType = legacy.BlobType, BlobId = legacy.BlobId, S3Key = key, Size = legacy.Data.Length
        });
        var result = await _service.DownloadAsync(_owner, Request(deleted, legacy));
        Assert.That(result.Entries[0].IsDeleted, Is.True);
        Assert.That(result.Entries[0].Data, Is.Null);
        Assert.That(result.Entries[1].Data, Is.EqualTo(legacy.Data));
        Assert.That(_storage.Downloads, Is.EqualTo(1));
    }

    [TestCase("duplicate")]
    [TestCase("type")]
    [TestCase("id")]
    [TestCase("checksum")]
    [TestCase("encoding")]
    [TestCase("prefix")]
    [TestCase("truncated")]
    [TestCase("count")]
    [TestCase("size")]
    [TestCase("cumulative")]
    public void InvalidManifestNeverWritesEvenWhenFirstEntryIsValid(string failure)
    {
        var a = Entry("alice");
        var b = Entry("berlin");
        var entries = new List<PackedUploadEntry> { a, b };
        switch (failure)
        {
            case "duplicate": b.BlobId = a.BlobId; break;
            case "type": b.BlobType = "event_month"; break;
            case "id": b.BlobId = "../other"; break;
            case "checksum": b.Checksum = "abc"; break;
            case "encoding": b.Data = "con:v1:not-base64"; break;
            case "prefix": b.Data = "plaintext"; break;
            case "truncated": b.Data = "con:v1:" + Convert.ToBase64String(new byte[27]); break;
            case "count": entries = Enumerable.Range(0, 129).Select(i => Entry($"p{i}")).ToList(); break;
            case "cumulative":
                entries = [Entry("alice", payloadSize: 2 * 1024 * 1024), Entry("berlin", payloadSize: 2 * 1024 * 1024)];
                break;
            case "size": b.Data = "con:v1:" + Convert.ToBase64String(new byte[PackedSyncService.MaxPayloadBytes]); break;
        }
        Assert.ThrowsAsync<ArgumentException>(() => _service.UploadAsync(_owner, new() { Entries = entries }));
        Assert.That(_storage.Objects, Is.Empty);
        Assert.That(_store.GetUserObjectsAsync(_owner).Result, Is.Empty);
    }

    [Test]
    public void UploadsNeedExplicitFlagAndCanonicalOrigin()
    {
        foreach (var (key, value) in new[] { ("Sync:PackingEnabled", "false"), ("jwt:issuer", "issuer-without-origin") })
        {
            SetUp();
            _configuration[key] = value;
            Assert.That(_service.Capabilities.CanUploadPacks, Is.False);
            Assert.ThrowsAsync<InvalidOperationException>(() => _service.UploadAsync(_owner, new() { Entries = [Entry("alice")] }));
            Assert.That(_storage.Objects, Is.Empty);
        }
    }

    [Test]
    public async Task OversizedLegacyBlobUsesUrlWithoutDownloadingItsBytes()
    {
        await _store.UpsertUserObjectAsync(new()
        {
            UserId = _owner, BlobType = "person", BlobId = "big", S3Key = $"{_owner}/person/big_123",
            Size = PackedSyncService.MaxPayloadBytes + 1, Version = 123
        });
        var result = await _service.DownloadAsync(_owner, Request(Entry("big")));
        Assert.That(result.Entries[0].Data, Is.Null);
        Assert.That(result.Entries[0].DownloadUrl, Does.StartWith("https://storage.test/"));
        Assert.That(_storage.Downloads, Is.Zero);
    }

    [Test]
    public async Task CumulativeInlineBudgetFallsBackToUrlWithoutReadingSecondPack()
    {
        var a = Entry("alice", payloadSize: 2 * 1024 * 1024);
        var b = Entry("berlin", payloadSize: 2 * 1024 * 1024);
        await _service.UploadAsync(_owner, new() { Entries = [a] });
        await _service.UploadAsync(_owner, new() { Entries = [b] });
        var result = await _service.DownloadAsync(_owner, Request(a, b));
        Assert.That(result.Entries[0].Data, Is.EqualTo(a.Data));
        Assert.That(result.Entries[1].Data, Is.Null);
        Assert.That(result.Entries[1].DownloadUrl, Does.StartWith("https://api.example.test/api/sync/packed/"));
        Assert.That(_storage.Downloads, Is.EqualTo(1));
    }

    [Test]
    public async Task TruncatedPackCannotProducePartialResponse()
    {
        var a = Entry("alice");
        var b = Entry("berlin");
        await _service.UploadAsync(_owner, new() { Entries = [a, b] });
        var key = _storage.Objects.Keys.Single();
        _storage.Objects[key] = _storage.Objects[key][..^1];
        Assert.ThrowsAsync<InvalidDataException>(() => _service.DownloadAsync(_owner, Request(a, b)));
    }

    [Test]
    public async Task StorageFailureDoesNotPublishLogicalObjects()
    {
        _storage.FailUpload = true;
        Assert.ThrowsAsync<S3UnavailableException>(() => _service.UploadAsync(_owner, new() { Entries = [Entry("alice")] }));
        Assert.That(await _store.GetUserObjectsAsync(_owner), Is.Empty);
    }

    [TestCase(100)]
    [TestCase(128)]
    public async Task FullMetadataBatchUsesOnePhysicalPut(int count)
    {
        await _service.UploadAsync(_owner, new() { Entries = Enumerable.Range(0, count).Select(i => Entry($"p{i}")).ToList() });
        Assert.That(_storage.Objects, Has.Count.EqualTo(1));
        Assert.That(_storage.Uploads, Is.EqualTo(1));
        Assert.That(await _store.GetUserObjectsAsync(_owner), Has.Count.EqualTo(count));
    }

    [Test]
    public async Task PublicationFailureThrowsAfterPrefixAndRetryPublishesEveryObject()
    {
        _store = new FailingSecondCommitStore();
        _sync = new(_store, _storage, NullLogger<SyncService>.Instance, _configuration);
        _service = new(_sync, _storage, _configuration);
        var request = new PackedUploadRequest { Entries = [Entry("alice"), Entry("berlin")] };
        Assert.ThrowsAsync<InvalidOperationException>(() => _service.UploadAsync(_owner, request));
        Assert.That((await _store.GetUserObjectsAsync(_owner)).Select(e => e.BlobId), Is.EqualTo(new[] { "alice" }));
        await _service.UploadAsync(_owner, request);
        Assert.That(await _store.GetUserObjectsAsync(_owner), Has.Count.EqualTo(2));
        Assert.That((await _store.GetStorageLimitAsync(_owner))!.UsedBytes,
            Is.EqualTo(request.Entries.Sum(e => e.Data.Length)), "Retry must not double-count existing logical bytes.");
    }

    private sealed class FailingSecondCommitStore : InMemorySyncStore, ISyncStore
    {
        private int _inserts;
        Task ISyncStore.InsertSyncEntryAsync(SyncEntry entry)
            => ++_inserts == 2 ? throw new InvalidOperationException("test commit failed") : InsertSyncEntryAsync(entry);
    }

    internal sealed class MemoryStorage : IS3Service
    {
        public Dictionary<string, byte[]> Objects { get; } = new();
        public int Downloads { get; private set; }
        public int Uploads { get; private set; }
        public bool FailUpload { get; set; }
        public bool IsConfigured => true;
        public Task<string> GetUploadUrlAsync(string key, TimeSpan expiry) => Task.FromResult("https://storage.test/" + key);
        public Task<string> GetDownloadUrlAsync(string key, TimeSpan expiry) => Task.FromResult("https://storage.test/" + key);
        public Task DeleteObjectAsync(string key) { Objects.Remove(key); return Task.CompletedTask; }
        public Task<bool> ObjectExistsAsync(string key) => Task.FromResult(Objects.ContainsKey(key));
        public Task<long> GetObjectSizeAsync(string key) => Task.FromResult((long)Objects[key].Length);
        public async Task UploadAsync(string key, Stream data, string contentType = "application/octet-stream")
        {
            if (FailUpload) throw new S3UnavailableException("test storage unavailable");
            Uploads++;
            using var buffer = new MemoryStream();
            await data.CopyToAsync(buffer);
            Objects[key] = buffer.ToArray();
        }
        public Task<Stream?> DownloadAsync(string key)
        {
            Downloads++;
            return Task.FromResult<Stream?>(Objects.TryGetValue(key, out var bytes) ? new MemoryStream(bytes) : null);
        }
        public Task<Stream?> DownloadRangeAsync(string key, long offset, long length)
            => Task.FromResult<Stream?>(Objects.TryGetValue(key, out var bytes)
                ? new MemoryStream(bytes.AsSpan((int)offset, (int)length).ToArray()) : null);
    }
}
