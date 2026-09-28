using System.Collections.Concurrent;

namespace RelationshipManager.Api.Services;

/// <summary>
/// Caps how many transcription segments one user can have in flight at once
/// (Transcription:MaxConcurrentPerUser, default 2).
/// </summary>
public class PerUserConcurrencyLimiter
{
    private readonly int _maxConcurrent;
    private readonly ConcurrentDictionary<Guid, SemaphoreSlim> _semaphores = new();

    public PerUserConcurrencyLimiter(IConfiguration config)
    {
        _maxConcurrent = Math.Max(1, config.GetValue("Transcription:MaxConcurrentPerUser", 2));
    }

    /// <summary>Non-blocking: returns false immediately instead of waiting when the user is already at the limit.</summary>
    public bool TryEnter(Guid userId)
    {
        var semaphore = _semaphores.GetOrAdd(userId, _ => new SemaphoreSlim(_maxConcurrent, _maxConcurrent));
        return semaphore.Wait(0);
    }

    public void Release(Guid userId)
    {
        if (_semaphores.TryGetValue(userId, out var semaphore))
        {
            semaphore.Release();
        }
    }
}
