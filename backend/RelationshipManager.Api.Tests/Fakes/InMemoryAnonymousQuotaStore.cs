using RelationshipManager.Api.Services;

namespace RelationshipManager.Api.Tests.Fakes;

public sealed class InMemoryAnonymousQuotaStore : IAnonymousQuotaStore
{
    private readonly Dictionary<string, string> _states = new();
    public Task<string?> ReadAsync(string key)
    {
        lock (_states) return Task.FromResult(_states.GetValueOrDefault(key));
    }
    public Task<bool> CompareExchangeAsync(string key, string? previous, string next)
    {
        lock (_states)
        {
            if (_states.GetValueOrDefault(key) != previous) return Task.FromResult(false);
            _states[key] = next;
            return Task.FromResult(true);
        }
    }
}
