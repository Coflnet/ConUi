namespace RelationshipManager.Api.Tests;

/// <summary>
/// Regression coverage for: CORS used to allow any origin unconditionally. Now origins come from
/// Cors:AllowedOrigins, empty means no cross-origin access, and Development additionally allows
/// localhost on any port.
/// </summary>
public class CorsTests
{
    [Test]
    public async Task AllowsConfiguredOrigin_OutsideDevelopment()
    {
        await using var factory = new TestWebApplicationFactory { Environment = "Production" };
        factory.ConfigOverrides["Cors:AllowedOrigins:0"] = "https://app.example.com";
        using var client = await factory.StartAsync();

        using var request = new HttpRequestMessage(HttpMethod.Get, "/health");
        request.Headers.Add("Origin", "https://app.example.com");
        var response = await client.SendAsync(request);

        Assert.That(response.Headers.Contains("Access-Control-Allow-Origin"), Is.True);
    }

    [Test]
    public async Task RejectsUnlistedOrigin_OutsideDevelopment()
    {
        await using var factory = new TestWebApplicationFactory { Environment = "Production" };
        factory.ConfigOverrides["Cors:AllowedOrigins:0"] = "https://app.example.com";
        using var client = await factory.StartAsync();

        using var request = new HttpRequestMessage(HttpMethod.Get, "/health");
        request.Headers.Add("Origin", "https://evil.example.com");
        var response = await client.SendAsync(request);

        Assert.That(response.Headers.Contains("Access-Control-Allow-Origin"), Is.False);
    }

    [Test]
    public async Task RejectsEverything_WhenNoOriginsConfigured_OutsideDevelopment()
    {
        await using var factory = new TestWebApplicationFactory { Environment = "Production" };
        factory.ConfigOverrides.Remove("Cors:AllowedOrigins:0");
        using var client = await factory.StartAsync();

        using var request = new HttpRequestMessage(HttpMethod.Get, "/health");
        request.Headers.Add("Origin", "https://app.example.com");
        var response = await client.SendAsync(request);

        Assert.That(response.Headers.Contains("Access-Control-Allow-Origin"), Is.False);
    }

    [Test]
    public async Task AllowsLocalhostOnAnyPort_InDevelopment()
    {
        await using var factory = new TestWebApplicationFactory(); // defaults to Development
        using var client = await factory.StartAsync();

        using var request = new HttpRequestMessage(HttpMethod.Get, "/health");
        request.Headers.Add("Origin", "http://localhost:54321");
        var response = await client.SendAsync(request);

        Assert.That(response.Headers.Contains("Access-Control-Allow-Origin"), Is.True);
    }
}
