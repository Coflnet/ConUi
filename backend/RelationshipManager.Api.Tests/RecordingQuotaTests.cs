using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RelationshipManager.Api.Services;
using RelationshipManager.Api.Tests.Fakes;

namespace RelationshipManager.Api.Tests;

public class RecordingQuotaTests
{
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = new(2026, 10, 28, 23, 59, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private sealed class YieldingStore : IAnonymousQuotaStore
    {
        private readonly InMemoryAnonymousQuotaStore _inner = new();
        public async Task<string?> ReadAsync(string key) { await Task.Yield(); return await _inner.ReadAsync(key); }
        public async Task<bool> CompareExchangeAsync(string key, string? previous, string next)
        { await Task.Yield(); return await _inner.CompareExchangeAsync(key, previous, next); }
    }

    private sealed class ConflictingStore : IAnonymousQuotaStore
    {
        public int Attempts;
        public Task<string?> ReadAsync(string key) => Task.FromResult<string?>(null);
        public Task<bool> CompareExchangeAsync(string key, string? previous, string next)
        { Attempts++; return Task.FromResult(false); }
    }

    private sealed class MidnightStore(IAnonymousQuotaStore inner, Clock clock) : IAnonymousQuotaStore
    {
        public async Task<string?> ReadAsync(string key)
        {
            var state = await inner.ReadAsync(key);
            clock.Now = new DateTimeOffset(2026, 10, 29, 0, 0, 0, TimeSpan.Zero);
            return state;
        }
        public Task<bool> CompareExchangeAsync(string key, string? previous, string next) => inner.CompareExchangeAsync(key, previous, next);
    }

    [Test]
    public async Task ConcurrentReservationsAcrossInstances_CannotOverspendPendingOrCompletedBudget()
    {
        var store = new YieldingStore();
        var quotas = Enumerable.Range(0, 10).Select(_ => new AnonymousRecordingQuota(store, TimeProvider.System)).ToArray();
        try
        {
            var results = await Task.WhenAll(quotas.Select(q => q.ReserveAsync("same-ip", 300, Guid.NewGuid(), 0, [1], 100)));
            Assert.That(results.Count(r => r.Error == null), Is.EqualTo(3));
            Assert.That(results.Count(r => r.Error == "anonymous_daily_limit"), Is.EqualTo(7));
            var pending = await quotas[0].StatusAsync("same-ip", 300);
            Assert.That(pending.UsedSeconds, Is.Zero);
            Assert.That(pending.RemainingSeconds, Is.Zero);
            await Task.WhenAll(results.Where(r => r.Reservation != null).Select(r => quotas[0].CompleteAsync(r.Reservation!)));
            var completed = await quotas[0].StatusAsync("same-ip", 300);
            Assert.That(completed.UsedSeconds, Is.EqualTo(300));
            Assert.That(completed.RemainingSeconds, Is.Zero);
        }
        finally { foreach (var quota in quotas) quota.Dispose(); }
    }

    [TestCase(300)]
    [TestCase(1200)]
    public async Task TinyWavSegments_HaveAtomicDailyCardinalityBound_WithoutBlockingRetriesOrRecovery(int limit)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(38);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(8000); writer.Write(16000);
        writer.Write((short)2); writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(2); writer.Write((short)0);
        var audio = stream.ToArray();
        var seconds = AnonymousRecordingQuota.WavSeconds(audio)!.Value;
        Assert.That(seconds, Is.EqualTo(0.000125));
        var hash = Convert.ToHexString(SHA256.HashData(audio));
        var clock = new Clock { Now = new DateTimeOffset(2026, 10, 28, 12, 0, 0, TimeSpan.Zero) };
        var store = new YieldingStore();
        var key = "2026-10-28:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("ip")));
        var state = Enumerable.Range(0, 4095).ToDictionary(_ => Guid.NewGuid(), _ =>
            new Dictionary<int, AnonymousRecordingQuota.Segment> { [0] = new() { Hash = hash, Seconds = seconds } });
        await store.CompareExchangeAsync(key, null, JsonSerializer.Serialize(state));
        var quotas = Enumerable.Range(0, 4).Select(_ => new AnonymousRecordingQuota(store, clock)).ToArray();
        try
        {
            var results = await Task.WhenAll(quotas.Select(q => q.ReserveAsync("ip", limit, Guid.NewGuid(), 0, audio, seconds)));
            Assert.That(results.Count(r => r.Error == null), Is.EqualTo(1));
            Assert.That(results.Count(r => r.Error == "recording_segment_limit"), Is.EqualTo(3));
            var persisted = JsonSerializer.Deserialize<Dictionary<Guid, Dictionary<int, AnonymousRecordingQuota.Segment>>>((await store.ReadAsync(key))!)!;
            Assert.That(persisted.Values.Sum(r => r.Count), Is.EqualTo(4096));
            Assert.That((await quotas[0].StatusAsync("ip", limit)).UsedSeconds, Is.LessThan(1));
            Assert.That((await quotas[0].ReserveAsync("ip", limit, state.Keys.First(), 0, audio, seconds)).Error, Is.Null,
                "A completed retry must remain usable at the distinct-segment cap.");
            var pending = results.Single(r => r.Reservation != null).Reservation!;
            Assert.That((await quotas[0].ReserveAsync("ip", limit, pending.RecordingId, 0, audio, seconds)).Error, Is.EqualTo("recording_segment_busy"));
            await quotas[0].ReleaseAsync(pending);
            Assert.That((await quotas[0].ReserveAsync("ip", limit, Guid.NewGuid(), 0, audio, seconds)).Error, Is.Null,
                "Failed transcription releases its cardinality slot as well as its duration.");
            clock.Now = clock.Now.AddMinutes(5);
            Assert.That((await quotas[0].ReserveAsync("ip", limit, Guid.NewGuid(), 0, audio, seconds)).Error, Is.Null,
                "An expired pending reservation no longer occupies a cardinality slot.");
        }
        finally { foreach (var quota in quotas) quota.Dispose(); }
    }

    [Test]
    public async Task ActiveDuplicateIsBusy_ReleaseAllowsImmediateRetry_CompletedRetryDoesNotChargeAgain()
    {
        var clock = new Clock();
        using var quota = new AnonymousRecordingQuota(new InMemoryAnonymousQuotaStore(), clock);
        var id = Guid.NewGuid();
        var first = await quota.ReserveAsync("ip", 300, id, 0, [1], 180);
        Assert.That((await quota.ReserveAsync("ip", 300, id, 0, [1], 180)).Error, Is.EqualTo("recording_segment_busy"));
        Assert.That((await quota.ReserveAsync("ip", 300, id, 0, [2], 180)).Error, Is.EqualTo("invalid_recording_segment"));
        await quota.ReleaseAsync(first.Reservation!);
        Assert.That((await quota.StatusAsync("ip", 300)).RemainingSeconds, Is.EqualTo(300));
        var retried = await quota.ReserveAsync("ip", 300, id, 0, [1], 180);
        await quota.CompleteAsync(retried.Reservation!);
        var cachedAfterRestart = await quota.ReserveAsync("ip", 300, id, 0, [1], 180);
        Assert.That(cachedAfterRestart.Error, Is.Null);
        await quota.CompleteAsync(cachedAfterRestart.Reservation!);
        Assert.That((await quota.StatusAsync("ip", 300)).UsedSeconds, Is.EqualTo(180));
        Assert.That((await quota.ReserveAsync("ip", 300, Guid.NewGuid(), 0, [1], 121)).Error, Is.EqualTo("anonymous_daily_limit"));
        for (var i = 0; i < 2; i++)
            Assert.That((await quota.ReserveAsync("ip", 300, id, 0, [1], 180)).Error, Is.Null);
        Assert.That((await quota.ReserveAsync("ip", 300, id, 0, [1], 180)).Error, Is.EqualTo("too_many_requests"));
        clock.Now = clock.Now.AddMinutes(1);
        Assert.That((await quota.ReserveAsync("ip", 300, id, 0, [1], 180)).Error, Is.Null);
    }

    [Test]
    public async Task ExpiredReservationRecoversBudget_StaleOwnerCannotCompleteOrReleaseReplacement()
    {
        var clock = new Clock { Now = new DateTimeOffset(2026, 10, 28, 12, 0, 0, TimeSpan.Zero) };
        using var daytimeQuota = new AnonymousRecordingQuota(new InMemoryAnonymousQuotaStore(), clock);
        var id = Guid.NewGuid();
        var first = await daytimeQuota.ReserveAsync("ip", 300, id, 0, [1], 300);
        clock.Now = clock.Now.AddMinutes(5);
        Assert.That((await daytimeQuota.StatusAsync("ip", 300)).RemainingSeconds, Is.EqualTo(300));
        var replacement = await daytimeQuota.ReserveAsync("ip", 300, id, 0, [1], 300);
        await daytimeQuota.ReleaseAsync(first.Reservation!);
        Assert.ThrowsAsync<InvalidOperationException>(async () => await daytimeQuota.CompleteAsync(first.Reservation!));
        Assert.That((await daytimeQuota.StatusAsync("ip", 300)).RemainingSeconds, Is.Zero);
        await daytimeQuota.CompleteAsync(replacement.Reservation!);
        Assert.That((await daytimeQuota.StatusAsync("ip", 300)).UsedSeconds, Is.EqualTo(300));
    }

    [Test]
    public async Task CompletionAcrossUtcMidnight_ChargesOriginalDay_AndDoesNotTouchNewReservation()
    {
        var clock = new Clock();
        using var quota = new AnonymousRecordingQuota(new InMemoryAnonymousQuotaStore(), clock);
        var id = Guid.NewGuid();
        var previousDay = await quota.ReserveAsync("ip", 300, id, 0, [1], 300);
        clock.Now = clock.Now.AddMinutes(1);
        var nextDay = await quota.ReserveAsync("ip", 300, id, 0, [1], 300);
        await quota.CompleteAsync(previousDay.Reservation!);
        quota.CacheText(previousDay.Reservation!, [1], "de", "previous day's result");
        Assert.That(quota.CachedText("ip", id, 0, [1], "de"), Is.Null, "Late completion cannot populate the new day's cache.");
        Assert.That((await quota.StatusAsync("ip", 300)).UsedSeconds, Is.Zero);
        await quota.CompleteAsync(nextDay.Reservation!);
        var status = await quota.StatusAsync("ip", 300);
        Assert.That(status.UsedSeconds, Is.EqualTo(300));
        Assert.That(status.ResetAt, Is.EqualTo(new DateTimeOffset(2026, 10, 30, 0, 0, 0, TimeSpan.Zero)));
    }

    [Test]
    public async Task OldLedgerDurationsRemainCharged_WithoutAudioOrTranscriptStorage()
    {
        var clock = new Clock();
        var store = new InMemoryAnonymousQuotaStore();
        var key = "2026-10-28:" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("ip")));
        await store.CompareExchangeAsync(key, null, $"{{\"{Guid.NewGuid()}\":{{\"0\":{{\"Hash\":\"oldhash\",\"Seconds\":60,\"Attempts\":1}}}}}}");
        using var quota = new AnonymousRecordingQuota(store, clock);
        var status = await quota.StatusAsync("ip", 300);
        Assert.That(status.UsedSeconds, Is.EqualTo(60));
        Assert.That(status.RemainingSeconds, Is.EqualTo(240));
        var audio = Encoding.UTF8.GetBytes("private audio marker");
        var reservation = await quota.ReserveAsync("ip", 300, Guid.NewGuid(), 0, audio, 6);
        await quota.CompleteAsync(reservation.Reservation!);
        quota.CacheText(reservation.Reservation!, audio, "de", "private transcript marker");
        Assert.That(await store.ReadAsync(key), Does.Not.Contain("private audio marker").And.Not.Contain("private transcript marker"));
    }

    [Test]
    public async Task StatusReadAcrossMidnight_LabelsUsageWithTheDayThatWasRead()
    {
        var clock = new Clock();
        var store = new InMemoryAnonymousQuotaStore();
        using var quota = new AnonymousRecordingQuota(store, clock);
        var reservation = await quota.ReserveAsync("ip", 300, Guid.NewGuid(), 0, [1], 60);
        await quota.CompleteAsync(reservation.Reservation!);
        using var crossingMidnight = new AnonymousRecordingQuota(new MidnightStore(store, clock), clock);
        var status = await crossingMidnight.StatusAsync("ip", 300);
        Assert.That(status.UsedSeconds, Is.EqualTo(60));
        Assert.That(status.ResetAt, Is.EqualTo(new DateTimeOffset(2026, 10, 29, 0, 0, 0, TimeSpan.Zero)));
        Assert.That((await crossingMidnight.StatusAsync("ip", 300)).UsedSeconds, Is.Zero);
    }

    [Test]
    public void CasContentionIsBounded()
    {
        var store = new ConflictingStore();
        using var quota = new AnonymousRecordingQuota(store, TimeProvider.System);
        Assert.ThrowsAsync<InvalidOperationException>(async () => await quota.ReserveAsync("ip", 300, Guid.NewGuid(), 0, [1], 6));
        Assert.That(store.Attempts, Is.EqualTo(20));
    }
}
