using System.IdentityModel.Tokens.Jwt;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Microsoft.IdentityModel.Tokens;

namespace RelationshipManager.Api.Tests;

/// <summary>Gets a bearer token through the real dev-login endpoint (requires ENABLE_DEV_AUTH=true).</summary>
public static class TestAuthHelper
{
    public static async Task<string> GetDevTokenAsync(HttpClient client, string userId = "test-user")
    {
        var response = await client.PostAsJsonAsync("/api/auth/dev", new { userId });
        response.EnsureSuccessStatusCode();
        var body = await response.Content.ReadAsStringAsync();
        using var doc = JsonDocument.Parse(body);
        return doc.RootElement.GetProperty("authToken").GetString()!;
    }

    /// <summary>
    /// Builds a validly-signed JWT (same issuer/secret as <paramref name="factory"/>'s config
    /// overrides, same shape as <see cref="Auth.AuthService.CreateTokenFor"/>) with an arbitrary
    /// "sub" claim value - including one that isn't a parseable <see cref="Guid"/>, or none at
    /// all when <paramref name="sub"/> is null. Used to reach the "authenticated, but the sub
    /// claim doesn't identify a real user" branches in controllers (a token like this can occur
    /// with a malformed/forged claim; [Authorize] alone lets it through since it only checks the
    /// signature/issuer/audience/expiry, not what "sub" contains).
    /// </summary>
    public static string MintTokenWithSub(TestWebApplicationFactory factory, string? sub)
    {
        var issuer = factory.ConfigOverrides["jwt:issuer"];
        var secret = factory.ConfigOverrides["jwt:secret"];
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(secret!));
        var credentials = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);

        var claims = new List<Claim> { new(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString()) };
        if (sub != null)
        {
            claims.Add(new Claim(JwtRegisteredClaimNames.Sub, sub));
        }

        var token = new JwtSecurityToken(issuer, issuer, claims, expires: DateTime.UtcNow.AddMinutes(5), signingCredentials: credentials);
        return new JwtSecurityTokenHandler().WriteToken(token);
    }
}
