using System.Net;
using System.Text;
using Microsoft.Extensions.Configuration;
using RelationshipManager.Api.Http;
using RelationshipManager.Api.Services;
using RelationshipManager.Api.Tests.Fakes;

namespace RelationshipManager.Api.Tests;

public class TranscriptionServiceTests
{
    private static IConfiguration Config(Dictionary<string, string?> values)
        => new ConfigurationBuilder().AddInMemoryCollection(values).Build();

    private static MemoryStream Audio(string content = "fake-wav-bytes") => new(Encoding.UTF8.GetBytes(content));

    [Test]
    public async Task AsrWebservice_SendsCorrectUrlQueryAndField_WithLanguage()
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"text\":\"hallo\"}")
        });
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local",
            ["Transcription:Api"] = "asr-webservice"
        }), new ListLogger<TranscriptionService>());

        var text = await service.TranscribeAsync(Audio(), "audio/wav", "de", CancellationToken.None);

        Assert.That(text, Is.EqualTo("hallo"));
        var uri = handler.LastRequest!.RequestUri!;
        Assert.That(uri.AbsoluteUri, Does.StartWith("http://whisper.local/asr?"));
        Assert.That(uri.Query, Does.Contain("task=transcribe"));
        Assert.That(uri.Query, Does.Contain("output=json"));
        Assert.That(uri.Query, Does.Contain("encode=true"));
        Assert.That(uri.Query, Does.Contain("language=de"));
        Assert.That(handler.LastMultipartFieldNames, Does.Contain("audio_file"));
    }

    [Test]
    public async Task AsrWebservice_OmitsLanguageQueryParam_WhenNoLanguageConfiguredOrPassed()
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"text\":\"hi\"}")
        });
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local"
        }), new ListLogger<TranscriptionService>());

        await service.TranscribeAsync(Audio(), "audio/wav", language: null, CancellationToken.None);

        Assert.That(handler.LastRequest!.RequestUri!.Query, Does.Not.Contain("language="));
    }

    [Test]
    public async Task AsrWebservice_UsesDefaultLanguage_WhenNoneProvided()
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"text\":\"hi\"}")
        });
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local",
            ["Transcription:DefaultLanguage"] = "fr"
        }), new ListLogger<TranscriptionService>());

        await service.TranscribeAsync(Audio(), "audio/wav", language: null, CancellationToken.None);

        Assert.That(handler.LastRequest!.RequestUri!.Query, Does.Contain("language=fr"));
    }

    [Test]
    public async Task OpenAi_SendsCorrectUrlFieldsAndAuthHeader()
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"text\":\"bonjour\"}")
        });
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "https://api.openai.com/v1",
            ["Transcription:Api"] = "openai",
            ["Transcription:Model"] = "whisper-1",
            ["Transcription:ApiKey"] = "sk-test-key"
        }), new ListLogger<TranscriptionService>());

        var text = await service.TranscribeAsync(Audio(), "audio/webm", "fr", CancellationToken.None);

        Assert.That(text, Is.EqualTo("bonjour"));
        Assert.That(handler.LastRequest!.RequestUri!.AbsoluteUri, Is.EqualTo("https://api.openai.com/v1/audio/transcriptions"));
        Assert.That(handler.LastRequest.Headers.Authorization?.Scheme, Is.EqualTo("Bearer"));
        Assert.That(handler.LastRequest.Headers.Authorization?.Parameter, Is.EqualTo("sk-test-key"));
        Assert.That(handler.LastMultipartFieldNames, Does.Contain("file"));
        Assert.That(handler.LastMultipartFieldNames, Does.Contain("model"));
        Assert.That(handler.LastMultipartFieldNames, Does.Contain("language"));
    }

    [Test]
    public void NotConfigured_Throws_WhenBaseUrlBlank()
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK));
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = ""
        }), new ListLogger<TranscriptionService>());

        Assert.That(service.IsConfigured, Is.False);
        Assert.ThrowsAsync<TranscriptionNotConfiguredException>(async () =>
            await service.TranscribeAsync(Audio(), "audio/wav", null, CancellationToken.None));
    }

    [Test]
    public void UpstreamErrorStatus_ThrowsTranscriptionFailedException()
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.InternalServerError));
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local"
        }), new ListLogger<TranscriptionService>());

        Assert.ThrowsAsync<TranscriptionFailedException>(async () =>
            await service.TranscribeAsync(Audio(), "audio/wav", null, CancellationToken.None));
    }

    [Test]
    public void UpstreamTimeout_ThrowsTranscriptionFailedException()
    {
        // Simulates client.Timeout elapsing: HttpClient throws TaskCanceledException even though
        // the caller's own token (CancellationToken.None here) was never cancelled.
        var handler = new RecordingHttpMessageHandler((Func<HttpRequestMessage, HttpResponseMessage>)(_ => throw new TaskCanceledException()));
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local"
        }), new ListLogger<TranscriptionService>());

        Assert.ThrowsAsync<TranscriptionFailedException>(async () =>
            await service.TranscribeAsync(Audio(), "audio/wav", null, CancellationToken.None));
    }

    [Test]
    public void SegmentTooLarge_PropagatesUnwrapped_NotAsTranscriptionFailed()
    {
        // Regression: TranscriptionService's broad catch used to swallow MaxLengthExceededException
        // (thrown by LimitedStream while HttpClient streams the body) and rewrap it as
        // TranscriptionFailedException, which the controller reports as 502 instead of 413.
        var handler = new RecordingHttpMessageHandler(async req =>
        {
            // Force the stream to actually be read, like a real HttpClient send would.
            await req.Content!.ReadAsStreamAsync();
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"text\":\"x\"}") };
        });
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local"
        }), new ListLogger<TranscriptionService>());

        using var oversized = new LimitedStream(Audio("this is way more than four bytes"), maxBytes: 4);

        Assert.ThrowsAsync<MaxLengthExceededException>(async () =>
            await service.TranscribeAsync(oversized, "audio/wav", null, CancellationToken.None));
    }

    [Test]
    public async Task NeverLogsTranscriptTextOrAudioContent()
    {
        const string secretTranscript = "grandma told me about the lake house in 1962";
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent($"{{\"text\":\"{secretTranscript}\"}}")
        });
        var logger = new ListLogger<TranscriptionService>();
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local"
        }), logger);

        var text = await service.TranscribeAsync(Audio("some audio bytes that must not be logged either"), "audio/wav", null, CancellationToken.None);

        Assert.That(text, Is.EqualTo(secretTranscript));
        foreach (var message in logger.Messages)
        {
            Assert.That(message, Does.Not.Contain(secretTranscript));
            Assert.That(message, Does.Not.Contain("some audio bytes"));
        }
    }
}
