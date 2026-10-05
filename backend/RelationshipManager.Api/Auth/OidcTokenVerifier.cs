using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using System.Text.Json;

namespace RelationshipManager.Api.Auth;

public sealed record OidcIdentity(string ProviderId, string? Name, string? Email, string? AlternateProviderId = null);

public sealed class OidcTokenVerifier
{
    private readonly OidcSettings _settings;
    private readonly ConfigurationManager<OpenIdConnectConfiguration>? _configuration;
    private readonly JsonWebTokenHandler _handler = new() { MapInboundClaims = false };

    public OidcTokenVerifier(OidcSettings settings, IHttpClientFactory clients)
    {
        _settings = settings;
        if (settings.Enabled)
        {
            _configuration = new ConfigurationManager<OpenIdConnectConfiguration>(
                settings.Issuer + "/.well-known/openid-configuration",
                new OpenIdConnectConfigurationRetriever(),
                new HttpDocumentRetriever(clients.CreateClient("oidc")) { RequireHttps = settings.RequireHttps });
        }
    }

    public async Task<OidcIdentity> VerifyAsync(string accessToken, CancellationToken cancellationToken)
    {
        if (_configuration == null) throw new InvalidOperationException("OIDC is not configured.");
        var configuration = await _configuration.GetConfigurationAsync(cancellationToken)
            .WaitAsync(TimeSpan.FromSeconds(8), cancellationToken);
        if (configuration.Issuer != _settings.Issuer)
            throw new InvalidOperationException("OIDC discovery issuer does not match server configuration.");
        var result = await _handler.ValidateTokenAsync(accessToken, new TokenValidationParameters
        {
            RequireSignedTokens = true,
            RequireExpirationTime = true,
            ValidateIssuerSigningKey = true,
            IssuerSigningKeys = configuration.SigningKeys,
            ValidAlgorithms = new[] { SecurityAlgorithms.RsaSha256 },
            ValidateIssuer = true,
            ValidIssuer = _settings.Issuer,
            IssuerValidator = (issuer, _, _) => _settings.AcceptsIssuer(issuer) ? issuer
                : throw new SecurityTokenInvalidIssuerException("Untrusted or expired issuer transition."),
            ValidateAudience = true,
            ValidAudience = _settings.Audience,
            IgnoreTrailingSlashWhenValidatingAudience = false,
            ValidateLifetime = true,
            ClockSkew = TimeSpan.Zero
        });
        if (!result.IsValid)
        {
            if (result.Exception is SecurityTokenSignatureKeyNotFoundException)
                _configuration.RequestRefresh();
            throw new SecurityTokenException("OIDC access token verification failed.");
        }
        var claims = result.ClaimsIdentity;
        var azp = claims.FindAll("azp").ToArray();
        var subjects = claims.FindAll("sub").ToArray();
        if (azp.Length != 1 || azp[0].Value != _settings.ClientId
            || subjects.Length != 1 || string.IsNullOrWhiteSpace(subjects[0].Value))
            throw new SecurityTokenException("OIDC subject or authorized party is invalid.");

        // Namespace by both issuer and subject. Never link identities by email.
        var providerId = "oidc:" + JsonSerializer.Serialize(new[] { _settings.AccountNamespaceIssuer, subjects[0].Value });
        var email = claims.FindFirst("email_verified")?.Value == "true" ? claims.FindFirst("email")?.Value : null;
        var alternate = _settings.AccountNamespaceIssuer != _settings.Issuer
            ? "oidc:" + JsonSerializer.Serialize(new[] { _settings.Issuer, subjects[0].Value }) : null;
        return new OidcIdentity(providerId, claims.FindFirst("name")?.Value, email, alternate);
    }
}
