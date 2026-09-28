using System.Net;

namespace RelationshipManager.Api.Tests;

public class HealthReadyTests
{
    [Test]
    public async Task Ready_ReturnsOk_WhenCassandraReachable()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.CassandraConnection.Reachable = true;
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/health/ready");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("\"cassandra\":true"));
    }

    [Test]
    public async Task Ready_Returns503_WhenCassandraUnreachable()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.CassandraConnection.Reachable = false;
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/health/ready");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        var body = await response.Content.ReadAsStringAsync();
        Assert.That(body, Does.Contain("\"cassandra\":false"));
    }

    [Test]
    public async Task Live_NeverTouchesCassandra()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.CassandraConnection.Reachable = false; // must not matter for liveness
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/health");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }
}
