using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using RelationshipManager.Api.Auth;

namespace RelationshipManager.Api.Tests;

/// <summary>
/// Regression coverage for two diagnosed bugs:
///  - POST /api/auth/dev was anonymous and enabled by default (ENABLE_DEV_AUTH defaulted to
///    true, with no environment check at all), so anyone could mint a token for any user id.
///  - POST /api/auth/firebase fell back to accepting `"dev_" + token` as the user id whenever
///    Firebase wasn't initialized, i.e. any string was accepted as a valid login.
/// </summary>
public class AuthControllerTests
{
    [Test]
    public async Task DevLogin_Returns404_WhenDisabledByConfig()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.ConfigOverrides["ENABLE_DEV_AUTH"] = "false";
        using var client = await factory.StartAsync();

        var response = await client.PostAsJsonAsync("/api/auth/dev", new { userId = "someone" });

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    [Test]
    public async Task DevLogin_Returns404_OutsideDevelopment_EvenWhenEnabled()
    {
        await using var factory = new TestWebApplicationFactory { Environment = "Production" };
        factory.ConfigOverrides["ENABLE_DEV_AUTH"] = "true";
        using var client = await factory.StartAsync();

        var response = await client.PostAsJsonAsync("/api/auth/dev", new { userId = "someone" });
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));

        // Regression test: this endpoint used to answer with a bare `return NotFound();`, which
        // [ApiController]'s automatic client-error handling turns into ASP.NET's own
        // ProblemDetails body (title/status/traceId) instead of this API's uniform
        // {"slug","message"} shape used by every other error response.
        Assert.That(body, Does.Contain("\"slug\":\"not_found\""), $"body: {body}");
        Assert.That(body, Does.Not.Contain("\"traceId\""), $"body: {body}");
        Assert.That(body, Does.Not.Contain("\"title\""), $"body: {body}");
    }

    [Test]
    public async Task DevLogin_Returns404_ByDefault_EvenInDevelopment()
    {
        // ENABLE_DEV_AUTH must default to false; a factory that doesn't explicitly enable it
        // (Environment stays Development) must still 404.
        await using var factory = new TestWebApplicationFactory();
        factory.ConfigOverrides.Remove("ENABLE_DEV_AUTH");
        using var client = await factory.StartAsync();

        var response = await client.PostAsJsonAsync("/api/auth/dev", new { userId = "someone" });

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    [Test]
    public async Task DevLogin_Succeeds_WhenDevelopmentAndExplicitlyEnabled()
    {
        await using var factory = new TestWebApplicationFactory(); // Development + ENABLE_DEV_AUTH=true by default
        using var client = await factory.StartAsync();

        var response = await client.PostAsJsonAsync("/api/auth/dev", new { userId = "someone" });

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task Firebase_Returns503_WhenNotConfigured()
    {
        await using var factory = new TestWebApplicationFactory();
        // FakeFirebaseTokenVerifier defaults to IsConfigured = false.
        using var client = await factory.StartAsync();

        var response = await client.PostAsJsonAsync("/api/auth/firebase", new { firebaseToken = "anything-at-all" });
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable), $"body: {body}");
        Assert.That(body, Does.Contain("sign_in_not_configured"));
    }

    [Test]
    public async Task Firebase_ReturnsUnauthorized_WhenTokenFailsVerification()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.FirebaseVerifier.IsConfigured = true;
        factory.FirebaseVerifier.ThrowOnVerify = new InvalidOperationException("bad token");
        using var client = await factory.StartAsync();

        var response = await client.PostAsJsonAsync("/api/auth/firebase", new { firebaseToken = "not-a-real-token" });

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
    }

    [Test]
    public async Task GetCurrentUser_ReturnsUnauthorized_WithCommonErrorShape_WhenSubClaimIsNotAGuid()
    {
        // Regression test: GetCurrentUser's `if (userId == null) return Unauthorized();` branch
        // (reachable with a validly-signed token whose "sub" claim doesn't parse as a Guid - JWT
        // bearer auth itself only checks signature/issuer/audience/expiry) used to be a bare
        // Unauthorized(), which [ApiController] turns into ASP.NET's ProblemDetails body instead
        // of this API's {"slug","message"} shape.
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        var token = TestAuthHelper.MintTokenWithSub(factory, sub: "not-a-guid");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await client.GetAsync("/api/auth/me");
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized), $"body: {body}");
        Assert.That(body, Does.Contain("\"slug\":\"unauthorized\""), $"body: {body}");
        Assert.That(body, Does.Not.Contain("\"traceId\""), $"body: {body}");
    }

    [Test]
    public async Task GetCurrentUser_ReturnsNotFound_WithCommonErrorShape_WhenUserDoesNotExist()
    {
        // Regression test: same bug as above but for the `if (user == null) return NotFound();`
        // branch - reachable with a validly-signed token for a user id that was never created.
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        var token = TestAuthHelper.MintTokenWithSub(factory, sub: Guid.NewGuid().ToString());
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);

        var response = await client.GetAsync("/api/auth/me");
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound), $"body: {body}");
        Assert.That(body, Does.Contain("\"slug\":\"not_found\""), $"body: {body}");
        Assert.That(body, Does.Not.Contain("\"traceId\""), $"body: {body}");
    }

    [Test]
    public async Task Firebase_Succeeds_WhenConfiguredAndTokenValid()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.FirebaseVerifier.IsConfigured = true;
        factory.FirebaseVerifier.Result = new FirebaseVerificationResult("firebase-uid-123", "person@example.com", "Person Name");
        using var client = await factory.StartAsync();

        var response = await client.PostAsJsonAsync("/api/auth/firebase", new { firebaseToken = "a-real-looking-token" });
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK), $"body: {body}");
        Assert.That(body, Does.Contain("authToken"));
    }
}
