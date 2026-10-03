using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Cassandra;
using Microsoft.Extensions.Caching.Memory;
using RelationshipManager.Api.Data;

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
        public int Attempts { get; set; }
        public DateTimeOffset LastAttempt { get; set; }
    }

    private string Key(string ip) => clock.GetUtcNow().ToString("yyyy-MM-dd") + ":" +
        Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ip)));

    public async Task<int> RemainingAsync(string ip)
    {
        var state = await store.ReadAsync(Key(ip));
        return 3 - (state == null ? 0 : Parse(state).Count);
    }

    private static Dictionary<Guid, Dictionary<int, Segment>> Parse(string value) =>
        JsonSerializer.Deserialize<Dictionary<Guid, Dictionary<int, Segment>>>(value)!;

    public async Task<string?> ReserveAsync(string ip, Guid recordingId, int segment, byte[] audio, double seconds)
    {
        var key = Key(ip);
        var hash = Convert.ToHexString(SHA256.HashData(audio));
        for (var attempt = 0; attempt < 20; attempt++)
        {
            var previous = await store.ReadAsync(key);
            var state = previous == null ? new Dictionary<Guid, Dictionary<int, Segment>>() : Parse(previous);
            if (!state.TryGetValue(recordingId, out var recording))
            {
                if (state.Count >= 3) return "anonymous_daily_limit";
                recording = new Dictionary<int, Segment>();
                state.Add(recordingId, recording);
            }
            if (recording.TryGetValue(segment, out var existing))
            {
                if (existing.Hash != hash) return "invalid_recording_segment";
                if (existing.Attempts >= 4 && clock.GetUtcNow() - existing.LastAttempt < TimeSpan.FromMinutes(1)) return "too_many_requests";
                existing.Attempts = clock.GetUtcNow() - existing.LastAttempt >= TimeSpan.FromMinutes(1) ? 1 : existing.Attempts + 1;
                existing.LastAttempt = clock.GetUtcNow();
            }
            else
            {
                if (recording.Values.Sum(s => s.Seconds) + seconds > 60.000001) return "anonymous_recording_too_long";
                recording.Add(segment, new Segment { Hash = hash, Seconds = seconds, Attempts = 1, LastAttempt = clock.GetUtcNow() });
            }
            if (await store.CompareExchangeAsync(key, previous, JsonSerializer.Serialize(state))) return null;
        }
        throw new InvalidOperationException("The recording quota is temporarily busy.");
    }

    private string ResultKey(string ip, Guid recordingId, int segment, byte[] audio, string? language) =>
        Key(ip) + ":" + recordingId + ":" + segment + ":" + Convert.ToHexString(SHA256.HashData(audio)) + ":" + language;

    // Results are kept only in bounded volatile memory; transcripts are never written to Cassandra.
    public string? CachedText(string ip, Guid recordingId, int segment, byte[] audio, string? language) =>
        _results.Get<string>(ResultKey(ip, recordingId, segment, audio, language));

    public void CacheText(string ip, Guid recordingId, int segment, byte[] audio, string? language, string text) =>
        _results.Set(ResultKey(ip, recordingId, segment, audio, language), text,
            new MemoryCacheEntryOptions { Size = Math.Max(1, text.Length), AbsoluteExpirationRelativeToNow = TimeSpan.FromMinutes(15) });

    // Anonymous audio must carry a verifiable PCM WAV duration; claimed client durations are never trusted.
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
