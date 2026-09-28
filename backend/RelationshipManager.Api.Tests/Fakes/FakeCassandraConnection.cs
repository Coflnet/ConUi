using RelationshipManager.Api.Data;
using CassandraSession = Cassandra.ISession;

namespace RelationshipManager.Api.Tests.Fakes;

/// <summary>
/// Stand-in for <see cref="ICassandraConnection"/>. <see cref="Reachable"/> controls what
/// <see cref="PingAsync"/> reports, so tests can exercise both the healthy and unhealthy
/// /health/ready paths without a real cluster. <see cref="Session"/> is intentionally not
/// implemented: nothing in tests should need a real Cassandra session.
/// </summary>
public class FakeCassandraConnection : ICassandraConnection
{
    public bool Reachable { get; set; } = true;

    public CassandraSession Session => throw new NotSupportedException("The fake Cassandra connection has no real session.");

    public Task PingAsync(CancellationToken cancellationToken = default)
    {
        if (!Reachable)
        {
            throw new InvalidOperationException("Cassandra is unreachable (fake)");
        }
        return Task.CompletedTask;
    }
}
