using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Tests;

public class SyncCommitAuthorizationTests
{
    private static readonly Guid Owner = Guid.Parse("11111111-1111-1111-1111-111111111111");

    [TestCase("22222222-2222-2222-2222-222222222222/person/p1_123")]
    [TestCase("11111111-1111-1111-1111-111111111111-extra/person/p1_123")]
    [TestCase("11111111-1111-1111-1111-111111111111/place/p1_123")]
    [TestCase("11111111-1111-1111-1111-111111111111/person/p10_123")]
    [TestCase("11111111-1111-1111-1111-111111111111/person/p1_extra_123")]
    [TestCase("11111111-1111-1111-1111-111111111111/person/p1_0")]
    [TestCase("11111111-1111-1111-1111-111111111111/person/p1_0123")]
    [TestCase("11111111-1111-1111-1111-111111111111/person/p1_123/other")]
    public async Task Commit_RejectsKeysOutsideExactUserAndBlob(string key)
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TestAuthHelper.MintTokenWithSub(factory, Owner.ToString()));

        var response = await client.PostAsJsonAsync("/api/sync/commit", new CommitEntry
        {
            BlobType = "person", BlobId = "p1", S3Key = key, Size = 42
        });

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(await response.Content.ReadAsStringAsync(), Does.Contain("invalid_blob_key"));
        Assert.That(await factory.SyncStore.GetUserObjectsAsync(Owner), Is.Empty);
        Assert.That(await factory.SyncStore.GetSyncEntriesAsync(Owner), Is.Empty);
        Assert.That(await factory.SyncStore.GetStorageLimitAsync(Owner), Is.Null);
        Assert.That((await client.GetAsync("/api/sync/download/person/p1")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    [TestCase("11111111-1111-1111-1111-111111111111/person/p1")]
    [TestCase("11111111-1111-1111-1111-111111111111/person/p1_123")]
    public async Task Commit_AcceptsExactProxyOrPresignedKeyAndDeleteStillWorks(string key)
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TestAuthHelper.MintTokenWithSub(factory, Owner.ToString()));
        var response = await client.PostAsJsonAsync("/api/sync/commit", new CommitEntry
        {
            BlobType = "person", BlobId = "p1", S3Key = key, Size = 42
        });
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That((await factory.SyncStore.GetUserObjectAsync(Owner, "person", "p1"))!.S3Key, Is.EqualTo(key));
        Assert.That((await client.DeleteAsync("/api/sync/person/p1")).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That((await factory.SyncStore.GetUserObjectAsync(Owner, "person", "p1"))!.IsDeleted, Is.True);
    }

    [TestCase("../person", "p1")]
    [TestCase("person", "../p1")]
    [TestCase("person", "p1/other")]
    [TestCase("person", "p1\\other")]
    [TestCase("person", "%2e%2e")]
    public async Task UploadAndCommit_RejectUnsafeKeySegments(string blobType, string blobId)
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TestAuthHelper.MintTokenWithSub(factory, Owner.ToString()));
        var upload = await client.PostAsJsonAsync("/api/sync/upload", new BlobUploadRequest { BlobType = blobType, BlobId = blobId });
        Assert.That(upload.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        var commit = await client.PostAsJsonAsync("/api/sync/commit", new CommitEntry
        {
            BlobType = blobType, BlobId = blobId, S3Key = $"{Owner}/{blobType}/{blobId}_123"
        });
        Assert.That(commit.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(await factory.SyncStore.GetUserObjectsAsync(Owner), Is.Empty);
    }

    [Test]
    public async Task BatchCommit_CannotBypassKeyOwnershipCheck()
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TestAuthHelper.MintTokenWithSub(factory, Owner.ToString()));
        var response = await client.PostAsJsonAsync("/api/sync/commit/batch", new BatchCommitRequest
        {
            Entries = [new CommitEntry { BlobType = "person", BlobId = "p1", S3Key = $"{Guid.NewGuid()}/person/p1_123" }]
        });
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That(await factory.SyncStore.GetUserObjectsAsync(Owner), Is.Empty);
    }
}
