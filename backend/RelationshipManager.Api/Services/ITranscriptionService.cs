namespace RelationshipManager.Api.Services;

/// <summary>Thrown when transcription is requested but Transcription:BaseUrl is not set.</summary>
public class TranscriptionNotConfiguredException : Exception
{
    public TranscriptionNotConfiguredException() : base("Transcription is not configured.")
    {
    }
}

/// <summary>Thrown when the upstream transcription call fails or times out.</summary>
public class TranscriptionFailedException : Exception
{
    public TranscriptionFailedException(string message, Exception? inner = null) : base(message, inner)
    {
    }
}

/// <summary>
/// Sends one audio segment to the configured speech-to-text upstream and returns the transcript.
/// Never persists audio or text anywhere - it is purely a pass-through.
/// </summary>
public interface ITranscriptionService
{
    /// <summary>True when Transcription:BaseUrl is set.</summary>
    bool IsConfigured { get; }

    /// <summary>
    /// Transcribes <paramref name="audio"/> (streamed, not buffered by this method) using
    /// <paramref name="contentType"/> and an optional two-letter <paramref name="language"/>.
    /// Throws <see cref="TranscriptionNotConfiguredException"/> or <see cref="TranscriptionFailedException"/>.
    /// </summary>
    Task<string> TranscribeAsync(Stream audio, string contentType, string? language, CancellationToken cancellationToken);
}
