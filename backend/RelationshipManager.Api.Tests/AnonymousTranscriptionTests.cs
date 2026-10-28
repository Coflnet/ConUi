using System.Net;
using System.Net.Http.Headers;
using System.Text;
using RelationshipManager.Api.Services;
using RelationshipManager.Api.Tests.Fakes;

namespace RelationshipManager.Api.Tests;

public class AnonymousTranscriptionTests
{
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = new(2026, 10, 3, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private static ByteArrayContent Wav(int seconds, byte sample = 0)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        var dataBytes = seconds * 16000 * 2;
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + dataBytes);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(16000); writer.Write(32000);
        writer.Write((short)2); writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(dataBytes);
        writer.Write(Enumerable.Repeat(sample, dataBytes).ToArray());
        var content = new ByteArrayContent(stream.ToArray());
        content.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        return content;
    }

    private static Task<HttpResponseMessage> Send(HttpClient client, Guid id, int segment = 0, int seconds = 6, byte sample = 0) =>
        client.PostAsync($"/api/transcription/segment?recordingId={id}&segment={segment}", Wav(seconds, sample));

    [Test]
    public async Task Anonymous_ResultCacheIncludesContext_AndSameContextRetryUsesCache()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        var id = Guid.NewGuid();
        client.DefaultRequestHeaders.Add("X-Transcription-Prompt", Convert.ToBase64String(Encoding.UTF8.GetBytes("First context")));
        factory.TranscriptionService.ResultText = "first result";
        Assert.That(await (await Send(client, id)).Content.ReadAsStringAsync(), Does.Contain("first result"));
        client.DefaultRequestHeaders.Remove("X-Transcription-Prompt");
        client.DefaultRequestHeaders.Add("X-Transcription-Prompt", Convert.ToBase64String(Encoding.UTF8.GetBytes("Different context")));
        factory.TranscriptionService.ResultText = "second result";
        Assert.That(await (await Send(client, id)).Content.ReadAsStringAsync(), Does.Contain("second result"));
        Assert.That(await (await Send(client, id)).Content.ReadAsStringAsync(), Does.Contain("second result"));
        Assert.That(factory.TranscriptionService.CallCount, Is.EqualTo(2));
    }

    [Test]
    public async Task Anonymous_FiveMinutesAcrossRecordings_ResetsAtUtcMidnight()
    {
        var clock = new Clock();
        await using var factory = new TestWebApplicationFactory { Clock = clock };
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        client.DefaultRequestHeaders.Add("X-Audio-Duration", "0"); // Client claims never determine the charged duration.
        for (var i = 0; i < 5; i++)
            Assert.That((await Send(client, Guid.NewGuid(), seconds: 60)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        var over = await Send(client, Guid.NewGuid(), seconds: 1);
        Assert.That(over.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        Assert.That(await over.Content.ReadAsStringAsync(), Does.Contain("anonymous_daily_limit").And.Contain("Sign in").And.Contain("tomorrow"));
        var status = await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync();
        Assert.That(status, Does.Contain("\"usedSeconds\":300").And.Contain("\"remainingSeconds\":0").And.Contain("\"dailyLimitSeconds\":300").And.Contain("\"warningAfterSeconds\":180").And.Contain("2026-10-04T00:00:00+00:00"));
        clock.Now = new DateTimeOffset(2026, 10, 4, 0, 0, 0, TimeSpan.Zero);
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task Anonymous_OneRecordingMayExceedOneMinute_AndRetryIsIdempotent()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        var id = Guid.NewGuid();
        Assert.That((await Send(client, id, 0, 66)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That((await Send(client, id, 64, 66)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        var retried = await Send(client, id, 0, 66);
        Assert.That(retried.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(await retried.Content.ReadAsStringAsync(), Does.Contain("\"usedSeconds\":132").And.Contain("\"remainingSeconds\":168").And.Contain("\"available\":true"));
        Assert.That(factory.TranscriptionService.CallCount, Is.EqualTo(2));
        Assert.That((await Send(client, id, 0, 66, 1)).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task AllUploads_RequireVerifiableWav_RecordingIdentity_AndValidAuthentication()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        foreach (var authenticated in new[] { false, true })
        {
            if (authenticated) client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", await TestAuthHelper.GetDevTokenAsync(client));
            using var invalid = new ByteArrayContent(new byte[100]);
            invalid.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
            var response = await client.PostAsync($"/api/transcription/segment?recordingId={Guid.NewGuid()}&segment=0", invalid);
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
            Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("invalid_audio").And.Contain("Record it again"));
            Assert.That((await client.PostAsync("/api/transcription/segment", Wav(1))).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
            using var webm = new ByteArrayContent(new byte[100]);
            webm.Headers.ContentType = new MediaTypeHeaderValue("audio/webm");
            Assert.That((await client.PostAsync($"/api/transcription/segment?recordingId={Guid.NewGuid()}&segment=0", webm)).StatusCode, Is.EqualTo(HttpStatusCode.UnsupportedMediaType));
        }
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "invalid");
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That((await client.GetAsync("/api/transcription/status")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That(factory.TranscriptionService.CallCount, Is.Zero);
    }

    [Test]
    public async Task Anonymous_QuotaSurvivesRestart_UntrustedForwardedIpCannotBypass_AndRetryDoesNotDoubleCharge()
    {
        var store = new InMemoryAnonymousQuotaStore();
        var id = Guid.NewGuid();
        await using (var first = new TestWebApplicationFactory { AnonymousQuotaStore = store })
        {
            first.TranscriptionService.IsConfigured = true;
            using var client = await first.StartAsync();
            for (var i = 0; i < 3; i++) Assert.That((await Send(client, id, i, 100)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        }
        await using var second = new TestWebApplicationFactory { AnonymousQuotaStore = store };
        second.TranscriptionService.IsConfigured = true;
        using var next = await second.StartAsync();
        next.DefaultRequestHeaders.Add("X-Forwarded-For", "198.51.100.4");
        Assert.That((await Send(next, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        var retry = await Send(next, id, 0, 100);
        Assert.That(retry.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(await retry.Content.ReadAsStringAsync(), Does.Contain("\"usedSeconds\":300"));
    }

    [Test]
    public async Task SignedIn_TwentyMinutesArePerUser_AndSeparateFromGuestQuota()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        var token = await TestAuthHelper.GetDevTokenAsync(client);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var id = Guid.NewGuid();
        for (var i = 0; i < 10; i++) Assert.That((await Send(client, id, i, 120)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        var over = await Send(client, Guid.NewGuid(), seconds: 1);
        Assert.That(over.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        Assert.That(await over.Content.ReadAsStringAsync(), Does.Contain("transcription_daily_limit"));
        Assert.That((await Send(client, id, 0, 120)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(factory.TranscriptionService.CallCount, Is.EqualTo(10), "Signed-in retries also use the result cache.");
        var status = await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync();
        Assert.That(status, Does.Contain("\"usedSeconds\":1200").And.Contain("\"dailyLimitSeconds\":1200"));
        Assert.That(status, Does.Not.Contain("\"warningAfterSeconds\":180"));
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TestAuthHelper.MintTokenWithSub(factory, Guid.NewGuid().ToString()));
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        client.DefaultRequestHeaders.Authorization = null;
        Assert.That(await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync(), Does.Contain("\"remainingSeconds\":300"));
    }

    [Test]
    public async Task OnlyTrustedProxy_ProvidesClientIp_AndClientSpoofedPrefixIsIgnored()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        factory.ConfigOverrides["ReverseProxy:KnownProxies:0"] = "127.0.0.1";
        using var client = await factory.StartAsync();
        for (var i = 0; i < 3; i++)
        {
            client.DefaultRequestHeaders.Remove("X-Forwarded-For");
            client.DefaultRequestHeaders.Add("X-Forwarded-For", $"203.0.113.{i}, 198.51.100.4");
            Assert.That((await Send(client, Guid.NewGuid(), seconds: 100)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        }
        client.DefaultRequestHeaders.Remove("X-Forwarded-For");
        client.DefaultRequestHeaders.Add("X-Forwarded-For", "203.0.113.99, 198.51.100.4");
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        client.DefaultRequestHeaders.Remove("X-Forwarded-For");
        client.DefaultRequestHeaders.Add("X-Forwarded-For", "198.51.100.5");
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task FailedTranscriptions_ReleaseBudget_AndSameSegmentCanRecoverImmediately()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        factory.TranscriptionService.ThrowOnTranscribe = new TranscriptionFailedException("unavailable");
        using var client = await factory.StartAsync();
        var id = Guid.NewGuid();
        for (var i = 0; i < 5; i++) Assert.That((await Send(client, id, seconds: 100)).StatusCode, Is.EqualTo(HttpStatusCode.BadGateway));
        Assert.That(await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync(), Does.Contain("\"usedSeconds\":0").And.Contain("\"remainingSeconds\":300"));
        factory.TranscriptionService.ThrowOnTranscribe = null;
        Assert.That((await Send(client, id, seconds: 100)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync(), Does.Contain("\"usedSeconds\":100").And.Contain("\"remainingSeconds\":200"));
    }

    [Test]
    public async Task CancelledUpstream_ReleasesReservationBeforeRetry()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        factory.TranscriptionService.ThrowOnTranscribe = new OperationCanceledException();
        using var client = await factory.StartAsync();
        var id = Guid.NewGuid();
        Assert.That((await Send(client, id, seconds: 100)).IsSuccessStatusCode, Is.False);
        Assert.That(await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync(), Does.Contain("\"usedSeconds\":0").And.Contain("\"remainingSeconds\":300"));
        factory.TranscriptionService.ThrowOnTranscribe = null;
        Assert.That((await Send(client, id, seconds: 100)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }
}
