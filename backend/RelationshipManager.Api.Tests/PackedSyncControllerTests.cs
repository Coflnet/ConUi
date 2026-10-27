using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Tests;

public class PackedSyncControllerTests
{
    [Test]
    public async Task BatchRoutesRequireJwtButInvalidReadCapabilityIsAnonymous404()
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        Assert.That((await client.PostAsJsonAsync("/api/sync/upload/batch", new { entries = Array.Empty<object>() })).StatusCode,
            Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That((await client.PostAsJsonAsync("/api/sync/download/batch", new { entries = Array.Empty<object>() })).StatusCode,
            Is.EqualTo(HttpStatusCode.Unauthorized));
        var invalid = await client.GetAsync("/api/sync/packed/not-a-ticket");
        Assert.That(invalid.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That(invalid.Headers.CacheControl!.NoStore, Is.True);
    }

    [Test]
    public async Task ReaderCapabilityIsAdvertisedAndUploadFlagDefaultsOff()
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer",
            TestAuthHelper.MintTokenWithSub(factory, Guid.NewGuid().ToString()));
        var updates = await client.PostAsJsonAsync("/api/sync/updates", new { lastSyncVersion = 0 });
        var body = await updates.Content.ReadFromJsonAsync<JsonElement>();
        var caps = body.GetProperty("batching");
        Assert.That(caps.GetProperty("version").GetInt32(), Is.EqualTo(1));
        Assert.That(caps.GetProperty("maxEntries").GetInt32(), Is.EqualTo(128));
        Assert.That(caps.GetProperty("maxPayloadBytes").GetInt32(), Is.EqualTo(4194304));
        Assert.That(caps.GetProperty("canUploadPacks").GetBoolean(), Is.False);
        var upload = await client.PostAsJsonAsync("/api/sync/upload/batch", new { entries = Array.Empty<object>() });
        Assert.That(upload.StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That(await upload.Content.ReadAsStringAsync(), Does.Contain("packing_disabled"));
        var download = await client.PostAsJsonAsync("/api/sync/download/batch",
            new { entries = new[] { new { blobType = "person", blobId = "absent" } } });
        Assert.That(download.StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That(await download.Content.ReadAsStringAsync(), Does.Contain("blob_missing"));
    }
    [Test]
    public async Task AuthorizedBatchAndLegacyCapabilityReadSurviveDisabledUploadsAndRespectOwner()
    {
        var storage = new PackedSyncServiceTests.MemoryStorage();
        await using var factory = new TestWebApplicationFactory { Storage = storage };
        factory.ConfigOverrides["Sync:PackingEnabled"] = "true";
        factory.ConfigOverrides["jwt:issuer"] = "https://api.example.test";
        using var client = await factory.StartAsync();
        var owner = Guid.NewGuid();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer",
            TestAuthHelper.MintTokenWithSub(factory, owner.ToString()));
        var ciphertext = "con:v1:" + Convert.ToBase64String(new byte[40]);
        var entries = new[] { new { blobType = "person", blobId = "alice", checksum = new string('a', 64), data = ciphertext, isDeleted = false } };
        Assert.That((await client.PostAsJsonAsync("/api/sync/upload/batch", new { entries })).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        var download = await client.PostAsJsonAsync("/api/sync/download/batch", new { entries });
        var body = await download.Content.ReadFromJsonAsync<PackedDownloadResponse>();
        Assert.That(body!.Entries.Single().Data, Is.EqualTo(ciphertext));
        var legacy = await client.GetFromJsonAsync<BlobDownloadResponse>("/api/sync/download/person/alice");
        var slice = new Uri(legacy!.DownloadUrl);
        factory.Configuration["Sync:PackingEnabled"] = "false";
        Assert.That((await client.PostAsJsonAsync("/api/sync/upload/batch", new { entries })).StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        client.DefaultRequestHeaders.Authorization = null;
        Assert.That(await client.GetStringAsync(slice.PathAndQuery), Is.EqualTo(ciphertext));
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", slice.Segments.Last());
        Assert.That((await client.GetAsync("/api/sync/all")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized),
            "An encrypted-slice capability must never authenticate app API access.");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer",
            TestAuthHelper.MintTokenWithSub(factory, Guid.NewGuid().ToString()));
        Assert.That((await client.PostAsJsonAsync("/api/sync/download/batch", new { entries })).StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That((await client.GetAsync("/api/sync/download/person/alice")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That(storage.Objects, Has.Count.EqualTo(1));
    }

}
