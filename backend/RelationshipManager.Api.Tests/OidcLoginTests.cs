using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Tests;

public class OidcLoginTests
{
    private const string Issuer = "https://identity.example.test/auth/realms/con";
    private const string ClientId = "con-app";
    private const string Audience = "con-api";

    private sealed class DiscoveryHandler : HttpMessageHandler
    {
        private readonly object _publicKey;
        public int DiscoveryRequests { get; private set; }
        public int KeyRequests { get; private set; }
        public bool Unavailable { get; set; }
        public string DiscoveryIssuer { get; set; } = Issuer;

        public DiscoveryHandler(RSA rsa)
        {
            var key = rsa.ExportParameters(false);
            _publicKey = new { kty = "RSA", kid = "test-key", use = "sig", alg = "RS256",
                n = Base64UrlEncoder.Encode(key.Modulus!), e = Base64UrlEncoder.Encode(key.Exponent!) };
        }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (Unavailable) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));
            object document;
            if (request.RequestUri!.AbsoluteUri == Issuer + "/.well-known/openid-configuration")
            {
                DiscoveryRequests++;
                document = new { issuer = DiscoveryIssuer, jwks_uri = Issuer + "/protocol/openid-connect/certs" };
            }
            else if (request.RequestUri.AbsoluteUri == Issuer + "/protocol/openid-connect/certs")
            {
                KeyRequests++;
                document = new { keys = new[] { _publicKey } };
            }
            else throw new InvalidOperationException("Unexpected discovery request URL.");
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(JsonSerializer.Serialize(document), Encoding.UTF8, "application/json")
            });
        }
    }

    private static TestWebApplicationFactory CreateFactory(DiscoveryHandler handler)
    {
        var factory = new TestWebApplicationFactory { OidcHttpHandler = handler, Environment = "Production" };
        factory.ConfigOverrides["Oidc:Issuer"] = Issuer;
        factory.ConfigOverrides["Oidc:ClientId"] = ClientId;
        factory.ConfigOverrides["Oidc:Audience"] = Audience;
        return factory;
    }

    private static string MintToken(RSA rsa, string invalid = "", string subject = "provider-user")
    {
        SecurityKey key = invalid == "symmetric"
            ? new SymmetricSecurityKey(Encoding.UTF8.GetBytes("test-only-wrong-symmetric-signing-key-123456"))
            : new RsaSecurityKey(rsa);
        key.KeyId = "test-key";
        var algorithm = invalid == "algorithm" ? SecurityAlgorithms.RsaSha512
            : invalid == "symmetric" ? SecurityAlgorithms.HmacSha256 : SecurityAlgorithms.RsaSha256;
        var claims = new List<Claim>
        {
            new("azp", invalid == "azp" ? "another-app" : ClientId),
            new("name", "Anna"), new("email", "anna@example.test"),
            new("email_verified", "true", ClaimValueTypes.Boolean)
        };
        if (invalid != "subject") claims.Add(new Claim("sub", subject));
        if (invalid == "missing_azp") claims.RemoveAll(c => c.Type == "azp");
        var jwt = new JwtSecurityToken(
            issuer: invalid == "issuer" ? "https://wrong.example.test/realms/con" : Issuer,
            audience: invalid == "audience" ? ClientId : invalid == "audience_slash" ? Audience + "/" : Audience,
            claims: claims, notBefore: DateTime.UtcNow.AddMinutes(-10),
            expires: invalid == "expired" ? DateTime.UtcNow.AddMinutes(-1) : DateTime.UtcNow.AddMinutes(5),
            signingCredentials: invalid == "unsigned" ? null : new SigningCredentials(key, algorithm));
        if (invalid == "no_expiry") jwt.Payload.Remove("exp");
        return new JwtSecurityTokenHandler().WriteToken(jwt);
    }

    [Test]
    public async Task MissingConfiguration_DisablesLogin_AndExposesNoDefaults()
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        var config = await client.GetFromJsonAsync<JsonElement>("/api/auth/config");
        Assert.That(config.GetProperty("enabled").GetBoolean(), Is.False);
        Assert.That(config.GetProperty("issuer").ValueKind, Is.EqualTo(JsonValueKind.Null));
        Assert.That(config.GetProperty("clientId").ValueKind, Is.EqualTo(JsonValueKind.Null));
        var response = await client.PostAsJsonAsync("/api/auth/oidc", new { accessToken = "anything" });
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("sign_in_not_configured"));
    }

    [Test]
    public async Task ValidLogin_UsesRealSignature_CachesDiscovery_AndPreservesUserAndSalt()
    {
        using var rsa = RSA.Create(2048);
        var handler = new DiscoveryHandler(rsa);
        await using var factory = CreateFactory(handler);
        using var client = await factory.StartAsync();
        var config = await client.GetFromJsonAsync<JsonElement>("/api/auth/config");
        Assert.That(config.GetProperty("enabled").GetBoolean(), Is.True);
        Assert.That(config.GetProperty("issuer").GetString(), Is.EqualTo(Issuer));
        Assert.That(config.GetProperty("clientId").GetString(), Is.EqualTo(ClientId));
        Assert.That(config.EnumerateObject().Count(), Is.EqualTo(3));
        User? first = null;
        for (var i = 0; i < 2; i++)
        {
            var response = await client.PostAsJsonAsync("/api/auth/oidc", new { accessToken = MintToken(rsa) });
            Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK), await response.Content.ReadAsStringAsync());
            var token = (await response.Content.ReadFromJsonAsync<TokenContainer>())!;
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token.AuthToken);
            var user = (await client.GetFromJsonAsync<User>("/api/auth/me"))!;
            Assert.That(user.Id, Is.Not.EqualTo(Guid.Empty));
            Assert.That(user.Name, Is.EqualTo("Anna"));
            Assert.That(user.Email, Is.EqualTo("anna@example.test"));
            Assert.That(Convert.FromBase64String(user.EncryptionKeySalt!), Has.Length.EqualTo(32));
            Assert.That(user.AuthProviderId, Is.EqualTo("oidc:" + JsonSerializer.Serialize(new[] { Issuer, "provider-user" })));
            if (first != null)
            {
                Assert.That(user.Id, Is.EqualTo(first.Id));
                Assert.That(user.EncryptionKeySalt, Is.EqualTo(first.EncryptionKeySalt));
            }
            first = user;
        }
        Assert.That(handler.DiscoveryRequests, Is.EqualTo(1));
        Assert.That(handler.KeyRequests, Is.EqualTo(1));
        var forbiddenDev = await client.PostAsJsonAsync("/api/auth/dev", new { userId = "someone" });
        Assert.That(forbiddenDev.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    [TestCase("signature")]
    [TestCase("issuer")]
    [TestCase("audience")]
    [TestCase("audience_slash")]
    [TestCase("expired")]
    [TestCase("no_expiry")]
    [TestCase("azp")]
    [TestCase("missing_azp")]
    [TestCase("subject")]
    [TestCase("unsigned")]
    [TestCase("symmetric")]
    [TestCase("algorithm")]
    [TestCase("malformed")]
    public async Task InvalidTokens_AreRejected_WithoutCreatingAUser(string invalid)
    {
        using var rsa = RSA.Create(2048);
        using var wrong = RSA.Create(2048);
        await using var factory = CreateFactory(new DiscoveryHandler(rsa));
        using var client = await factory.StartAsync();
        var token = invalid == "malformed" ? "not.a.token" : MintToken(invalid == "signature" ? wrong : rsa, invalid);
        var response = await client.PostAsJsonAsync("/api/auth/oidc", new { accessToken = token });
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized), await response.Content.ReadAsStringAsync());
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("invalid_token"));
        Assert.That(await factory.UserStore.GetByAuthProviderIdAsync("oidc:" + JsonSerializer.Serialize(new[] { Issuer, "provider-user" })), Is.Null);
    }

    [TestCase(true)]
    [TestCase(false)]
    public async Task DiscoveryFailure_IsUnavailable_InsteadOfAcceptingToken(bool unavailable)
    {
        using var rsa = RSA.Create(2048);
        var handler = new DiscoveryHandler(rsa) { Unavailable = unavailable, DiscoveryIssuer = "https://wrong.example.test" };
        await using var factory = CreateFactory(handler);
        using var client = await factory.StartAsync();
        var response = await client.PostAsJsonAsync("/api/auth/oidc", new { accessToken = MintToken(rsa) });
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("sign_in_unavailable"));
    }
}
