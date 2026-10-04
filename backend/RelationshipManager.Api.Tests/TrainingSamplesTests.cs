using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using RelationshipManager.Api.Models;
using RelationshipManager.Api.Services;
using RelationshipManager.Api.Tests.Fakes;

namespace RelationshipManager.Api.Tests;

public sealed class TrainingSamplesTests
{
    private const string ReviewerToken = "test-reviewer-token-32-characters-minimum";
    private const string Day = "2026-10-04";
    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now = new(2026, 10, 4, 12, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }
    private static TestWebApplicationFactory Factory(Clock? clock = null)
    {
        var factory = new TestWebApplicationFactory { Clock = clock ?? new Clock() };
        factory.ConfigOverrides["TrainingSamples:ReviewerTokenHash"] = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ReviewerToken))).ToLowerInvariant();
        return factory;
    }
    private static TrainingSampleInput Input(Guid? id = null, bool consent = true, string? transcript = null) =>
        new(id ?? Guid.NewGuid(), consent, transcript ?? "Ada works at TestCo and knows Ben.", "Ben works at ExampleCo.", "en",
            [new("Ada", "TestCo", ["Works with Ben"]), new("Ben", null, [])], [new("Ada", "Ben", "colleague")]);
    private static byte[] Wav(int seconds = 1)
    {
        using var stream = new MemoryStream();
        using var writer = new BinaryWriter(stream);
        var size = seconds * 8000;
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(36 + size);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
        writer.Write((short)1); writer.Write((short)1); writer.Write(8000); writer.Write(8000);
        writer.Write((short)1); writer.Write((short)8);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(size); writer.Write(new byte[size]);
        return stream.ToArray();
    }
    private static MultipartFormDataContent Form(object metadata, byte[]? audio = null, string audioType = "audio/wav")
    {
        var form = new MultipartFormDataContent();
        form.Add(new StringContent(JsonSerializer.Serialize(metadata, new JsonSerializerOptions(JsonSerializerDefaults.Web)), Encoding.UTF8, "application/json"), "metadata");
        if (audio != null)
        {
            var content = new ByteArrayContent(audio);
            content.Headers.ContentType = new MediaTypeHeaderValue(audioType);
            form.Add(content, "audio", "story.wav");
        }
        return form;
    }
    private static async Task<HttpResponseMessage> Upload(HttpClient client, object input, byte[]? audio = null)
    {
        using var form = Form(input, audio);
        return await client.PostAsync("/api/training-samples", form);
    }
    private static void Review(HttpClient client) => client.DefaultRequestHeaders.Add("X-Training-Token", ReviewerToken);

    [Test]
    public async Task ExplicitReport_RoundTripsAudioAndOnlySubmittedExtraction_AndCanBeRemoved()
    {
        await using var factory = Factory();
        using var client = await factory.StartAsync();
        var input = Input();
        var audio = Wav();
        var response = await Upload(client, input, audio);
        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.Created));
        var receipt = JsonDocument.Parse(await response.Content.ReadAsStringAsync()).RootElement;
        Assert.That(receipt.GetProperty("id").GetGuid(), Is.EqualTo(input.SampleId));
        Assert.That(receipt.GetProperty("date").GetString(), Is.EqualTo(Day));
        Review(client);
        var list = await client.GetAsync($"/api/training-samples?date={Day}");
        Assert.That(list.Headers.CacheControl?.NoStore, Is.True);
        var page = (await list.Content.ReadFromJsonAsync<TrainingSamplePage>())!;
        Assert.That(page.Items, Has.Count.EqualTo(1));
        var sample = page.Items[0];
        Assert.That(sample.Transcript, Is.EqualTo(input.Transcript));
        Assert.That(sample.Correction, Is.EqualTo(input.Correction));
        Assert.That(sample.People.Select(p => p.Name), Is.EquivalentTo(new[] { "Ada", "Ben" }));
        Assert.That(sample.ConsentVersion, Is.EqualTo("1"));
        Assert.That(sample.AudioSize, Is.EqualTo(audio.Length));
        Assert.That(sample.AudioSha256, Is.EqualTo(Convert.ToHexString(SHA256.HashData(audio)).ToLowerInvariant()));
        var downloaded = await client.GetAsync($"/api/training-samples/{Day}/{input.SampleId}/audio");
        Assert.That(downloaded.Content.Headers.ContentType?.MediaType, Is.EqualTo("audio/wav"));
        Assert.That(await downloaded.Content.ReadAsByteArrayAsync(), Is.EqualTo(audio));
        Assert.That((await client.DeleteAsync($"/api/training-samples/{Day}/{input.SampleId}")).StatusCode, Is.EqualTo(HttpStatusCode.NoContent));
        Assert.That((await client.GetAsync($"/api/training-samples/{Day}/{input.SampleId}/audio")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That((await client.GetFromJsonAsync<TrainingSamplePage>($"/api/training-samples?date={Day}"))!.Items, Is.Empty);
    }

    [Test]
    public async Task IdenticalNames_PreserveBothReportedPeopleAndConnectionForHumanReview()
    {
        await using var factory = Factory();
        using var client = await factory.StartAsync();
        var input = Input() with
        {
            Transcript = "Alex Smith is Alex Smith's parent.",
            People = [new("Alex Smith", null, ["Parent"]), new("Alex Smith", null, ["Child"])],
            Connections = [new("Alex Smith", "Alex Smith", "parent")]
        };
        Assert.That((await Upload(client, input)).StatusCode, Is.EqualTo(HttpStatusCode.Created));
        Review(client);
        var sample = (await client.GetFromJsonAsync<TrainingSamplePage>($"/api/training-samples?date={Day}"))!.Items.Single();
        Assert.That(sample.People, Has.Count.EqualTo(2));
        Assert.That(sample.People.Select(p => p.Name), Is.EqualTo(new[] { "Alex Smith", "Alex Smith" }));
        Assert.That(sample.Connections.Single(), Is.EqualTo(input.Connections.Single()));
    }

    [Test]
    public async Task FailedRecognition_CanReportAudioWithoutTranscript_ButCannotReportAnEmptySample()
    {
        await using var factory = Factory();
        using var client = await factory.StartAsync();
        var input = Input(transcript: "") with { Correction = null, People = [], Connections = [] };
        Assert.That((await Upload(client, input, Wav())).StatusCode, Is.EqualTo(HttpStatusCode.Created));
        Assert.That((await Upload(client, Input(transcript: ""))).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await Upload(client, Input(transcript: " "))).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Review(client);
        var sample = (await client.GetFromJsonAsync<TrainingSamplePage>($"/api/training-samples?date={Day}"))!.Items.Single();
        Assert.That(sample.Transcript, Is.Empty);
        Assert.That(sample.AudioSize, Is.GreaterThan(0));
    }

    [Test]
    public async Task MetadataOnly_IdempotentRetry_ConflictAndReviewerPagination()
    {
        await using var factory = Factory();
        using var client = await factory.StartAsync();
        var input = Input();
        Assert.That((await Upload(client, input)).StatusCode, Is.EqualTo(HttpStatusCode.Created));
        Assert.That((await Upload(client, input)).StatusCode, Is.EqualTo(HttpStatusCode.Created));
        var conflict = await Upload(client, input with { Transcript = "Changed transcript" });
        Assert.That(conflict.StatusCode, Is.EqualTo(HttpStatusCode.Conflict));
        Assert.That(await conflict.Content.ReadAsStringAsync(), Does.Contain("sample_conflict"));
        for (var i = 0; i < 2; i++) Assert.That((await Upload(client, Input())).StatusCode, Is.EqualTo(HttpStatusCode.Created));
        Review(client);
        var first = (await client.GetFromJsonAsync<TrainingSamplePage>($"/api/training-samples?date={Day}&limit=2"))!;
        Assert.That(first.Items, Has.Count.EqualTo(2));
        Assert.That(first.NextCursor, Is.Not.Null);
        var second = (await client.GetFromJsonAsync<TrainingSamplePage>($"/api/training-samples?date={Day}&limit=2&cursor={Uri.EscapeDataString(first.NextCursor!)}"))!;
        Assert.That(second.Items, Has.Count.EqualTo(1));
        Assert.That(second.NextCursor, Is.Null);
        Assert.That(first.Items.Concat(second.Items).Select(s => s.Id).Distinct().Count(), Is.EqualTo(3));
        Assert.That(second.Items[0].AudioSize, Is.Zero);
        Assert.That(second.Items[0].AudioSha256, Is.Null);
        Assert.That((await client.GetAsync($"/api/training-samples/{Day}/{input.SampleId}/audio")).StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    [Test]
    public async Task ReviewerAccess_RequiresDedicatedCredential_AndInvalidBearerCannotUpload()
    {
        await using var factory = Factory();
        using var client = await factory.StartAsync();
        var token = await TestAuthHelper.GetDevTokenAsync(client);
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", token);
        var id = Guid.NewGuid();
        Assert.That((await client.GetAsync($"/api/training-samples?date={Day}")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That((await client.GetAsync($"/api/training-samples/{Day}/{id}/audio")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        Assert.That((await client.DeleteAsync($"/api/training-samples/{Day}/{id}")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        client.DefaultRequestHeaders.Add("X-Training-Token", ReviewerToken + "wrong");
        Assert.That((await client.GetAsync($"/api/training-samples?date={Day}")).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        client.DefaultRequestHeaders.Remove("X-Training-Token");
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", "invalid");
        Assert.That((await Upload(client, Input())).StatusCode, Is.EqualTo(HttpStatusCode.Unauthorized));
        client.DefaultRequestHeaders.Authorization = null;
        Review(client);
        Assert.That((await client.GetAsync($"/api/training-samples?date={Day}")).StatusCode, Is.EqualTo(HttpStatusCode.OK));
    }

    [Test]
    public async Task ConsentAndWhitelistedBounds_RejectUnrelatedContactsAndInvalidAudio()
    {
        await using var factory = Factory();
        using var client = await factory.StartAsync();
        foreach (var input in new[]
        {
            Input(consent: false), Input(transcript: ""), Input(transcript: new string('x', 32001)),
            Input() with { SampleId = Guid.Empty }, Input() with { Correction = new string('x', 4001) },
            Input() with { Language = "fr" }, Input() with { People = null! },
            Input() with { Connections = [new("Ada", "Unknown account contact", "knows")] },
            Input() with { People = Enumerable.Range(0, 51).Select(i => new TrainingPerson("Person" + i, null, [])).ToList() }
        }) Assert.That((await Upload(client, input)).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await Upload(client, new { sampleId = Guid.NewGuid(), consent = true, transcript = "Story", people = Array.Empty<object>(), connections = Array.Empty<object>(), accountContacts = new[] { "Secret contact" } })).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await Upload(client, Input(), new byte[44])).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        Assert.That((await Upload(client, Input(), Wav(601))).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        using var wrongType = Form(Input(), Wav(), "audio/webm");
        Assert.That((await client.PostAsync("/api/training-samples", wrongType)).StatusCode, Is.EqualTo(HttpStatusCode.UnsupportedMediaType));
        using var tooLarge = Form(Input(), new byte[10 * 1024 * 1024 + 1]);
        Assert.That((await client.PostAsync("/api/training-samples", tooLarge)).StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge));
        using var tooMuchMetadata = Form(Input(transcript: new string('x', 70000)));
        Assert.That((await client.PostAsync("/api/training-samples", tooMuchMetadata)).StatusCode, Is.EqualTo(HttpStatusCode.RequestEntityTooLarge));
        Review(client);
        Assert.That((await client.GetFromJsonAsync<TrainingSamplePage>($"/api/training-samples?date={Day}"))!.Items, Is.Empty);
    }

    [Test]
    public async Task DailyIpQuota_PersistsAcrossRestart_AllowsRetriesAndUtcReset_AndIgnoresSpoofedForwarding()
    {
        var clock = new Clock();
        var quotaStore = new InMemoryAnonymousQuotaStore();
        var sampleStore = new InMemoryTrainingSampleStore();
        var input = Input();
        await using (var first = Factory(clock))
        {
            first.AnonymousQuotaStore = quotaStore;
            first.TrainingSampleStore = sampleStore;
            using var client = await first.StartAsync();
            Assert.That((await Upload(client, input)).StatusCode, Is.EqualTo(HttpStatusCode.Created));
            for (var i = 1; i < 10; i++) Assert.That((await Upload(client, Input())).StatusCode, Is.EqualTo(HttpStatusCode.Created));
        }
        await using var second = Factory(clock);
        second.AnonymousQuotaStore = quotaStore;
        second.TrainingSampleStore = sampleStore;
        using var next = await second.StartAsync();
        next.DefaultRequestHeaders.Add("X-Forwarded-For", "198.51.100.7");
        Assert.That((await Upload(next, input)).StatusCode, Is.EqualTo(HttpStatusCode.Created));
        var full = await Upload(next, Input());
        Assert.That(full.StatusCode, Is.EqualTo(HttpStatusCode.TooManyRequests));
        Assert.That(await full.Content.ReadAsStringAsync(), Does.Contain("training_daily_limit").And.Contain("tomorrow"));
        clock.Now = clock.Now.AddDays(1);
        Assert.That((await Upload(next, Input())).StatusCode, Is.EqualTo(HttpStatusCode.Created));
    }

    [Test]
    public async Task ConcurrentCasReservations_AcrossInstances_AllowExactlyTenAndChangedRetryConflicts()
    {
        var store = new InMemoryAnonymousQuotaStore();
        var quotas = Enumerable.Range(0, 30).Select(_ => new TrainingSampleQuota(store));
        var results = await Task.WhenAll(quotas.Select(q => Task.Run(() => q.ReserveAsync("same-ip", Day, Guid.NewGuid(), "hash"))));
        Assert.That(results.Count(r => r == null), Is.EqualTo(10));
        Assert.That(results.Count(r => r == "training_daily_limit"), Is.EqualTo(20));
        var quota = new TrainingSampleQuota(store);
        var id = Guid.NewGuid();
        Assert.That(await quota.ReserveAsync("other-ip", Day, id, "hash"), Is.Null);
        Assert.That(await quota.ReserveAsync("other-ip", Day, id, "hash"), Is.Null);
        Assert.That(await quota.ReserveAsync("other-ip", Day, id, "changed"), Is.EqualTo("sample_conflict"));
    }

    [Test]
    public async Task DisabledOrFailedStorage_ReturnsHelpful503_AndInvalidReviewQueriesReturn400()
    {
        await using (var disabled = new TestWebApplicationFactory())
        {
            using var client = await disabled.StartAsync();
            Assert.That((await Upload(client, Input())).StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
            Assert.That((await client.GetAsync($"/api/training-samples?date={Day}")).StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        }
        await using var factory = Factory();
        using var enabled = await factory.StartAsync();
        Review(enabled);
        foreach (var query in new[] { "date=bad", $"date={Day}&limit=101", $"date={Day}&limit=0", $"date={Day}&limit=invalid", $"date={Day}&cursor=bad" })
            Assert.That((await enabled.GetAsync("/api/training-samples?" + query)).StatusCode, Is.EqualTo(HttpStatusCode.BadRequest));
        factory.TrainingSampleStore.Unavailable = true;
        var failure = await Upload(enabled, Input());
        Assert.That(failure.StatusCode, Is.EqualTo(HttpStatusCode.ServiceUnavailable));
        Assert.That(await failure.Content.ReadAsStringAsync(), Does.Contain("training_samples_unavailable"));
    }
}
