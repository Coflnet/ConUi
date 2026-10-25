using Microsoft.AspNetCore.Builder;
using System.Net;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace RelationshipManager.Api.Tests;

[NonParallelizable]
public class ReverseProxyTrustTests
{
    private static IConfiguration Config(params (string Key, string Value)[] values) =>
        new ConfigurationBuilder().AddInMemoryCollection(values.ToDictionary(v => v.Key, v => (string?)v.Value)).Build();

    /// <summary>Runs a request from <paramref name="peer"/> through the real forwarded-headers middleware configured like the app.</summary>
    private static async Task<IPAddress?> RemoteIpAfterMiddleware(IConfiguration config, string peer, string forwardedFor = "203.0.113.7")
    {
        var (proxies, networks) = ReverseProxyTrust.Parse(config);
        var options = new ForwardedHeadersOptions { ForwardedHeaders = ForwardedHeaders.XForwardedFor, ForwardLimit = 1 };
        ReverseProxyTrust.Apply(options, proxies, networks);
        var middleware = new ForwardedHeadersMiddleware(_ => Task.CompletedTask, NullLoggerFactory.Instance, Options.Create(options));
        var context = new DefaultHttpContext();
        context.Connection.RemoteIpAddress = IPAddress.Parse(peer);
        context.Request.Headers["X-Forwarded-For"] = forwardedFor;
        await middleware.Invoke(context);
        return context.Connection.RemoteIpAddress;
    }

    [Test]
    public async Task PeerInsideKnownNetwork_GetsForwardedClientIp()
    {
        var config = Config(("ReverseProxy:KnownNetworks:0", "10.244.0.0/16"));
        Assert.That(await RemoteIpAfterMiddleware(config, "10.244.3.9"), Is.EqualTo(IPAddress.Parse("203.0.113.7")));
    }

    [Test]
    public async Task PeerOutsideKnownNetwork_IsNotTrusted()
    {
        var config = Config(("ReverseProxy:KnownNetworks:0", "10.244.0.0/16"));
        Assert.That(await RemoteIpAfterMiddleware(config, "10.245.0.1"), Is.EqualTo(IPAddress.Parse("10.245.0.1")));
    }

    [Test]
    public async Task KnownProxies_StillWorkWithoutNetworks()
    {
        var config = Config(("ReverseProxy:KnownProxies:0", "10.1.2.3"));
        Assert.That(await RemoteIpAfterMiddleware(config, "10.1.2.3"), Is.EqualTo(IPAddress.Parse("203.0.113.7")));
        Assert.That(await RemoteIpAfterMiddleware(config, "10.1.2.4"), Is.EqualTo(IPAddress.Parse("10.1.2.4")));
    }

    [Test]
    public async Task ProxiesAndNetworks_AreCombined()
    {
        var config = Config(("ReverseProxy:KnownProxies:0", "192.168.1.5"), ("ReverseProxy:KnownNetworks:0", "10.244.0.0/16"));
        Assert.That(await RemoteIpAfterMiddleware(config, "192.168.1.5"), Is.EqualTo(IPAddress.Parse("203.0.113.7")));
        Assert.That(await RemoteIpAfterMiddleware(config, "10.244.0.2"), Is.EqualTo(IPAddress.Parse("203.0.113.7")));
    }

    [Test]
    public async Task NothingConfigured_TrustsNobody()
    {
        Assert.That(await RemoteIpAfterMiddleware(Config(), "10.244.3.9"), Is.EqualTo(IPAddress.Parse("10.244.3.9")));
    }

    [TestCase("10.244.0.0")]
    [TestCase("10.244.0.0/")]
    [TestCase("10.244.0.0/33")]
    [TestCase("10.244.0.0/-1")]
    [TestCase("10.244.0.0/abc")]
    [TestCase("10.244.0.0/0")]
    [TestCase("::/0")]
    [TestCase("fd00::/129")]
    [TestCase("not-an-ip/16")]
    [TestCase("")]
    public void InvalidNetwork_RefusesStartup(string entry)
    {
        var ex = Assert.Throws<InvalidOperationException>(() => RelationshipManagerApp.Build([], builder =>
            builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["jwt:secret"] = "test-only-secret-that-is-at-least-32-characters",
                ["ReverseProxy:KnownNetworks:0"] = entry
            }), environmentName: "Development"));
        Assert.That(ex!.Message, Does.Contain("ReverseProxy:KnownNetworks"));
    }

    [Test]
    public void InvalidProxy_RefusesStartup()
    {
        var ex = Assert.Throws<InvalidOperationException>(() => ReverseProxyTrust.Parse(Config(("ReverseProxy:KnownProxies:0", "nope"))));
        Assert.That(ex!.Message, Does.Contain("ReverseProxy:KnownProxies"));
    }

    [Test]
    public async Task ValidNetworkAndIpv6_BuildsApp()
    {
        await using var app = RelationshipManagerApp.Build([], builder =>
            builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["jwt:secret"] = "test-only-secret-that-is-at-least-32-characters",
                ["ReverseProxy:KnownNetworks:0"] = "10.244.0.0/16",
                ["ReverseProxy:KnownNetworks:1"] = "fd00::/8"
            }), environmentName: "Development");
        Assert.That(app, Is.Not.Null);
    }
}
