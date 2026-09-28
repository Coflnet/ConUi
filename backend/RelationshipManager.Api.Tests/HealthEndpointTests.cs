using System.Net;

namespace RelationshipManager.Api.Tests;

public class HealthEndpointTests
{
    [Test]
    public async Task Health_ReturnsOk_WithoutTouchingDependencies()
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/health");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }
}
