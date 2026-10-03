using RelationshipManager.Api.Services;

namespace RelationshipManager.Api.Tests.Fakes;

/// <summary>Stand-in for <see cref="ITranscriptionService"/> so controller tests don't need a real upstream.</summary>
public class FakeTranscriptionService : ITranscriptionService
{
    public bool IsConfigured { get; set; }
    public int CallCount { get; private set; }
    public string ResultText { get; set; } = "hello world";
    public Exception? ThrowOnTranscribe { get; set; }
    public string? LastContentType { get; private set; }
    public string? LastLanguage { get; private set; }
    public long LastAudioByteCount { get; private set; }

    /// <summary>When set, TranscribeAsync awaits this before returning - lets a test hold a call "in flight" to exercise concurrency limiting.</summary>
    public TaskCompletionSource<bool>? Gate { get; set; }

    public async Task<string> TranscribeAsync(Stream audio, string contentType, string? language, CancellationToken cancellationToken)
    {
        CallCount++;
        LastContentType = contentType;
        LastLanguage = language;

        // Drain the stream like a real implementation would (also exercises LimitedStream).
        using var buffer = new MemoryStream();
        await audio.CopyToAsync(buffer, cancellationToken);
        LastAudioByteCount = buffer.Length;

        if (ThrowOnTranscribe != null)
        {
            throw ThrowOnTranscribe;
        }
        if (!IsConfigured)
        {
            throw new TranscriptionNotConfiguredException();
        }

        if (Gate != null)
        {
            await Gate.Task;
        }

        return ResultText;
    }
}
