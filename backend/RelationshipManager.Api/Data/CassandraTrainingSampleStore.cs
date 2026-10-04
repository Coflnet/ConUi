using System.Text.Json;
using Cassandra;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Data;

public sealed class CassandraTrainingSampleStore : ITrainingSampleStore
{
    private const int ChunkSize = 256 * 1024;
    private readonly ICassandraConnection _connection;
    private readonly Lazy<Task> _schema;

    public CassandraTrainingSampleStore(ICassandraConnection connection)
    {
        _connection = connection;
        _schema = new Lazy<Task>(async () =>
        {
            await Execute("CREATE TABLE IF NOT EXISTS training_samples (day text, id uuid, metadata text, audio_id uuid, PRIMARY KEY (day, id))");
            await Execute("CREATE TABLE IF NOT EXISTS training_sample_audio (upload_id uuid, chunk int, data blob, PRIMARY KEY (upload_id, chunk))");
        });
    }

    private Task<RowSet> Execute(string query, params object[] values) =>
        _connection.Session.ExecuteAsync(new SimpleStatement(query, values).SetConsistencyLevel(ConsistencyLevel.Quorum).SetSerialConsistencyLevel(ConsistencyLevel.Serial));

    private async Task<Row?> RowAsync(string date, Guid id)
    {
        await _schema.Value;
        // Resolve any in-progress publication before deciding whether its chunks are unused.
        return (await _connection.Session.ExecuteAsync(new SimpleStatement(
            "SELECT metadata, audio_id FROM training_samples WHERE day = ? AND id = ?", date, id)
            .SetConsistencyLevel(ConsistencyLevel.Serial))).FirstOrDefault();
    }

    private static TrainingSample Sample(Row row) => JsonSerializer.Deserialize<TrainingSample>(row.GetValue<string>("metadata"))!;

    public async Task<TrainingSample?> GetAsync(string date, Guid id)
    {
        var row = await RowAsync(date, id);
        return row == null ? null : Sample(row);
    }

    public async Task<TrainingSample> PublishAsync(TrainingSample sample, byte[]? audio)
    {
        await _schema.Value;
        var uploadId = Guid.NewGuid();
        var published = false;
        try
        {
            if (audio != null)
                for (var offset = 0; offset < audio.Length; offset += ChunkSize)
                    await Execute("INSERT INTO training_sample_audio (upload_id, chunk, data) VALUES (?, ?, ?)",
                        uploadId, offset / ChunkSize, audio[offset..Math.Min(audio.Length, offset + ChunkSize)]);
            var rows = await Execute("INSERT INTO training_samples (day, id, metadata, audio_id) VALUES (?, ?, ?, ?) IF NOT EXISTS",
                sample.Date, sample.Id, JsonSerializer.Serialize(sample), uploadId);
            published = rows.First().GetValue<bool>("[applied]");
            if (published) return sample;
            return await GetAsync(sample.Date, sample.Id) ?? throw new InvalidOperationException("Sample publication was interrupted.");
        }
        catch
        {
            // A timeout may have followed a successful LWT. Do not erase its audio.
            published = true; // Preserve audio if publication status cannot be checked.
            var current = await RowAsync(sample.Date, sample.Id);
            published = current?.GetValue<Guid>("audio_id") == uploadId;
            throw;
        }
        finally
        {
            if (!published) await Execute("DELETE FROM training_sample_audio WHERE upload_id = ?", uploadId);
        }
    }

    public async Task<TrainingSamplePage> ListAsync(string date, int limit, Guid? after)
    {
        await _schema.Value;
        var rows = after == null
            ? await Execute("SELECT metadata FROM training_samples WHERE day = ? LIMIT ?", date, limit + 1)
            : await Execute("SELECT metadata FROM training_samples WHERE day = ? AND id > ? LIMIT ?", date, after.Value, limit + 1);
        var samples = rows.Select(Sample).ToList();
        var more = samples.Count > limit;
        if (more) samples.RemoveAt(limit);
        return new TrainingSamplePage(samples, more ? Convert.ToBase64String(samples[^1].Id.ToByteArray()) : null);
    }

    public async Task<byte[]?> AudioAsync(string date, Guid id)
    {
        var row = await RowAsync(date, id);
        if (row == null) return null;
        var sample = Sample(row);
        if (sample.AudioSize == 0) return null;
        var rows = await Execute("SELECT chunk, data FROM training_sample_audio WHERE upload_id = ?", row.GetValue<Guid>("audio_id"));
        using var audio = new MemoryStream(sample.AudioSize);
        var next = 0;
        foreach (var chunk in rows)
        {
            var bytes = chunk.GetValue<byte[]>("data");
            if (chunk.GetValue<int>("chunk") != next++ || audio.Length + bytes.Length > sample.AudioSize)
                throw new InvalidOperationException("Sample audio is incomplete.");
            await audio.WriteAsync(bytes);
        }
        if (audio.Length != sample.AudioSize) throw new InvalidOperationException("Sample audio is incomplete.");
        return audio.ToArray();
    }

    public async Task DeleteAsync(string date, Guid id)
    {
        var row = await RowAsync(date, id);
        if (row == null) return;
        await Execute("BEGIN BATCH DELETE FROM training_samples WHERE day = ? AND id = ?; " +
            "DELETE FROM training_sample_audio WHERE upload_id = ?; APPLY BATCH", date, id, row.GetValue<Guid>("audio_id"));
    }
}
