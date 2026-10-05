namespace RelationshipManager.Api.Auth;

/// <summary>Server-owned public configuration; clients cannot supply an authority.</summary>
public sealed class OidcSettings
{
    public string? Issuer { get; }
    public string? ClientId { get; }
    public string? Audience { get; }
    public const string OldIssuer = "https://app.rfind.de/auth/realms/con";
    public const string NewIssuer = "https://auth.coflnet.com/auth/realms/con";
    public string? AccountNamespaceIssuer { get; }
    private readonly DateTimeOffset? _migrationStart, _migrationDeadline;
    public bool AcceptsIssuer(string issuer) => issuer == Issuer || issuer == OldIssuer && _migrationStart != null
        && DateTimeOffset.UtcNow >= _migrationStart && DateTimeOffset.UtcNow < _migrationDeadline;
    public bool Enabled => Issuer != null;
    public bool RequireHttps { get; } = true;

    public OidcSettings(IConfiguration config, IHostEnvironment environment)
    {
        Issuer = config["Oidc:Issuer"];
        ClientId = config["Oidc:ClientId"];
        Audience = config["Oidc:Audience"];
        AccountNamespaceIssuer = Issuer;
        var migration = config["Oidc:IssuerMigrationStartedAt"];
        if (!string.IsNullOrEmpty(migration))
        {
            if (Issuer != NewIssuer || !DateTimeOffset.TryParse(migration, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.None, out var started)
                || started.Offset != TimeSpan.Zero || !(migration.EndsWith('Z') || migration.EndsWith("+00:00"))
                || !int.TryParse(config["Oidc:MaxAccessTokenLifetimeSeconds"], out var lifetime) || lifetime is < 1 or > 86400)
                throw new InvalidOperationException("Issuer migration requires exact new issuer, UTC start and explicit access-token lifetime.");
            _migrationStart = started;
            _migrationDeadline = started.AddSeconds(lifetime + 600);
            // This stable ownership namespace remains after old JWT acceptance ends.
            AccountNamespaceIssuer = OldIssuer;
        }
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
