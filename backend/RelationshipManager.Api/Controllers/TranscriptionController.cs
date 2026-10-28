using System.Diagnostics;
using System.Net.Http.Headers;
using System.Text;
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
        "audio/wav"
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
            var status = await _anonymousQuota.StatusAsync(QuotaIdentity(), DailyLimit());
            status.Available = _transcriptionService.IsConfigured;
            return Ok(status);
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
                new ApiError("unsupported_content_type", "This audio format is not supported. Record again in the app using PCM WAV."));
        }

        if (!string.IsNullOrEmpty(language) && !LanguagePattern.IsMatch(language))
        {
            return BadRequest(new ApiError("invalid_language", "Choose a recording language in Settings and try again (for example, en for English or de for German)."));
        }

        string? initialPrompt = null;
        if (Request.Headers.TryGetValue("X-Transcription-Prompt", out var encodedPrompt))
        {
            try
            {
                initialPrompt = new UTF8Encoding(false, true).GetString(Convert.FromBase64String(encodedPrompt.ToString())).Trim();
                if (initialPrompt.EnumerateRunes().Take(1025).Count() > 1024) throw new FormatException();
                if (initialPrompt.Length == 0) initialPrompt = null;
            }
            catch (Exception ex) when (ex is FormatException or DecoderFallbackException)
            {
                return BadRequest(new ApiError("invalid_transcription_prompt", "Previous transcription context must be valid UTF-8 text of at most 1024 characters."));
            }
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
        AnonymousRecordingQuota.Reservation? reservation = null;
        var completed = false;
        var identity = QuotaIdentity();
        var limit = DailyLimit();
        try
        {
            using var limitedBody = new LimitedStream(Request.Body, maxBytes);
            if (recordingId == null || recordingId == Guid.Empty || segment is null or < 0 or > 4095)
                return BadRequest(new ApiError("invalid_recording_segment", "Start a new recording in the app and try again."));
            using var audio = new MemoryStream();
            await limitedBody.CopyToAsync(audio, HttpContext.RequestAborted);
            var bytes = audio.ToArray();
            var seconds = AnonymousRecordingQuota.WavSeconds(bytes);
            if (seconds == null)
                return BadRequest(new ApiError("invalid_audio", "This recording is not a valid PCM WAV file. Record it again in the app."));
            try
            {
                var cached = _anonymousQuota.CachedText(identity, recordingId.Value, segment.Value, bytes, language, initialPrompt);
                if (cached != null) return Ok(await ResultAsync(identity, limit, cached));
                var reserved = await _anonymousQuota.ReserveAsync(identity, limit, recordingId.Value, segment.Value, bytes, seconds.Value);
                if (reserved.Error != null)
                {
                    var message = reserved.Error switch
                    {
                        "anonymous_daily_limit" => "You have used your five free transcription minutes for today. Sign in to continue, or try again tomorrow. Your recording stays saved on this device.",
                        "transcription_daily_limit" => "You have used your twenty transcription minutes for today. Try again tomorrow; your recording stays saved on this device.",
                        "invalid_recording_segment" => "This recording segment has changed. Start a new recording and try again.",
                        "too_many_requests" => "This recording segment has been retried too often. Wait one minute and retry; your audio stays saved on this device.",
                        "recording_segment_limit" => "You have reached today's transcription segment limit. Try again after midnight UTC; your recording stays saved on this device.",
                        _ => "This recording segment is already being transcribed. Wait a moment and retry; your audio stays saved on this device."
                    };
                    return StatusCode(reserved.Error == "invalid_recording_segment" ? 400 : 429, new ApiError(reserved.Error, message));
                }
                reservation = reserved.Reservation!;
            }
            catch (Exception ex)
            {
                _logger.LogWarning("Recording quota unavailable: {ExceptionType}", ex.GetType().Name);
                return QuotaUnavailable();
            }
            audio.Position = 0;
            var text = await _transcriptionService.TranscribeAsync(audio, contentType, language, HttpContext.RequestAborted, initialPrompt);
            TranscriptionResult result;
            try
            {
                await _anonymousQuota.CompleteAsync(reservation);
                completed = true;
                _anonymousQuota.CacheText(reservation, bytes, language, text, initialPrompt);
                result = await ResultAsync(identity, limit, text);
            }
            catch (Exception ex)
            {
                _logger.LogWarning("Recording quota unavailable: {ExceptionType}", ex.GetType().Name);
                return QuotaUnavailable();
            }
            sw.Stop();
            _logger.LogInformation(
                "Transcribed segment: content-type {ContentType}, {ElapsedMs}ms, status 200",
                contentType, sw.ElapsedMilliseconds);

            return Ok(result);
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
            if (reservation != null && !completed)
            {
                try { await _anonymousQuota.ReleaseAsync(reservation); }
                catch (Exception ex) { _logger.LogWarning("Recording reservation release failed: {ExceptionType}", ex.GetType().Name); }
            }
            _limiter.Release(concurrencyId);
        }
    }

    private string QuotaIdentity() => GetUserId() is { } userId ? $"user:{userId}" : ClientIp();
    private int DailyLimit() => GetUserId() == null ? 300 : 1200;

    private async Task<TranscriptionResult> ResultAsync(string identity, int limit, string text)
    {
        var status = await _anonymousQuota.StatusAsync(identity, limit);
        return new TranscriptionResult
        {
            Available = true, Text = text,
            UsedSeconds = status.UsedSeconds, RemainingSeconds = status.RemainingSeconds,
            DailyLimitSeconds = status.DailyLimitSeconds, WarningAfterSeconds = status.WarningAfterSeconds,
            ResetAt = status.ResetAt
        };
    }

    private ObjectResult NotConfigured()
        => StatusCode(StatusCodes.Status503ServiceUnavailable,
            new ApiError("transcription_not_configured", "Text recognition is unavailable on this server. You can save your recording and add notes manually; ask the service administrator to enable transcription."));

    private string ClientIp() => HttpContext.Connection.RemoteIpAddress?.MapToIPv6().ToString() ?? "unknown";

    private bool HasInvalidAuthentication() =>
        (Request.Headers.ContainsKey("Authorization") && User.Identity?.IsAuthenticated != true) ||
        (User.Identity?.IsAuthenticated == true && GetUserId() == null);

    private ObjectResult UnauthorizedError() => Unauthorized(new ApiError("unauthorized", "Your sign-in has expired. Sign in again and retry; your recording remains saved on this device."));

    private ObjectResult QuotaUnavailable() => StatusCode(503, new ApiError("recording_quota_unavailable", "Transcription limits cannot be checked right now. Wait a moment and retry; your recording remains saved on this device."));

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
