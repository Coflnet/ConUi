using System.Collections.Concurrent;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Tests.Fakes;

/// <summary>In-memory stand-in for <see cref="CassandraUserStore"/> so tests never need Cassandra.</summary>
public class InMemoryUserStore : IUserStore
{
    private readonly ConcurrentDictionary<string, User> _byAuthProviderId = new();

    public Task<User?> GetByAuthProviderIdAsync(string authProviderId)
        => Task.FromResult(_byAuthProviderId.TryGetValue(authProviderId, out var user) ? user : null);

    public Task<User?> GetByIdAsync(Guid id)
        => Task.FromResult(_byAuthProviderId.Values.FirstOrDefault(u => u.Id == id));

    public Task UpsertAsync(User user)
    {
        _byAuthProviderId[user.AuthProviderId] = user;
        return Task.CompletedTask;
    }
}
