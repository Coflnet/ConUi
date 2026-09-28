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
/// gets text back; nothing here is ever written to disk or stored, and only sizes/durations/status
/// codes are logged - never audio content or transcript text.
/// </summary>
[ApiController]
[Route("api/[controller]")]
[Authorize]
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
    private readonly ILogger<TranscriptionController> _logger;

    public TranscriptionController(
        ITranscriptionService transcriptionService,
        PerUserConcurrencyLimiter limiter,
        IConfiguration config,
        ILogger<TranscriptionController> logger)
    {
        _transcriptionService = transcriptionService;
        _limiter = limiter;
        _config = config;
        _logger = logger;
    }

    /// <summary>Whether live transcription is available, so the app can show this before recording starts.</summary>
    [HttpGet("status")]
    public IActionResult Status() => Ok(new TranscriptionStatus { Available = _transcriptionService.IsConfigured });

    /// <summary>Transcribes one ~6 second audio segment. Body is the raw audio bytes.</summary>
    [HttpPost("segment")]
    public async Task<IActionResult> Segment([FromQuery] string? language)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

        if (!_transcriptionService.IsConfigured)
        {
            return NotConfigured();
        }

        var contentType = GetMediaType(Request.ContentType);
        if (contentType == null || !AllowedContentTypes.Contains(contentType))
        {
            return StatusCode(StatusCodes.Status415UnsupportedMediaType,
                new ApiError("unsupported_content_type", "Unsupported audio content type."));
        }

        if (!string.IsNullOrEmpty(language) && !LanguagePattern.IsMatch(language))
        {
            return BadRequest(new ApiError("invalid_language", "language must be a two-letter ISO 639-1 code, e.g. 'en'."));
        }

        if (!_limiter.TryEnter(userId.Value))
        {
            return StatusCode(StatusCodes.Status429TooManyRequests,
                new ApiError("too_many_requests", "Too many concurrent transcription requests for this user."));
        }

        var maxBytes = _config.GetValue("Transcription:MaxSegmentBytes", 5 * 1024 * 1024);
        var sw = Stopwatch.StartNew();
        try
        {
            using var limitedBody = new LimitedStream(Request.Body, maxBytes);
            var text = await _transcriptionService.TranscribeAsync(limitedBody, contentType, language, HttpContext.RequestAborted);

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
                new ApiError("segment_too_large", $"Audio segment exceeds the {maxBytes} byte limit."));
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
                new ApiError("transcription_failed", "The transcription service could not process this segment."));
        }
        finally
        {
            _limiter.Release(userId.Value);
        }
    }

    private ObjectResult NotConfigured()
        => StatusCode(StatusCodes.Status503ServiceUnavailable,
            new ApiError("transcription_not_configured", "Live transcription is not configured on this server."));

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
