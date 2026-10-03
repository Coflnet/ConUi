namespace RelationshipManager.Api.Auth;

/// <summary>Server-owned public configuration; clients cannot supply an authority.</summary>
public sealed class OidcSettings
{
    public string? Issuer { get; }
    public string? ClientId { get; }
    public string? Audience { get; }
    public bool Enabled => Issuer != null;
    public bool RequireHttps { get; } = true;

    public OidcSettings(IConfiguration config, IHostEnvironment environment)
    {
        Issuer = config["Oidc:Issuer"];
        ClientId = config["Oidc:ClientId"];
        Audience = config["Oidc:Audience"];
        if (string.IsNullOrWhiteSpace(Issuer) && string.IsNullOrWhiteSpace(ClientId) && string.IsNullOrWhiteSpace(Audience))
        {
            Issuer = ClientId = Audience = null;
            return;
        }
        if (string.IsNullOrWhiteSpace(ClientId) || string.IsNullOrWhiteSpace(Audience)
            || !Uri.TryCreate(Issuer, UriKind.Absolute, out var uri)
            || !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query)
            || !string.IsNullOrEmpty(uri.Fragment) || Issuer!.EndsWith('/'))
            throw new InvalidOperationException("Oidc:Issuer, ClientId and Audience must be configured together with a valid issuer URL.");

        RequireHttps = !(environment.IsDevelopment()
            && config.GetValue("Oidc:AllowInsecureLocalhost", false)
            && uri.IsLoopback && uri.Scheme == Uri.UriSchemeHttp);
        if (RequireHttps && uri.Scheme != Uri.UriSchemeHttps)
            throw new InvalidOperationException("OIDC requires HTTPS; HTTP loopback is allowed only explicitly in Development.");
    }
}
