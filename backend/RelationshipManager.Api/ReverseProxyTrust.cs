using System.Net;
using Microsoft.AspNetCore.HttpOverrides;
using IPNetwork = Microsoft.AspNetCore.HttpOverrides.IPNetwork;

namespace RelationshipManager.Api;

/// <summary>
/// Builds the forwarded-header trust list from <c>ReverseProxy:KnownProxies</c> (single IPs) and
/// <c>ReverseProxy:KnownNetworks</c> (CIDR ranges such as <c>10.244.0.0/16</c>). Entries are
/// validated eagerly so a typo fails startup instead of silently trusting nobody (or, worse,
/// everybody).
/// </summary>
public static class ReverseProxyTrust
{
    public const string KnownProxiesKey = "ReverseProxy:KnownProxies";
    public const string KnownNetworksKey = "ReverseProxy:KnownNetworks";

    /// <summary>Parses and validates the configured proxies/networks. Throws <see cref="InvalidOperationException"/> on any invalid entry.</summary>
    public static (IReadOnlyList<IPAddress> Proxies, IReadOnlyList<IPNetwork> Networks) Parse(IConfiguration configuration)
    {
        var proxies = new List<IPAddress>();
        foreach (var entry in configuration.GetSection(KnownProxiesKey).Get<string[]>() ?? Array.Empty<string>())
        {
            if (!IPAddress.TryParse(entry?.Trim(), out var address))
                throw new InvalidOperationException($"{KnownProxiesKey} contains '{entry}', which is not a valid IP address.");
            proxies.Add(address);
        }

        var networks = new List<IPNetwork>();
        foreach (var entry in configuration.GetSection(KnownNetworksKey).Get<string[]>() ?? Array.Empty<string>())
            networks.Add(ParseNetwork(entry));

        return (proxies, networks);
    }

    /// <summary>
    /// Applies the configured trust to the options. With neither setting present nobody is trusted
    /// (ASP.NET otherwise treats an empty allowlist as trust-all).
    /// </summary>
    public static void Apply(ForwardedHeadersOptions options, IReadOnlyList<IPAddress> proxies, IReadOnlyList<IPNetwork> networks)
    {
        options.KnownNetworks.Clear();
        options.KnownProxies.Clear();
        foreach (var proxy in proxies)
            options.KnownProxies.Add(proxy);
        foreach (var network in networks)
            options.KnownNetworks.Add(network);
        if (options.KnownProxies.Count == 0 && options.KnownNetworks.Count == 0)
            options.KnownProxies.Add(IPAddress.None);
    }

    private static IPNetwork ParseNetwork(string? entry)
    {
        var parts = entry?.Trim().Split('/');
        if (parts is not { Length: 2 }
            || !IPAddress.TryParse(parts[0], out var address)
            || !int.TryParse(parts[1], System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var prefix))
            throw new InvalidOperationException($"{KnownNetworksKey} contains '{entry}', which is not a valid CIDR network such as 10.244.0.0/16.");

        var maxPrefix = address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork ? 32 : 128;
        // /0 would trust every address, which defeats the allowlist; require an explicit narrower range.
        if (prefix < 1 || prefix > maxPrefix)
            throw new InvalidOperationException($"{KnownNetworksKey} contains '{entry}': prefix length must be between 1 and {maxPrefix}.");

        return new IPNetwork(address, prefix);
    }
}
