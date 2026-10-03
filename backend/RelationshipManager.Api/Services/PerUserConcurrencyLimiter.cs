using System.Collections.Concurrent;

namespace RelationshipManager.Api.Services;

/// <summary>
/// Caps how many transcription segments one user can have in flight at once
/// (Transcription:MaxConcurrentPerUser, default 2).
/// </summary>
public class PerUserConcurrencyLimiter
{
    private readonly int _maxConcurrent;
    private readonly ConcurrentDictionary<Guid, int> _active = new();

    public PerUserConcurrencyLimiter(IConfiguration config)
    {
        _maxConcurrent = Math.Max(1, config.GetValue("Transcription:MaxConcurrentPerUser", 2));
    }

    /// <summary>Non-blocking: returns false immediately instead of waiting when the user is already at the limit.</summary>
    public bool TryEnter(Guid userId)
    {
        while (true)
        {
            if (!_active.TryGetValue(userId, out var count))
            {
                if (_active.TryAdd(userId, 1)) return true;
                continue;
            }
            if (count >= _maxConcurrent) return false;
            if (_active.TryUpdate(userId, count + 1, count)) return true;
        }
    }

    public void Release(Guid userId)
    {
        while (_active.TryGetValue(userId, out var count))
        {
            if (count == 1)
            {
                if (((ICollection<KeyValuePair<Guid, int>>)_active).Remove(new(userId, count))) return;
            }
            else if (_active.TryUpdate(userId, count - 1, count)) return;
        }
    }
}
