using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Tests;

/// <summary>
/// Regression coverage for: S3Service used to connect synchronously in its constructor, which
/// meant the whole app failed to start without a reachable S3. Now it starts fine and S3-backed
/// endpoints answer 503 instead.
/// </summary>
public class SyncControllerStorageTests
{
    [Test]
    public async Task GetUploadUrl_Returns503_WhenS3NotConfigured()
    {
        await using var factory = new TestWebApplicationFactory();
        // TestWebApplicationFactory leaves S3:* blank by default (not configured).
        using var client = await factory.StartAsync();
        var token = await TestAuthHelper.GetDevTokenAsync(client);
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

        var response = await client.PostAsJsonAsync("/api/sync/upload", new
        {
            blobType = "person",
            blobId = Guid.NewGuid().ToString(),
            checksum = "abc",
            expectedVersion = 0
        });

        var body = await response.Content.ReadAsStringAsync();
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable), $"body: {body}");
        Assert.That(body, Does.Contain("storage_unavailable"));
    }

    [Test]
    public async Task ProxyUpload_VersionConflict_UsesUniformErrorShape()
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        var token = await TestAuthHelper.GetDevTokenAsync(client);
        client.DefaultRequestHeaders.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);

        var me = await client.GetFromJsonAsync<JsonElement>("/api/auth/me");
        var userId = Guid.Parse(me.GetProperty("id").GetString()!);

        // Seed an existing object with a version newer than what we're about to "upload".
        await factory.SyncStore.UpsertUserObjectAsync(new RelationshipManager.Api.Models.UserObject
        {
            UserId = userId,
            BlobType = "person",
            BlobId = "p1",
            S3Key = "irrelevant",
            Version = 999,
            Size = 1,
            CreatedAt = DateTime.UtcNow,
            UpdatedAt = DateTime.UtcNow
        });

        var response = await client.PostAsync("/api/sync/proxy-upload/person/p1?version=1", new ByteArrayContent(new byte[] { 1, 2, 3 }));
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Conflict), $"body: {body}");
        Assert.That(body, Does.Contain("\"slug\":\"version_conflict\""));
    }
}
