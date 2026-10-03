using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text.RegularExpressions;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using RelationshipManager.Api.Errors;
using RelationshipManager.Api.Http;
using RelationshipManager.Api.Models;
using RelationshipManager.Api.Services;

namespace RelationshipManager.Api.Controllers;

/// <summary>
/// Live transcription while a story is being recorded. The app sends short audio segments and
/// gets text back. Audio is never written to disk; retry results stay only in bounded volatile
/// memory. Only sizes/durations/status codes are logged, never audio content or transcript text.
/// </summary>
[ApiController]
[Route("api/[controller]")]
[AllowAnonymous]
public class TranscriptionController : ControllerBase
{
    private static readonly HashSet<string> AllowedContentTypes = new(StringComparer.OrdinalIgnoreCase)
    {
        "audio/wav", "audio/webm", "audio/ogg", "audio/mp4", "audio/mpeg"
    };

    private static readonly Regex LanguagePattern = new(@"^[a-z]{2}$", RegexOptions.Compiled);

    private readonly ITranscriptionService _transcriptionService;
    private readonly PerUserConcurrencyLimiter _limiter;
    private readonly IConfiguration _config;
    private readonly AnonymousRecordingQuota _anonymousQuota;
    private readonly ILogger<TranscriptionController> _logger;

    public TranscriptionController(
        ITranscriptionService transcriptionService,
        PerUserConcurrencyLimiter limiter,
        IConfiguration config,
        AnonymousRecordingQuota anonymousQuota,
        ILogger<TranscriptionController> logger)
    {
        _transcriptionService = transcriptionService;
        _limiter = limiter;
        _config = config;
        _anonymousQuota = anonymousQuota;
        _logger = logger;
    }

    /// <summary>Whether live transcription is available, so the app can show this before recording starts.</summary>
    [HttpGet("status")]
    public async Task<IActionResult> Status()
    {
        if (HasInvalidAuthentication()) return UnauthorizedError();
        try
        {
            return Ok(new TranscriptionStatus
            {
                Available = _transcriptionService.IsConfigured,
                RemainingRecordings = GetUserId() == null && _transcriptionService.IsConfigured
                    ? await _anonymousQuota.RemainingAsync(ClientIp()) : null
            });
        }
        catch (Exception ex)
        {
            _logger.LogWarning("Recording quota unavailable: {ExceptionType}", ex.GetType().Name);
            return QuotaUnavailable();
        }
    }

    /// <summary>Transcribes one ~6 second audio segment. Body is the raw audio bytes.</summary>
    [HttpPost("segment")]
    public async Task<IActionResult> Segment([FromQuery] string? language, [FromQuery] Guid? recordingId, [FromQuery] int? segment)
    {
        var userId = GetUserId();
        if (HasInvalidAuthentication()) return UnauthorizedError();

        if (!_transcriptionService.IsConfigured)
        {
            return NotConfigured();
        }

        var contentType = GetMediaType(Request.ContentType);
        if (contentType == null || !AllowedContentTypes.Contains(contentType))
        {
            return StatusCode(StatusCodes.Status415UnsupportedMediaType,
                new ApiError("unsupported_content_type", "This audio format is not supported. Record again in the app using WAV, WebM, Ogg, MP4, or MP3."));
        }

        if (!string.IsNullOrEmpty(language) && !LanguagePattern.IsMatch(language))
        {
            return BadRequest(new ApiError("invalid_language", "Choose a recording language in Settings and try again (for example, en for English or de for German)."));
        }

        // Anonymous requests from one IP share concurrency slots, including retries.
        var concurrencyId = userId ?? new Guid(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(ClientIp()))[..16]);
        if (!_limiter.TryEnter(concurrencyId))
        {
            return StatusCode(StatusCodes.Status429TooManyRequests,
                new ApiError("too_many_requests", "Transcription is already busy. Wait a few seconds and try again; your recording is still saved."));
        }

        var maxBytes = _config.GetValue("Transcription:MaxSegmentBytes", 5 * 1024 * 1024);
        var sw = Stopwatch.StartNew();
        try
        {
            using var limitedBody = new LimitedStream(Request.Body, maxBytes);
            Stream audio = limitedBody;
            using var anonymousAudio = userId == null ? new MemoryStream() : null;
            if (anonymousAudio != null)
            {
                if (recordingId == null || recordingId == Guid.Empty || segment is null or < 0 or > 63)
                    return BadRequest(new ApiError("invalid_recording_segment", "Start a new recording in the app and try again."));
                await limitedBody.CopyToAsync(anonymousAudio, HttpContext.RequestAborted);
                var bytes = anonymousAudio.ToArray();
                var seconds = contentType == "audio/wav" ? AnonymousRecordingQuota.WavSeconds(bytes) : null;
                if (seconds == null)
                    return BadRequest(new ApiError("invalid_audio", "This recording is not a valid PCM WAV file. Record it again in the app, or sign in to use another audio format."));
                string? rejected;
                try
                {
                    var cached = _anonymousQuota.CachedText(ClientIp(), recordingId.Value, segment.Value, bytes, language);
                    if (cached != null) return Ok(new TranscriptionResult { Text = cached });
                    rejected = await _anonymousQuota.ReserveAsync(ClientIp(), recordingId.Value, segment.Value, bytes, seconds.Value);
                }
                catch (Exception ex)
                {
                    _logger.LogWarning("Recording quota unavailable: {ExceptionType}", ex.GetType().Name);
                    return QuotaUnavailable();
                }
                if (rejected != null)
                {
                    var message = rejected switch
                    {
                        "anonymous_daily_limit" => "You have used your three free recordings for today. Sign in to continue, or try again tomorrow. Your recording stays saved on this device.",
                        "anonymous_recording_too_long" => "Free recordings can be at most one minute long. Sign in to transcribe longer recordings, or make a shorter recording. Your audio stays saved on this device.",
                        "invalid_recording_segment" => "This recording segment has changed. Start a new recording and try again.",
                        _ => "This recording has been retried too often. Wait one minute and retry, or sign in; your audio stays saved on this device."
                    };
                    return StatusCode(rejected == "anonymous_recording_too_long" ? 413 : rejected == "invalid_recording_segment" ? 400 : 429, new ApiError(rejected, message));
                }
                anonymousAudio.Position = 0;
                audio = anonymousAudio;
            }
            var text = await _transcriptionService.TranscribeAsync(audio, contentType, language, HttpContext.RequestAborted);

            if (anonymousAudio != null)
                _anonymousQuota.CacheText(ClientIp(), recordingId!.Value, segment!.Value, anonymousAudio.ToArray(), language, text);
            sw.Stop();
            _logger.LogInformation(
                "Transcribed segment: content-type {ContentType}, {ElapsedMs}ms, status 200",
                contentType, sw.ElapsedMilliseconds);

            return Ok(new TranscriptionResult { Text = text });
        }
        catch (MaxLengthExceededException)
        {
            _logger.LogWarning("Rejected oversized transcription segment (over {MaxBytes} bytes)", maxBytes);
            return StatusCode(StatusCodes.Status413PayloadTooLarge,
                new ApiError("segment_too_large", $"This audio segment is too large (limit {maxBytes} bytes). Make a shorter recording and try again; your original audio remains saved."));
        }
        catch (TranscriptionNotConfiguredException)
        {
            return NotConfigured();
        }
        catch (TranscriptionFailedException ex)
        {
            sw.Stop();
            _logger.LogWarning("Transcription failed after {ElapsedMs}ms: {ExceptionType}", sw.ElapsedMilliseconds, ex.GetType().Name);
            return StatusCode(StatusCodes.Status502BadGateway,
                new ApiError("transcription_failed", "Text recognition is temporarily unavailable. Wait a moment and retry the recording; your audio remains saved on this device."));
        }
        finally
        {
            _limiter.Release(concurrencyId);
        }
    }

    private ObjectResult NotConfigured()
        => StatusCode(StatusCodes.Status503ServiceUnavailable,
            new ApiError("transcription_not_configured", "Text recognition is unavailable on this server. You can save your recording and add notes manually; ask the service administrator to enable transcription."));

    private string ClientIp() => HttpContext.Connection.RemoteIpAddress?.MapToIPv6().ToString() ?? "unknown";

    private bool HasInvalidAuthentication() =>
        (Request.Headers.ContainsKey("Authorization") && User.Identity?.IsAuthenticated != true) ||
        (User.Identity?.IsAuthenticated == true && GetUserId() == null);

    private ObjectResult UnauthorizedError() => Unauthorized(new ApiError("unauthorized", "Your sign-in has expired. Sign in again and retry; your recording remains saved on this device."));

    private ObjectResult QuotaUnavailable() => StatusCode(503, new ApiError("recording_quota_unavailable", "Free recording limits cannot be checked right now. Wait a moment and retry, or sign in; your recording remains saved on this device."));

    private static string? GetMediaType(string? contentType)
    {
        if (string.IsNullOrEmpty(contentType))
        {
            return null;
        }
        return MediaTypeHeaderValue.TryParse(contentType, out var parsed) ? parsed.MediaType : null;
    }

    private Guid? GetUserId()
    {
        var sub = User.Claims.FirstOrDefault(c => c.Type == "sub")?.Value;
        if (Guid.TryParse(sub, out var userId))
        {
            return userId;
        }
        return null;
    }
}
