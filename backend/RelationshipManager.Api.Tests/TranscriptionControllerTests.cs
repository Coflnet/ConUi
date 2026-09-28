using System.Net;
using System.Net.Http.Headers;
using System.Text;

namespace RelationshipManager.Api.Tests;

public class TranscriptionControllerTests
{
    private static async Task<(TestWebApplicationFactory factory, HttpClient client, string token)> StartAuthedAsync(
        Action<TestWebApplicationFactory>? configure = null)
    {
        var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        configure?.Invoke(factory);
        var client = await factory.StartAsync();
        var token = await TestAuthHelper.GetDevTokenAsync(client);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        return (factory, client, token);
    }

    private static ByteArrayContent WavContent(int bytes = 100)
    {
        var content = new ByteArrayContent(new byte[bytes]);
        content.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        return content;
    }

    [Test]
    public async Task Status_ReportsWhetherConfigured()
    {
        var (factory, client, _) = await StartAuthedAsync();
        await using var f = factory;
        using var c = client;

        var response = await c.GetAsync("/api/transcription/status");
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(body, Does.Contain("\"available\":true"));
    }

    [Test]
    public async Task Segment_Returns503_WhenNotConfigured()
    {
        var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = false;
        await using var f = factory;
        using var client = await factory.StartAsync();
        var token = await TestAuthHelper.GetDevTokenAsync(client);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await client.PostAsync("/api/transcription/segment", WavContent());
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable), $"body: {body}");
        Assert.That(body, Does.Contain("transcription_not_configured"));
    }

    [Test]
    public async Task Segment_Returns200_WithText_ForValidRequest()
    {
        var (factory, client, _) = await StartAuthedAsync(f => f.TranscriptionService.ResultText = "hallo welt");
        await using var f2 = factory;
        using var c = client;

        var response = await c.PostAsync("/api/transcription/segment?language=de", WavContent());
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK), $"body: {body}");
        Assert.That(body, Does.Contain("hallo welt"));
        Assert.That(factory.TranscriptionService.LastLanguage, Is.EqualTo("de"));
        Assert.That(factory.TranscriptionService.LastContentType, Is.EqualTo("audio/wav"));
    }

    [Test]
    public async Task Segment_Returns415_ForUnsupportedContentType()
    {
        var (factory, client, _) = await StartAuthedAsync();
        await using var f = factory;
        using var c = client;

        var content = new ByteArrayContent(new byte[10]);
        content.Headers.ContentType = new MediaTypeHeaderValue("text/plain");

        var response = await c.PostAsync("/api/transcription/segment", content);
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.UnsupportedMediaType), $"body: {body}");
        Assert.That(body, Does.Contain("unsupported_content_type"));
    }

    [Test]
    public async Task Segment_Returns400_ForInvalidLanguage()
    {
        var (factory, client, _) = await StartAuthedAsync();
        await using var f = factory;
        using var c = client;

        var response = await c.PostAsync("/api/transcription/segment?language=deutsch", WavContent());
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest), $"body: {body}");
        Assert.That(body, Does.Contain("invalid_language"));
    }

    [Test]
    public async Task Segment_Returns401_WithoutAuthentication()
    {
        var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        await using var f = factory;
        using var client = await factory.StartAsync();

        var response = await client.PostAsync("/api/transcription/segment", WavContent());

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task Segment_Returns401_WithCommonErrorShape_WhenSubClaimIsNotAGuid()
    {
        // Regression test: same bug/fix as SyncController and AuthController.GetCurrentUser -
        // `if (userId == null) return Unauthorized();` used to be bare, so [ApiController] turned
        // it into ASP.NET's ProblemDetails body instead of this API's {"slug","message"} shape.
        var factory = new TestWebApplicationFactory();
        factory.TranscriptionService.IsConfigured = true;
        await using var f = factory;
        using var client = await factory.StartAsync();
        var token = TestAuthHelper.MintTokenWithSub(factory, sub: "not-a-guid");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await client.PostAsync("/api/transcription/segment", WavContent());
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized), $"body: {body}");
        Assert.That(body, Does.Contain("\"slug\":\"unauthorized\""), $"body: {body}");
        Assert.That(body, Does.Not.Contain("\"traceId\""), $"body: {body}");
    }

    [Test]
    public async Task Segment_Returns502_WhenUpstreamFails()
    {
        var (factory, client, _) = await StartAuthedAsync(f =>
            f.TranscriptionService.ThrowOnTranscribe = new Services.TranscriptionFailedException("boom"));
        await using var f2 = factory;
        using var c = client;

        var response = await c.PostAsync("/api/transcription/segment", WavContent());
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadGateway), $"body: {body}");
        Assert.That(body, Does.Contain("transcription_failed"));
    }

    [Test]
    public async Task Segment_Returns413_WhenBodyExceedsMaxSegmentBytes()
    {
        var (factory, client, _) = await StartAuthedAsync(f => f.ConfigOverrides["Transcription:MaxSegmentBytes"] = "16");
        await using var f2 = factory;
        using var c = client;

        var response = await c.PostAsync("/api/transcription/segment", WavContent(bytes: 1024));
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge), $"body: {body}");
        Assert.That(body, Does.Contain("segment_too_large"));
    }

    [Test]
    public async Task Segment_Returns429_WhenOverConcurrencyLimit()
    {
        var (factory, client, token) = await StartAuthedAsync(f => f.ConfigOverrides["Transcription:MaxConcurrentPerUser"] = "1");
        await using var f2 = factory;
        using var c = client;

        // Hold the first request "in flight" so the concurrency slot stays taken.
        factory.TranscriptionService.Gate = new TaskCompletionSource<bool>();
        var firstRequest = c.PostAsync("/api/transcription/segment", WavContent());

        // Give the first request a moment to actually acquire the semaphore before the second fires.
        await Task.Delay(200);

        using var secondClient = new HttpClient { BaseAddress = c.BaseAddress };
        secondClient.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var secondResponse = await secondClient.PostAsync("/api/transcription/segment", WavContent());
        var secondBody = await secondResponse.Content.ReadAsStringAsync();

        factory.TranscriptionService.Gate.SetResult(true);
        var firstResponse = await firstRequest;

        Assert.That(secondResponse.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests), $"body: {secondBody}");
        Assert.That(secondBody, Does.Contain("too_many_requests"));
        Assert.That(firstResponse.StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }
}
