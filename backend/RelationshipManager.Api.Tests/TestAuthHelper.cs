using System.Net.Http.Json;
using System.Text.Json;

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
}
