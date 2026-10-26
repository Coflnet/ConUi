using System.Net;
using System.Text;
using Microsoft.Extensions.Configuration;
using RelationshipManager.Api.Http;
using RelationshipManager.Api.Services;
using RelationshipManager.Api.Tests.Fakes;

namespace RelationshipManager.Api.Tests;

public class TranscriptionServiceTests
{
    [TestCase("asr-webservice", false)]
    [TestCase("asr-webservice", true)]
    [TestCase("openai", false)]
    public async Task PreviousContext_UsesUpstreamProtocol_WithoutExtraCallsOrTextLogs(string api, bool dialect)
    {
        const string prompt = "Vorheriger Satz: Grüße & Namen.\nNächster Satz";
        string? sentPrompt = null;
        var calls = 0;
        var handler = new RecordingHttpMessageHandler(async request =>
        {
            calls++;
            if (api == "asr-webservice" && !dialect)
            {
                Assert.That(Uri.UnescapeDataString(request.RequestUri!.Query), Does.Contain("initial_prompt=" + prompt));
            }
            else
            {
                var field = dialect ? "initialPrompt" : "prompt";
                sentPrompt = await ((MultipartFormDataContent)request.Content!).Single(part => part.Headers.ContentDisposition!.Name!.Trim('"') == field).ReadAsStringAsync();
                Assert.That(request.RequestUri!.Query, Is.Empty);
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"text\":\"next\"}") };
        });
        var logger = new ListLogger<TranscriptionService>();
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local",
            ["Transcription:Api"] = api,
            ["Transcription:DialectBaseUrl"] = dialect ? "http://tab-api.tab" : null
        }), logger);
        Assert.That(await service.TranscribeAsync(Audio(), "audio/wav", "de", CancellationToken.None, prompt), Is.EqualTo("next"));
        Assert.That(calls, Is.EqualTo(1));
        if (sentPrompt != null) Assert.That(sentPrompt, Is.EqualTo(prompt));
        Assert.That(string.Join("\n", logger.Messages), Does.Not.Contain(prompt));
    }

    [Test]
    public void UpstreamExceptionContext_IsNotLogged()
    {
        const string prompt = "PRIVATE RECOGNIZED CONTEXT";
        var handler = new RecordingHttpMessageHandler((Func<HttpRequestMessage, HttpResponseMessage>)(_ => throw new HttpRequestException(prompt)));
        var logger = new ListLogger<TranscriptionService>();
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new() { ["Transcription:BaseUrl"] = "http://whisper.local" }), logger);
        Assert.ThrowsAsync<TranscriptionFailedException>(async () => await service.TranscribeAsync(Audio(), "audio/wav", "de", CancellationToken.None, prompt));
        Assert.That(string.Join("\n", logger.Messages), Does.Not.Contain(prompt));
    }

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
        Assert.That(uri.Query, Does.Contain("vad_filter=true"));
        Assert.That(uri.Query, Does.Contain("language=de"));
        Assert.That(handler.LastMultipartFieldNames, Does.Contain("audio_file"));
    }

    [TestCase("de")]
    [TestCase(null)]
    public async Task German_UsesConfiguredDiaTrainedQueue_WithoutCollectionOrCredentials(string? language)
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"text\":\"hallo\",\"durationMs\":400}")
        });
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local",
            ["Transcription:DialectBaseUrl"] = "http://tab-api.tab/",
            ["Transcription:DefaultLanguage"] = "de",
            ["Transcription:ApiKey"] = "must-not-be-forwarded"
        }), new ListLogger<TranscriptionService>());

        var text = await service.TranscribeAsync(Audio(), "audio/wav", language, CancellationToken.None);

        Assert.That(text, Is.EqualTo("hallo"));
        Assert.That(handler.LastRequest!.RequestUri!.AbsoluteUri,
            Is.EqualTo("http://tab-api.tab/api/Dialect/transcribe"));
        Assert.That(handler.LastMultipartFieldNames, Is.EqualTo(new[] { "audioFile" }));
        Assert.That(handler.LastRequest.Headers.Authorization, Is.Null);
    }

    [TestCase("en")]
    [TestCase(null)]
    public async Task DiaConfigured_PreservesOtherLanguagesAndAutomaticDetection(string? language)
    {
        var handler = new RecordingHttpMessageHandler(_ => new HttpResponseMessage(HttpStatusCode.OK)
        {
            Content = new StringContent("{\"text\":\"hello\"}")
        });
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local",
            ["Transcription:DialectBaseUrl"] = "http://tab-api.tab"
        }), new ListLogger<TranscriptionService>());

        await service.TranscribeAsync(Audio(), "audio/wav", language, CancellationToken.None);

        Assert.That(handler.LastRequest!.RequestUri!.AbsoluteUri, Does.StartWith("http://whisper.local/asr?"));
        Assert.That(handler.LastRequest.RequestUri.Query, language == null
            ? Does.Not.Contain("language=") : Does.Contain("language=en"));
        Assert.That(handler.LastMultipartFieldNames, Is.EqualTo(new[] { "audio_file" }));
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

    [TestCase(null)]
    [TestCase("http://tab-api.tab")]
    public void UpstreamErrorStatus_ThrowsTranscriptionFailedException_WithoutFallback(string? dialectBaseUrl)
    {
        var requests = 0;
        var handler = new RecordingHttpMessageHandler(_ =>
        {
            requests++;
            return new HttpResponseMessage(HttpStatusCode.InternalServerError);
        });
        var service = new TranscriptionService(new FakeHttpClientFactory(handler), Config(new()
        {
            ["Transcription:BaseUrl"] = "http://whisper.local",
            ["Transcription:DialectBaseUrl"] = dialectBaseUrl
        }), new ListLogger<TranscriptionService>());

        Assert.ThrowsAsync<TranscriptionFailedException>(async () =>
            await service.TranscribeAsync(Audio(), "audio/wav", "de", CancellationToken.None));
        Assert.That(requests, Is.EqualTo(1));
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
