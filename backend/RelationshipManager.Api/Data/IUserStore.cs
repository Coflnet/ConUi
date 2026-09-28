using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Data;

/// <summary>
/// Cassandra access for <see cref="User"/>. Kept separate from <see cref="Auth.AuthService"/> so
/// tests can substitute an in-memory implementation instead of talking to a real cluster.
/// </summary>
public interface IUserStore
{
    Task<User?> GetByAuthProviderIdAsync(string authProviderId);
    Task<User?> GetByIdAsync(Guid id);
    Task UpsertAsync(User user);
}
