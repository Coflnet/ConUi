using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.Net.Http.Headers;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Errors;
using RelationshipManager.Api.Http;
using RelationshipManager.Api.Models;
using RelationshipManager.Api.Services;

namespace RelationshipManager.Api.Controllers;

[ApiController]
[AllowAnonymous]
[Route("api/training-samples")]
public sealed class TrainingSamplesController(ITrainingSampleStore store, TrainingSampleQuota quota,
    IConfiguration config, TimeProvider clock, PerUserConcurrencyLimiter limiter,
    ILogger<TrainingSamplesController> logger) : ControllerBase
{
    private const int MaxAudioBytes = 10 * 1024 * 1024;
    private const int MaxMetadataBytes = 64 * 1024;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web)
    {
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow
    };

    private bool Configured => config["TrainingSamples:ReviewerTokenHash"] is { Length: 64 } hash &&
        hash.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');

    private ObjectResult Error(int status, string slug, string message) => StatusCode(status, new ApiError(slug, message));
    private ObjectResult Unavailable() => Error(503, "training_samples_unavailable", "Sample reporting is unavailable. Keep your recording and try again later.");
    private ObjectResult UnauthorizedError() => Error(401, "unauthorized", "A valid review credential is required to access reported samples.");
    private ObjectResult InvalidMetadata() => Error(400, "invalid_sample", "Include explicit consent, a sample ID, transcript or WAV audio, and the people and connections extracted from this recording within the sample limits.");

    private bool Reviewer()
    {
        var token = Request.Headers["X-Training-Token"];
        if (token.Count != 1 || token[0] is not { Length: >= 32 and <= 512 } value) return false;
        return CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(value)),
            Convert.FromHexString(config["TrainingSamples:ReviewerTokenHash"]!));
    }

    [HttpPost]
    [RequestSizeLimit(MaxAudioBytes + MaxMetadataBytes + 16384)]
    public async Task<IActionResult> Upload()
    {
        if (Request.Headers.ContainsKey("Authorization") && User.Identity?.IsAuthenticated != true)
            return Error(401, "unauthorized", "Your sign-in has expired. Sign in again and retry reporting your recording.");
        if (!Configured) return Unavailable();
        if (!MediaTypeHeaderValue.TryParse(Request.ContentType, out var contentType) ||
            !contentType.MediaType.Equals("multipart/form-data", StringComparison.OrdinalIgnoreCase))
            return Error(415, "unsupported_content_type", "Send sample metadata and optional WAV audio as multipart/form-data.");
        var boundary = HeaderUtilities.RemoveQuotes(contentType.Boundary).Value;
        if (string.IsNullOrWhiteSpace(boundary) || boundary.Length > 128) return InvalidMetadata();
        var ip = HttpContext.Connection.RemoteIpAddress?.MapToIPv6().ToString() ?? "unknown";
        var concurrencyId = new Guid(SHA256.HashData(Encoding.UTF8.GetBytes("training:" + ip))[..16]);
        if (!limiter.TryEnter(concurrencyId))
            return Error(429, "too_many_requests", "Sample reporting is busy. Wait a moment and retry; your recording stays on this device.");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(HttpContext.RequestAborted);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        try
        {
            using var limited = new LimitedStream(Request.Body, MaxAudioBytes + MaxMetadataBytes + 16384);
            var reader = new MultipartReader(boundary, limited) { HeadersCountLimit = 8, HeadersLengthLimit = 4096 };
            byte[]? metadata = null;
            byte[]? audio = null;
            MultipartSection? section;
            var count = 0;
            while ((section = await reader.ReadNextSectionAsync(timeout.Token)) != null)
            {
                if (++count > 2 || !ContentDispositionHeaderValue.TryParse(section.ContentDisposition, out var disposition) ||
                    !disposition.DispositionType.Equals("form-data", StringComparison.OrdinalIgnoreCase)) return InvalidMetadata();
                var name = HeaderUtilities.RemoveQuotes(disposition.Name).Value;
                if (name == "metadata" && metadata == null)
                    metadata = await ReadBounded(section.Body, MaxMetadataBytes, timeout.Token);
                else if (name == "audio" && audio == null)
                {
                    if (!MediaTypeHeaderValue.TryParse(section.ContentType, out var audioType) ||
                        !audioType.MediaType.Equals("audio/wav", StringComparison.OrdinalIgnoreCase))
                        return Error(415, "unsupported_audio", "Attach the original recording as PCM WAV audio.");
                    audio = await ReadBounded(section.Body, MaxAudioBytes, timeout.Token);
                }
                else return InvalidMetadata();
            }
            if (metadata == null) return InvalidMetadata();
            var input = JsonSerializer.Deserialize<TrainingSampleInput>(metadata, Json);
            if (!Valid(input) || (string.IsNullOrWhiteSpace(input!.Transcript) && audio == null)) return InvalidMetadata();
            if (audio != null && AnonymousRecordingQuota.WavSeconds(audio) is not (> 0 and <= 600))
                return Error(400, "invalid_audio", "Attach a valid PCM WAV recording of at most ten minutes, or report the transcript without audio.");
            var audioHash = audio == null ? null : Hash(audio);
            var dataHash = Hash(JsonSerializer.SerializeToUtf8Bytes(new { input, audioHash }, Json));
            var now = clock.GetUtcNow();
            var date = now.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            var sample = new TrainingSample(input!.SampleId, date, now, "1", input.Transcript, input.Correction,
                input.Language, input.People, input.Connections, audio?.Length ?? 0, audioHash, dataHash);
            var existing = await store.GetAsync(date, sample.Id);
            if (existing != null) return Published(existing, sample);
            var rejected = await quota.ReserveAsync(ip, date, sample.Id, dataHash);
            if (rejected == "sample_conflict") return ConflictError();
            if (rejected != null)
                return Error(429, rejected, "You have reported ten samples today. Try again tomorrow; your recording stays on this device.");
            return Published(await store.PublishAsync(sample, audio), sample);
        }
        catch (MaxLengthExceededException)
        {
            return Error(413, "sample_too_large", "Sample metadata must be at most 64 KiB and WAV audio at most 10 MiB. Report the transcript without audio if the recording is larger.");
        }
        catch (BadHttpRequestException ex) when (ex.StatusCode == 413)
        {
            return Error(413, "sample_too_large", "WAV audio must be at most 10 MiB and sample metadata at most 64 KiB.");
        }
        catch (Exception ex) when (ex is JsonException or InvalidDataException or FormatException or BadHttpRequestException)
        {
            return InvalidMetadata();
        }
        catch (OperationCanceledException) when (!HttpContext.RequestAborted.IsCancellationRequested)
        {
            return Error(408, "sample_upload_timeout", "Sample reporting took too long. Check your connection and retry; your recording stays on this device.");
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            logger.LogWarning("Sample reporting unavailable: {ExceptionType}", ex.GetType().Name);
            return Unavailable();
        }
        finally { limiter.Release(concurrencyId); }
    }

    private IActionResult Published(TrainingSample stored, TrainingSample uploaded) =>
        stored.DataSha256 == uploaded.DataSha256 ? StatusCode(201, new { stored.Id, stored.Date }) : ConflictError();
    private ObjectResult ConflictError() => Error(409, "sample_conflict", "This sample ID was already used for different content. Start a new report to submit a changed sample.");
    private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

    private static async Task<byte[]> ReadBounded(Stream stream, int limit, CancellationToken ct)
    {
        using var limited = new LimitedStream(stream, limit);
        using var buffer = new MemoryStream();
        await limited.CopyToAsync(buffer, ct);
        return buffer.ToArray();
    }

    private static bool Text(string? value, int max) => !string.IsNullOrWhiteSpace(value) && value.Length <= max;
    private static bool Valid(TrainingSampleInput? sample)
    {
        if (sample == null || sample.SampleId == Guid.Empty || !sample.Consent || sample.Transcript == null || sample.Transcript.Length > 32000 ||
            sample.Correction?.Length > 4000 || sample.Language is not (null or "en" or "de") ||
            sample.People is not { Count: <= 50 } || sample.Connections is not { Count: <= 100 }) return false;
        foreach (var person in sample.People)
            if (person == null || !Text(person.Name, 200) || person.Company?.Length > 200 ||
                person.Facts is not { Count: <= 20 } || person.Facts.Any(f => !Text(f, 1000))) return false;
        var names = new HashSet<string>(sample.People.Select(p => p.Name), StringComparer.OrdinalIgnoreCase);
        return sample.Connections.All(c => c != null && Text(c.Type, 100) && c.Person1Name != null && c.Person2Name != null &&
            names.Contains(c.Person1Name) && names.Contains(c.Person2Name));
    }

    private static bool Date(string? value) => DateOnly.TryParseExact(value, "yyyy-MM-dd", CultureInfo.InvariantCulture, DateTimeStyles.None, out _);

    [HttpGet]
    public async Task<IActionResult> List([FromQuery] string? date, [FromQuery] string? limit = null, [FromQuery] string? cursor = null)
    {
        if (!Configured) return Unavailable();
        if (!Reviewer()) return UnauthorizedError();
        var pageSize = 20;
        if (!Date(date) || (limit != null && !int.TryParse(limit, out pageSize)) || pageSize is < 1 or > 100) return Error(400, "invalid_sample_query", "Choose a UTC date as YYYY-MM-DD and a limit from 1 to 100.");
        Guid? after = null;
        if (cursor != null)
        {
            try { after = new Guid(Convert.FromBase64String(cursor)); }
            catch (Exception ex) when (ex is FormatException or ArgumentException)
            { return Error(400, "invalid_sample_query", "Use the nextCursor returned by the previous sample page."); }
        }
        Response.Headers.CacheControl = "no-store";
        try { return Ok(await store.ListAsync(date!, pageSize, after)); }
        catch (Exception ex) { logger.LogWarning("Sample retrieval unavailable: {ExceptionType}", ex.GetType().Name); return Unavailable(); }
    }

    [HttpGet("{date}/{id:guid}/audio")]
    public async Task<IActionResult> Audio(string date, Guid id)
    {
        if (!Configured) return Unavailable();
        if (!Reviewer()) return UnauthorizedError();
        if (!Date(date)) return Error(400, "invalid_sample_query", "Choose a UTC date as YYYY-MM-DD.");
        Response.Headers.CacheControl = "no-store";
        try
        {
            var audio = await store.AudioAsync(date, id);
            return audio == null ? Error(404, "sample_audio_not_found", "This sample has no attached recording.") : File(audio, "audio/wav", id + ".wav");
        }
        catch (Exception ex) { logger.LogWarning("Sample audio unavailable: {ExceptionType}", ex.GetType().Name); return Unavailable(); }
    }

    [HttpDelete("{date}/{id:guid}")]
    public async Task<IActionResult> Delete(string date, Guid id)
    {
        if (!Configured) return Unavailable();
        if (!Reviewer()) return UnauthorizedError();
        if (!Date(date)) return Error(400, "invalid_sample_query", "Choose a UTC date as YYYY-MM-DD.");
        Response.Headers.CacheControl = "no-store";
        try { await store.DeleteAsync(date, id); return NoContent(); }
        catch (Exception ex) { logger.LogWarning("Sample removal unavailable: {ExceptionType}", ex.GetType().Name); return Unavailable(); }
    }
}
