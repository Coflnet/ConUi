using System.Net;
using System.Net.Http.Json;

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
}
