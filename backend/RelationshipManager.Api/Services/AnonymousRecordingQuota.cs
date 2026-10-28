using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Cassandra;
using Microsoft.Extensions.Caching.Memory;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Services;

public interface IAnonymousQuotaStore
{
    Task<string?> ReadAsync(string key);
    Task<bool> CompareExchangeAsync(string key, string? previous, string next);
}

public sealed class CassandraAnonymousQuotaStore(ICassandraConnection connection) : IAnonymousQuotaStore
{
    private Task? _schema;
    private Task Schema => _schema ??= connection.Session.ExecuteAsync(new SimpleStatement(
        "CREATE TABLE IF NOT EXISTS anonymous_recording_quota (id text PRIMARY KEY, state text) WITH default_time_to_live = 172800"));

    public async Task<string?> ReadAsync(string key)
    {
        await Schema;
        var rows = await connection.Session.ExecuteAsync(new SimpleStatement("SELECT state FROM anonymous_recording_quota WHERE id = ?", key));
        return rows.FirstOrDefault()?.GetValue<string>("state");
    }

    public async Task<bool> CompareExchangeAsync(string key, string? previous, string next)
    {
        await Schema;
        var statement = previous == null
            ? new SimpleStatement("INSERT INTO anonymous_recording_quota (id, state) VALUES (?, ?) IF NOT EXISTS", key, next)
            : new SimpleStatement("UPDATE anonymous_recording_quota SET state = ? WHERE id = ? IF state = ?", next, key, previous);
        var rows = await connection.Session.ExecuteAsync(statement);
        return rows.First().GetValue<bool>("[applied]");
    }
}

public sealed class AnonymousRecordingQuota(IAnonymousQuotaStore store, TimeProvider clock) : IDisposable
{
    private readonly MemoryCache _results = new(new MemoryCacheOptions { SizeLimit = 1_000_000 });

    public void Dispose() => _results.Dispose();

    public sealed class Segment
    {
        public string Hash { get; set; } = "";
        public double Seconds { get; set; }
        // Entries from the former ledger already consumed quota and have no pending token.
        public Guid? PendingToken { get; set; }
        public DateTimeOffset PendingUntil { get; set; }
        public int Attempts { get; set; }
        public DateTimeOffset LastAttempt { get; set; }
    }

    public sealed record Reservation(string Key, Guid RecordingId, int Sequence, Guid? Token);
    public sealed record ReservationResult(string? Error, Reservation? Reservation);

    private string Key(string identity, DateTimeOffset? at = null) => (at ?? clock.GetUtcNow()).ToString("yyyy-MM-dd") + ":" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));

    private Dictionary<Guid, Dictionary<int, Segment>> Parse(string? value)
    {
        var state = value == null ? new Dictionary<Guid, Dictionary<int, Segment>>() :
            JsonSerializer.Deserialize<Dictionary<Guid, Dictionary<int, Segment>>>(value)!;
        foreach (var recording in state.Values)
            foreach (var sequence in recording.Where(s => s.Value.PendingToken != null && s.Value.PendingUntil <= clock.GetUtcNow()).Select(s => s.Key).ToArray())
                recording.Remove(sequence);
        foreach (var id in state.Where(r => r.Value.Count == 0).Select(r => r.Key).ToArray()) state.Remove(id);
        return state;
    }

    public async Task<TranscriptionStatus> StatusAsync(string identity, int limit)
    {
        var now = clock.GetUtcNow();
        var segments = Parse(await store.ReadAsync(Key(identity, now))).Values.SelectMany(r => r.Values).ToArray();
        return new TranscriptionStatus
        {
            UsedSeconds = segments.Where(s => s.PendingToken == null).Sum(s => s.Seconds),
            RemainingSeconds = Math.Max(0, limit - segments.Sum(s => s.Seconds)),
            DailyLimitSeconds = limit,
            WarningAfterSeconds = limit == 300 ? 180 : null,
            ResetAt = new DateTimeOffset(now.UtcDateTime.Date.AddDays(1), TimeSpan.Zero)
        };
    }

    public async Task<ReservationResult> ReserveAsync(string identity, int limit, Guid recordingId, int segment, byte[] audio, double seconds)
    {
        var key = Key(identity);
        var hash = Convert.ToHexString(SHA256.HashData(audio));
        for (var attempt = 0; attempt < 20; attempt++)
        {
            var previous = await store.ReadAsync(key);
            var state = Parse(previous);
            if (!state.TryGetValue(recordingId, out var recording))
                state.Add(recordingId, recording = new Dictionary<int, Segment>());
            if (recording.TryGetValue(segment, out var existing))
            {
                if (existing.Hash != hash) return new("invalid_recording_segment", null);
                if (existing.PendingToken != null) return new("recording_segment_busy", null);
                var recent = clock.GetUtcNow() - existing.LastAttempt < TimeSpan.FromMinutes(1);
                if (recent && existing.Attempts >= 4) return new("too_many_requests", null);
                existing.Attempts = recent ? existing.Attempts + 1 : 1;
                existing.LastAttempt = clock.GetUtcNow();
                if (await store.CompareExchangeAsync(key, previous, JsonSerializer.Serialize(state)))
                    return new(null, new Reservation(key, recordingId, segment, null));
                continue;
            }
            var segments = state.Values.SelectMany(r => r.Values).ToArray();
            if (segments.Length >= 4096) return new("recording_segment_limit", null);
            if (segments.Sum(s => s.Seconds) + seconds > limit + 0.000001)
                return new(limit == 300 ? "anonymous_daily_limit" : "transcription_daily_limit", null);
            var token = Guid.NewGuid();
            recording.Add(segment, new Segment { Hash = hash, Seconds = seconds, PendingToken = token,
                PendingUntil = clock.GetUtcNow().AddMinutes(5), Attempts = 1, LastAttempt = clock.GetUtcNow() });
            if (await store.CompareExchangeAsync(key, previous, JsonSerializer.Serialize(state)))
                return new(null, new Reservation(key, recordingId, segment, token));
        }
        throw new InvalidOperationException("The recording quota is temporarily busy.");
    }

    public Task CompleteAsync(Reservation reservation) => FinishAsync(reservation, complete: true);
    public Task ReleaseAsync(Reservation reservation) => FinishAsync(reservation, complete: false);

    private async Task FinishAsync(Reservation reservation, bool complete)
    {
        if (reservation.Token == null) return; // A completed retry never charges a second time.
        for (var attempt = 0; attempt < 20; attempt++)
        {
            var previous = await store.ReadAsync(reservation.Key);
            var state = Parse(previous);
            if (!state.TryGetValue(reservation.RecordingId, out var recording) ||
                !recording.TryGetValue(reservation.Sequence, out var entry) || entry.PendingToken != reservation.Token)
            {
                if (complete) throw new InvalidOperationException("The recording reservation expired.");
                return;
            }
            if (complete) entry.PendingToken = null;
            else recording.Remove(reservation.Sequence);
            if (await store.CompareExchangeAsync(reservation.Key, previous, JsonSerializer.Serialize(state))) return;
        }
        throw new InvalidOperationException("The recording quota is temporarily busy.");
    }

    private static string ResultKey(string key, Guid recordingId, int segment, byte[] audio, string? language, string? initialPrompt) =>
        key + ":" + recordingId + ":" + segment + ":" + Convert.ToHexString(SHA256.HashData(audio)) + ":" + language + ":" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(initialPrompt ?? "")));

    // Results are kept only in bounded volatile memory; transcripts are never written to Cassandra.
    public string? CachedText(string identity, Guid recordingId, int segment, byte[] audio, string? language, string? initialPrompt = null) =>
        _results.Get<string>(ResultKey(Key(identity), recordingId, segment, audio, language, initialPrompt));

    public void CacheText(Reservation reservation, byte[] audio, string? language, string text, string? initialPrompt = null) =>
        _results.Set(ResultKey(reservation.Key, reservation.RecordingId, reservation.Sequence, audio, language, initialPrompt), text,
            new MemoryCacheEntryOptions { Size = Math.Max(1, text.Length), AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(15) });

    // Every upload must carry a verifiable PCM WAV duration; claimed client durations are never trusted.
    public static double? WavSeconds(byte[] bytes)
    {
        if (bytes.Length < 44 || Encoding.ASCII.GetString(bytes, 0, 4) != "RIFF" ||
            Encoding.ASCII.GetString(bytes, 8, 4) != "WAVE" || BitConverter.ToUInt32(bytes, 4) != bytes.Length - 8) return null;
        uint byteRate = 0;
        ushort blockAlign = 0;
        int? dataBytes = null;
        var offset = 12;
        while (offset + 8 <= bytes.Length)
        {
            var length = BitConverter.ToUInt32(bytes, offset + 4);
            if (length > bytes.Length - offset - 8) return null;
            var name = Encoding.ASCII.GetString(bytes, offset, 4);
            if (name == "fmt ")
            {
                if (length < 16 || byteRate != 0 || BitConverter.ToUInt16(bytes, offset + 8) != 1) return null;
                var channels = BitConverter.ToUInt16(bytes, offset + 10);
                var sampleRate = BitConverter.ToUInt32(bytes, offset + 12);
                byteRate = BitConverter.ToUInt32(bytes, offset + 16);
                blockAlign = BitConverter.ToUInt16(bytes, offset + 20);
                var bits = BitConverter.ToUInt16(bytes, offset + 22);
                if (channels is < 1 or > 2 || sampleRate is < 8000 or > 192000 || bits is not (8 or 16 or 24 or 32) ||
                    blockAlign != channels * bits / 8 || byteRate != sampleRate * blockAlign) return null;
            }
            if (name == "data")
            {
                if (dataBytes != null) return null;
                dataBytes = (int)length;
            }
            offset += 8 + (int)length + (int)(length % 2);
            if (offset > bytes.Length) return null;
        }
        return offset == bytes.Length && byteRate > 0 && dataBytes > 0 && dataBytes % blockAlign == 0 ? dataBytes / (double)byteRate : null;
    }
}
