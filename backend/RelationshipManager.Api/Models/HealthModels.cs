namespace RelationshipManager.Api.Models;

public class HealthStatus
{
    public string Status { get; set; } = string.Empty;
    public DateTime Timestamp { get; set; }
}

/// <summary>
/// Readiness body. Deliberately only booleans - never hosts, ports or credentials.
/// </summary>
public class ReadinessStatus
{
    public bool Cassandra { get; set; }
    public bool S3Configured { get; set; }
}
