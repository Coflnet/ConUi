using System.Reflection;
using System.Text.Json;
using Cassandra;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Tests;

public sealed class CassandraTrainingSampleStoreTests
{
    public class SessionProxy : DispatchProxy
    {
        public Func<SimpleStatement, Task<RowSet>> Handler = null!;
        protected override object? Invoke(MethodInfo? method, object?[]? args) =>
            method?.Name == "ExecuteAsync" && args?[0] is SimpleStatement statement
                ? Handler(statement) : throw new NotSupportedException(method?.Name);
    }
    private sealed class Connection(ISession session) : ICassandraConnection
    {
        public int Accesses;
        public ISession Session { get { Accesses++; return session; } }
        public Task PingAsync(CancellationToken cancellationToken = default) => Task.CompletedTask;
    }
    private sealed class ValueRow(Dictionary<string, object> values) : Row
    {
        public override T GetValue<T>(string name) => (T)values[name];
    }
    private static RowSet Rows(params Dictionary<string, object>[] values)
    {
        var rows = new RowSet();
        var add = typeof(RowSet).GetMethod("AddRow", BindingFlags.Instance | BindingFlags.NonPublic)!;
        foreach (var value in values) add.Invoke(rows, [new ValueRow(value)]);
        return rows;
    }
    private static (CassandraTrainingSampleStore Store, Connection Connection, List<SimpleStatement> Queries) Store(Func<SimpleStatement, Task<RowSet>> handler)
    {
        var session = DispatchProxy.Create<ISession, SessionProxy>();
        var queries = new List<SimpleStatement>();
        ((SessionProxy)(object)session).Handler = statement => { queries.Add(statement); return handler(statement); };
        var connection = new Connection(session);
        return (new CassandraTrainingSampleStore(connection), connection, queries);
    }
    private static TrainingSample Sample(int audioSize = 0) => new(Guid.NewGuid(), "2026-10-04", DateTimeOffset.UtcNow,
        "1", "Synthetic test transcript", null, "en", [], [], audioSize, audioSize == 0 ? null : "audio-hash", "data-hash");
    private static Task<RowSet> Applied() => Task.FromResult(Rows(new Dictionary<string, object> { ["[applied]"] = true }));
    private static Task<RowSet> Empty() => Task.FromResult(Rows());

    [Test]
    public async Task LazySchema_PublishesOnlyAfterBoundedChunks_AndAudioRoundTripsWithStrongConsistency()
    {
        var audio = new byte[600000];
        var sample = Sample(audio.Length);
        var chunks = new List<(int Index, byte[] Data)>();
        Guid audioId = Guid.Empty;
        var fixture = Store(statement =>
        {
            var values = statement.QueryValues;
            if (statement.QueryString.StartsWith("INSERT INTO training_sample_audio"))
            {
                audioId = (Guid)values[0];
                chunks.Add(((int)values[1], (byte[])values[2]));
            }
            if (statement.QueryString.StartsWith("INSERT INTO training_samples"))
            {
                Assert.That(chunks.Sum(c => c.Data.Length), Is.EqualTo(audio.Length), "Metadata must not expose a partially written recording.");
                Assert.That((Guid)values[3], Is.EqualTo(audioId));
                return Applied();
            }
            if (statement.QueryString.StartsWith("SELECT metadata, audio_id"))
                return Task.FromResult(Rows(new Dictionary<string, object> { ["metadata"] = JsonSerializer.Serialize(sample), ["audio_id"] = audioId }));
            if (statement.QueryString.StartsWith("SELECT chunk, data"))
                return Task.FromResult(Rows(chunks.Select(c => new Dictionary<string, object> { ["chunk"] = c.Index, ["data"] = c.Data }).ToArray()));
            return Empty();
        });
        Assert.That(fixture.Connection.Accesses, Is.Zero, "Registering storage must not open Cassandra.");
        Assert.That(await fixture.Store.PublishAsync(sample, audio), Is.EqualTo(sample));
        Assert.That(chunks, Has.Count.EqualTo(3));
        Assert.That(chunks.All(c => c.Data.Length <= 256 * 1024), Is.True);
        Assert.That(await fixture.Store.AudioAsync(sample.Date, sample.Id), Is.EqualTo(audio));
        Assert.That(fixture.Queries.Count(q => q.QueryString.StartsWith("CREATE TABLE")), Is.EqualTo(2));
        Assert.That(fixture.Queries.All(q => q.ConsistencyLevel is ConsistencyLevel.Quorum or ConsistencyLevel.Serial), Is.True);
        Assert.That(fixture.Queries.First(q => q.QueryString.StartsWith("INSERT INTO training_samples")).QueryString, Does.EndWith("IF NOT EXISTS"));
        Assert.That(fixture.Queries.First(q => q.QueryString.StartsWith("INSERT INTO training_samples")).SerialConsistencyLevel, Is.EqualTo(ConsistencyLevel.Serial));
    }

    [Test]
    public async Task LostPublication_CleansOnlyOwnUpload_AndKeepsExistingSample()
    {
        var existing = Sample(1);
        var winnerId = Guid.NewGuid();
        Guid loserId = Guid.Empty;
        var fixture = Store(statement =>
        {
            if (statement.QueryString.StartsWith("INSERT INTO training_sample_audio")) loserId = (Guid)statement.QueryValues[0];
            if (statement.QueryString.StartsWith("INSERT INTO training_samples")) return Task.FromResult(Rows(new Dictionary<string, object> { ["[applied]"] = false }));
            if (statement.QueryString.StartsWith("SELECT metadata, audio_id"))
                return Task.FromResult(Rows(new Dictionary<string, object> { ["metadata"] = JsonSerializer.Serialize(existing), ["audio_id"] = winnerId }));
            return Empty();
        });
        var returned = await fixture.Store.PublishAsync(existing with { DataSha256 = "different" }, [1]);
        Assert.That(returned.Id, Is.EqualTo(existing.Id));
        Assert.That(returned.DataSha256, Is.EqualTo(existing.DataSha256));
        var cleanup = fixture.Queries.Single(q => q.QueryString.StartsWith("DELETE"));
        Assert.That(cleanup.QueryString, Is.EqualTo("DELETE FROM training_sample_audio WHERE upload_id = ?"));
        Assert.That(cleanup.QueryValues[0], Is.EqualTo(loserId).And.Not.EqualTo(winnerId));
    }

    [Test]
    public void FailedChunkUpload_CleansOwnChunks_WhileUncertainCommittedPublicationPreservesAudio()
    {
        var sample = Sample(300000);
        var failed = Store(statement => statement.QueryString.StartsWith("INSERT INTO training_sample_audio") && (int)statement.QueryValues[1] == 1
            ? throw new IOException("Synthetic write failure") : Empty());
        Assert.ThrowsAsync<IOException>(() => failed.Store.PublishAsync(sample, new byte[300000]));
        Assert.That(failed.Queries.Any(q => q.QueryString.StartsWith("INSERT INTO training_samples")), Is.False);
        Assert.That(failed.Queries.Count(q => q.QueryString.StartsWith("DELETE FROM training_sample_audio")), Is.EqualTo(1));
        var ambiguous = Store(statement => statement.QueryString.StartsWith("INSERT INTO training_samples") || statement.QueryString.StartsWith("SELECT metadata, audio_id")
            ? throw new IOException("Synthetic timeout with unknown commit state") : Empty());
        Assert.ThrowsAsync<IOException>(() => ambiguous.Store.PublishAsync(sample, [1]));
        Assert.That(ambiguous.Queries.Any(q => q.QueryString.StartsWith("DELETE")), Is.False, "An unavailable status read must not erase audio that may already be published.");
    }

    [Test]
    public async Task Removal_UsesOneLoggedBatchForMetadataAndItsExactAudioPartition()
    {
        var sample = Sample(1);
        var audioId = Guid.NewGuid();
        var fixture = Store(statement => statement.QueryString.StartsWith("SELECT metadata, audio_id")
            ? Task.FromResult(Rows(new Dictionary<string, object> { ["metadata"] = JsonSerializer.Serialize(sample), ["audio_id"] = audioId })) : Empty());
        await fixture.Store.DeleteAsync(sample.Date, sample.Id);
        var delete = fixture.Queries.Single(q => q.QueryString.StartsWith("BEGIN BATCH"));
        Assert.That(delete.QueryString, Does.Contain("DELETE FROM training_samples WHERE day = ? AND id = ?;")
            .And.Contain("DELETE FROM training_sample_audio WHERE upload_id = ?; APPLY BATCH"));
        Assert.That(delete.QueryValues, Is.EqualTo(new object[] { sample.Date, sample.Id, audioId }));
    }
}
