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
    public async Task Anonymous_ThreeRecordingsPerDay_WithIdempotentChunksAndHelpfulFourthError()
    {
        var clock = new Clock();
        await using var factory = new TestWebApplicationFactory { Clock = clock };
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        var id = Guid.NewGuid();
        Assert.That((await Send(client, id)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That((await Send(client, id)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(factory.TranscriptionService.CallCount, Is.EqualTo(1), "A retry must reuse the result instead of sending the audio upstream again.");
        Assert.That((await Send(client, id, 1)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        var fourth = await Send(client, Guid.NewGuid());
        Assert.That(fourth.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        Assert.That(await fourth.Content.ReadAsStringAsync(), Does.Contain("anonymous_daily_limit").And.Contain("Sign in").And.Contain("tomorrow"));
        Assert.That(await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync(), Does.Contain("\"remainingRecordings\":0"));
        clock.Now = clock.Now.AddDays(1);
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task Anonymous_EnforcesActualCombinedWavDuration_AndRejectsChangedRetry()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        var id = Guid.NewGuid();
        Assert.That((await Send(client, id, 0, 30)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That((await Send(client, id, 1, 30)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That((await Send(client, id, 0, 30)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        var over = await Send(client, id, 2, 1);
        Assert.That(over.StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge));
        Assert.That(await over.Content.ReadAsStringAsync(), Does.Contain("anonymous_recording_too_long").And.Contain("Sign in"));
        Assert.That((await Send(client, id, 0, 30, 1)).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
    }

    [Test]
    public async Task Anonymous_RejectsUnverifiableAudio_AndInvalidBearer()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        using var invalid = new ByteArrayContent(new byte[100]);
        invalid.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        var response = await client.PostAsync($"/api/transcription/segment?recordingId={Guid.NewGuid()}&segment=0", invalid);
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("invalid_audio").And.Contain("Record it again"));
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "invalid");
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That((await client.GetAsync("/api/transcription/status")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task Anonymous_QuotaSurvivesServerRestart_AndUntrustedForwardedIpCannotBypass()
    {
        var store = new InMemoryAnonymousQuotaStore();
        await using (var first = new TestWebApplicationFactory { AnonymousQuotaStore = store })
        {
            first.TranscriptionService.IsConfigured = true;
            using var client = await first.StartAsync();
            for (var i = 0; i < 3; i++) Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        }
        await using var second = new TestWebApplicationFactory { AnonymousQuotaStore = store };
        second.TranscriptionService.IsConfigured = true;
        using var next = await second.StartAsync();
        next.DefaultRequestHeaders.Add("X-Forwarded-For", "198.51.100.4");
        Assert.That((await Send(next, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
    }

    [Test]
    public async Task SignedIn_DoesNotConsumeAnonymousQuota_OrHaveOneMinuteLimit()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        using var client = await factory.StartAsync();
        var token = await TestAuthHelper.GetDevTokenAsync(client);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        for (var i = 0; i < 4; i++) Assert.That((await client.PostAsync("/api/transcription/segment", Wav(61))).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        client.DefaultRequestHeaders.Authorization = null;
        Assert.That(await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync(), Does.Contain("\"remainingRecordings\":3"));
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
            Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        }
        client.DefaultRequestHeaders.Remove("X-Forwarded-For");
        client.DefaultRequestHeaders.Add("X-Forwarded-For", "203.0.113.99, 198.51.100.4");
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        client.DefaultRequestHeaders.Remove("X-Forwarded-For");
        client.DefaultRequestHeaders.Add("X-Forwarded-For", "198.51.100.5");
        Assert.That((await Send(client, Guid.NewGuid())).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task FailedRetries_AreBounded_ButCanRecoverAfterOneMinuteWithoutNewSlot()
    {
        var clock = new Clock();
        await using var factory = new TestWebApplicationFactory { Clock = clock };
        factory.TranscriptionService.IsConfigured = true;
        factory.TranscriptionService.ThrowOnTranscribe = new TranscriptionFailedException("unavailable");
        using var client = await factory.StartAsync();
        var id = Guid.NewGuid();
        for (var i = 0; i < 4; i++) Assert.That((await Send(client, id)).StatusCode, Is.EqualTo(HttpStatusCode.BadGateway));
        var limited = await Send(client, id);
        Assert.That(limited.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        Assert.That(await limited.Content.ReadAsStringAsync(), Does.Contain("Wait one minute"));
        clock.Now = clock.Now.AddMinutes(1);
        factory.TranscriptionService.ThrowOnTranscribe = null;
        Assert.That((await Send(client, id)).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(await (await client.GetAsync("/api/transcription/status")).Content.ReadAsStringAsync(), Does.Contain("\"remainingRecordings\":2"));
    }

    [Test]
    public async Task ConcurrentReservations_AcrossInstances_AllowExactlyThree()
    {
        var store = new InMemoryAnonymousQuotaStore();
        var quotas = Enumerable.Range(0, 10).Select(_ => new AnonymousRecordingQuota(store, TimeProvider.System));
        var results = await Task.WhenAll(quotas.Select(q => q.ReserveAsync("same-ip", Guid.NewGuid(), 0, new byte[] {1}, 6)));
        Assert.That(results.Count(r => r == null), Is.EqualTo(3));
        Assert.That(results.Count(r => r == "anonymous_daily_limit"), Is.EqualTo(7));
    }
}
