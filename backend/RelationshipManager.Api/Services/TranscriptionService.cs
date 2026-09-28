using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.Json;

namespace RelationshipManager.Api.Services;

/// <summary>
/// Calls one of two upstream speech-to-text protocols, selected by Transcription:Api:
///  - "asr-webservice": onerahmet/openai-whisper-asr-webservice's own API (what production uses).
///  - "openai": the OpenAI-compatible /audio/transcriptions endpoint.
/// Privacy: this only ever logs sizes/durations/status - never the transcript text or audio
/// content itself (see the char *count* logged below, never the text).
/// </summary>
public class TranscriptionService : ITranscriptionService
{
    private readonly IHttpClientFactory _httpClientFactory;
    private readonly IConfiguration _config;
    private readonly ILogger<TranscriptionService> _logger;

    public TranscriptionService(IHttpClientFactory httpClientFactory, IConfiguration config, ILogger<TranscriptionService> logger)
    {
        _httpClientFactory = httpClientFactory;
        _config = config;
        _logger = logger;
    }

    public bool IsConfigured => !string.IsNullOrWhiteSpace(_config["Transcription:BaseUrl"]);

    public async Task<string> TranscribeAsync(Stream audio, string contentType, string? language, CancellationToken cancellationToken)
    {
        if (!IsConfigured)
        {
            throw new TranscriptionNotConfiguredException();
        }

        var baseUrl = _config["Transcription:BaseUrl"]!.TrimEnd('/');
        var api = _config["Transcription:Api"] ?? "asr-webservice";
        var timeoutSeconds = _config.GetValue("Transcription:TimeoutSeconds", 60);
        var effectiveLanguage = string.IsNullOrEmpty(language) ? _config["Transcription:DefaultLanguage"] : language;

        var client = _httpClientFactory.CreateClient("transcription");
        client.Timeout = TimeSpan.FromSeconds(timeoutSeconds);

        var sw = Stopwatch.StartNew();
        try
        {
            var text = string.Equals(api, "openai", StringComparison.OrdinalIgnoreCase)
                ? await TranscribeOpenAiAsync(client, baseUrl, audio, contentType, effectiveLanguage, cancellationToken)
                : await TranscribeAsrWebserviceAsync(client, baseUrl, audio, contentType, effectiveLanguage, cancellationToken);

            sw.Stop();
            _logger.LogInformation("Transcription segment completed in {ElapsedMs}ms, {TextLength} characters returned", sw.ElapsedMilliseconds, text.Length);
            return text;
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            // The caller didn't cancel - this is client.Timeout elapsing.
            sw.Stop();
            _logger.LogWarning("Transcription upstream call timed out after {ElapsedMs}ms", sw.ElapsedMilliseconds);
            throw new TranscriptionFailedException("The transcription service timed out.");
        }
        catch (OperationCanceledException)
        {
            throw; // real cancellation (client disconnected) - let ASP.NET Core handle it
        }
        catch (RelationshipManager.Api.Http.MaxLengthExceededException)
        {
            throw; // segment was too large - the controller maps this to 413, not an upstream failure
        }
        catch (Exception ex)
        {
            sw.Stop();
            _logger.LogWarning(ex, "Transcription upstream call failed after {ElapsedMs}ms", sw.ElapsedMilliseconds);
            throw new TranscriptionFailedException("The transcription service call failed.", ex);
        }
    }

    private async Task<string> TranscribeAsrWebserviceAsync(HttpClient client, string baseUrl, Stream audio, string contentType, string? language, CancellationToken ct)
    {
        var url = $"{baseUrl}/asr?task=transcribe&output=json&encode=true";
        if (!string.IsNullOrEmpty(language))
        {
            url += $"&language={Uri.EscapeDataString(language)}";
        }

        using var content = new MultipartFormDataContent();
        using var streamContent = new StreamContent(audio);
        streamContent.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        content.Add(streamContent, "audio_file", "segment" + ExtensionFor(contentType));

        using var response = await client.PostAsync(url, content, ct);
        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"asr-webservice returned HTTP {(int)response.StatusCode}");
        }

        var body = await response.Content.ReadAsStringAsync(ct);
        return ParseText(body);
    }

    private async Task<string> TranscribeOpenAiAsync(HttpClient client, string baseUrl, Stream audio, string contentType, string? language, CancellationToken ct)
    {
        var url = $"{baseUrl}/audio/transcriptions";

        using var content = new MultipartFormDataContent();
        using var streamContent = new StreamContent(audio);
        streamContent.Headers.ContentType = new MediaTypeHeaderValue(contentType);
        content.Add(streamContent, "file", "segment" + ExtensionFor(contentType));
        content.Add(new StringContent(_config["Transcription:Model"] ?? "whisper-1"), "model");
        if (!string.IsNullOrEmpty(language))
        {
            content.Add(new StringContent(language), "language");
        }

        var apiKey = _config["Transcription:ApiKey"];
        if (!string.IsNullOrEmpty(apiKey))
        {
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        }

        using var response = await client.PostAsync(url, content, ct);
        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException($"openai returned HTTP {(int)response.StatusCode}");
        }

        var body = await response.Content.ReadAsStringAsync(ct);
        return ParseText(body);
    }

    private static string ParseText(string json)
    {
        var parsed = JsonSerializer.Deserialize<TranscriptionApiResponse>(json, JsonOptions);
        return parsed?.Text ?? string.Empty;
    }

    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private static string ExtensionFor(string contentType) => contentType.ToLowerInvariant() switch
    {
        "audio/wav" or "audio/x-wav" or "audio/wave" => ".wav",
        "audio/webm" => ".webm",
        "audio/ogg" => ".ogg",
        "audio/mp4" => ".m4a",
        "audio/mpeg" => ".mp3",
        _ => ""
    };

    private class TranscriptionApiResponse
    {
        public string? Text { get; set; }
    }
}
