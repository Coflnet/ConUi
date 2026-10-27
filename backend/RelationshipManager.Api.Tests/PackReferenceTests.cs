using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using Microsoft.Extensions.Configuration;
using RelationshipManager.Api.Models;
using RelationshipManager.Api.Services;

namespace RelationshipManager.Api.Tests;

public class PackReferenceTests
{
    private const string Id = "0123456789abcdef0123456789abcdef";
    private const string Secret = "test-only-secret-key-that-is-at-least-32-characters!";

    [TestCase("pack:v1:0123456789abcdef0123456789abcdef:0:1", true)]
    [TestCase("pack:v1:0123456789abcdef0123456789abcdef:4194303:1", true)]
    [TestCase("pack:v1:0123456789abcdef0123456789abcdef:4194304:1", false)]
    [TestCase("pack:v1:0123456789abcdef0123456789abcdef:0:0", false)]
    [TestCase("pack:v1:0123456789ABCDEF0123456789abcdef:0:1", false)]
    [TestCase("pack:v1:../other:0:1", false)]
    [TestCase("pack:v1:0123456789abcdef0123456789abcdef:01:1", false)]
    [TestCase("pack:v1:0123456789abcdef0123456789abcdef:-1:1", false)]
    [TestCase("pack:v2:0123456789abcdef0123456789abcdef:0:1", false)]
    [TestCase("pack:v1:0123456789abcdef0123456789abcdef:9223372036854775807:1", false)]
    public void References_AreCanonicalAndBounded(string value, bool valid)
    {
        Assert.That(PackReference.TryParse(value, out var reference), Is.EqualTo(valid));
        if (valid) Assert.That(reference.ToString(), Is.EqualTo(value));
    }

    [TestCase("https://api.example.test", true)]
    [TestCase("http://localhost:8080/", true)]
    [TestCase("relationship-manager", false)]
    [TestCase("https://api.example.test/issuer", false)]
    [TestCase("https://user:password@api.example.test", false)]
    [TestCase("https://api.example.test/?redirect=elsewhere", false)]
    [TestCase("https://api.example.test/#fragment", false)]
    [TestCase("file:///tmp", false)]
    public void TicketUrls_RequireCanonicalHttpOrigin(string issuer, bool valid)
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["jwt:issuer"] = issuer }).Build();
        Assert.That(PackTickets.TryGetOrigin(config, out _), Is.EqualTo(valid));
    }

    [Test]
    public void Tickets_BindOwnerPackRangeAndExpiry_AndRejectTampering()
    {
        var now = DateTimeOffset.FromUnixTimeSeconds(1_800_000_000);
        var owner = Guid.NewGuid();
        var reference = new PackReference(Id, 100, 42);
        var ticket = PackTickets.Create(owner, reference, Secret, now);
        Assert.That(PackTickets.TryRead(ticket, Secret, now, out var decodedOwner, out var decodedReference), Is.True);
        Assert.That(decodedOwner, Is.EqualTo(owner));
        Assert.That(decodedReference, Is.EqualTo(reference));
        Assert.That(reference.PhysicalKey(owner), Is.EqualTo($"{owner}/.packs/v1/{Id}"));
        Assert.That(PackTickets.TryRead(ticket, Secret, now.AddMinutes(15), out _, out _), Is.False);
        Assert.That(PackTickets.TryRead(ticket, "wrong-key", now, out _, out _), Is.False);
        for (var index = 0; index < ticket.Length; index++)
        {
            var modified = ticket.ToCharArray();
            modified[index] = modified[index] == 'A' ? 'B' : 'A';
            Assert.That(PackTickets.TryRead(new string(modified), Secret, now, out _, out _), Is.False, $"byte {index}");
        }
        Assert.That(PackTickets.TryRead("%invalid", Secret, now, out _, out _), Is.False);
    }

    [Test]
    public async Task Updates_ReturnOnlyLatestLogicalEntry_PreservingTombstonesAndCursor()
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();
        var owner = Guid.NewGuid();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TestAuthHelper.MintTokenWithSub(factory, owner.ToString()));
        foreach (var entry in new[]
        {
            new SyncEntry { UserId = owner, BlobType = "person", BlobId = "p1", Version = 10 },
            new SyncEntry { UserId = owner, BlobType = "person", BlobId = "p1", Version = 20, IsDeleted = true },
            new SyncEntry { UserId = owner, BlobType = "place", BlobId = "p1", Version = 30 }
        }) await factory.SyncStore.InsertSyncEntryAsync(entry);
        var response = await client.PostAsJsonAsync("/api/sync/updates", new SyncRequest());
        var updates = await response.Content.ReadFromJsonAsync<SyncResponse>();
        Assert.That(updates!.LatestVersion, Is.EqualTo(30));
        Assert.That(updates.Entries, Has.Count.EqualTo(2));
        var person = updates.Entries.Single(e => e.BlobType == "person");
        Assert.That(person.Version, Is.EqualTo(20));
        Assert.That(person.IsDeleted, Is.True);
    }

    [Test]
    public async Task PackedEntries_KeepLegacyDownloadUrlAndDeletion_WhileOrdinaryCommitRejectsReferences()
    {
        await using var factory = new TestWebApplicationFactory();
        factory.ConfigOverrides["jwt:issuer"] = "https://api.example.test";
        using var client = await factory.StartAsync();
        var owner = Guid.NewGuid();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", TestAuthHelper.MintTokenWithSub(factory, owner.ToString()));
        var reference = new PackReference(Id, 5, 42);
        var commit = new CommitEntry { BlobType = "person", BlobId = "p1", S3Key = reference.ToString(), Size = 42 };
        Assert.That((await client.PostAsJsonAsync("/api/sync/commit", commit)).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        await factory.SyncStore.UpsertUserObjectAsync(new UserObject
        {
            UserId = owner, BlobType = "person", BlobId = "p1", S3Key = reference.ToString(), Size = 42
        });
        var download = await client.GetFromJsonAsync<BlobDownloadResponse>("/api/sync/download/person/p1");
        var url = new Uri(download!.DownloadUrl);
        Assert.That(url.GetLeftPart(UriPartial.Authority), Is.EqualTo("https://api.example.test"));
        Assert.That(url.AbsolutePath, Does.StartWith("/api/sync/packed/"));
        Assert.That(PackTickets.TryRead(url.Segments.Last(), Secret, DateTimeOffset.UtcNow, out var ticketOwner, out var ticketReference), Is.True);
        Assert.That(ticketOwner, Is.EqualTo(owner));
        Assert.That(ticketReference, Is.EqualTo(reference));
        Assert.That((await client.DeleteAsync("/api/sync/person/p1")).StatusCode, Is.EqualTo(HttpStatusCode.OK));
        var deleted = await factory.SyncStore.GetUserObjectAsync(owner, "person", "p1");
        Assert.That(deleted!.IsDeleted, Is.True);
        Assert.That(deleted.S3Key, Is.EqualTo(reference.ToString()));
        Assert.That((await client.GetAsync("/api/sync/download/person/p1")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }
}
