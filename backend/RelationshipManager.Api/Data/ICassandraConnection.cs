using CassandraSession = Cassandra.ISession;

namespace RelationshipManager.Api.Data;

/// <summary>
/// Owns the Cassandra session. The real implementation only connects the first time
/// <see cref="Session"/> is accessed, so registering it in DI never opens a socket by itself
/// (important for tests, which substitute a fake instead of touching a real cluster).
/// </summary>
public interface ICassandraConnection
{
    CassandraSession Session { get; }

    /// <summary>
    /// Runs a trivial query against the cluster to prove it is reachable. Used by the
    /// readiness probe. Throws when Cassandra cannot be reached.
    /// </summary>
    Task PingAsync(CancellationToken cancellationToken = default);
}
