using System.Security.Authentication;
using System.Security.Cryptography.X509Certificates;
using System.Text.RegularExpressions;
using Cassandra;
using CassandraSession = Cassandra.ISession;

namespace RelationshipManager.Api.Data;

/// <summary>
/// Builds the Cassandra session from the "CASSANDRA" configuration section, mirroring the
/// connection handling Coflnet's other services use (see CoflnetCore/Cassandra/CassandraServiceExtensions.cs):
/// connect without a default keyspace, create the keyspace with the configured replication if it
/// does not exist yet, then switch to it. Optional client-certificate TLS is used when
/// CASSANDRA__X509Certificate_PATHS is set, which production requires for Scylla.
/// </summary>
public class CassandraConnection : ICassandraConnection
{
    private readonly Lazy<CassandraSession> _session;
    private readonly ILogger<CassandraConnection> _logger;

    public CassandraConnection(IConfiguration config, ILogger<CassandraConnection> logger)
    {
        _logger = logger;
        _session = new Lazy<CassandraSession>(() => Connect(config, logger), LazyThreadSafetyMode.ExecutionAndPublication);
    }

    public CassandraSession Session => _session.Value;

    public async Task PingAsync(CancellationToken cancellationToken = default)
    {
        // system.local always exists and requires no keyspace, so this proves connectivity
        // without depending on our own schema being present yet.
        await Session.ExecuteAsync(new SimpleStatement("SELECT now() FROM system.local"));
    }

    private static CassandraSession Connect(IConfiguration config, ILogger logger)
    {
        var section = config.GetSection("CASSANDRA");
        var hosts = section["HOSTS"] ?? "localhost";
        var keyspace = section["KEYSPACE"] ?? throw new InvalidOperationException("CASSANDRA:KEYSPACE must be set to a keyspace name.");
        if (Regex.IsMatch(keyspace, @"[^a-zA-Z0-9_]"))
        {
            throw new InvalidOperationException("CASSANDRA:KEYSPACE must only contain alphanumeric characters and underscores.");
        }

        logger.LogInformation("Connecting to Cassandra hosts {Hosts}, keyspace {Keyspace}", hosts, keyspace);

        var builder = Cluster.Builder()
            .AddContactPoints(hosts.Split(','))
            .WithLoadBalancingPolicy(new TokenAwarePolicy(new DCAwareRoundRobinPolicy()))
            .WithCredentials(section["USER"], section["PASSWORD"])
            .WithDefaultKeyspace(keyspace);

        var certificatePaths = section["X509Certificate_PATHS"];
        if (!string.IsNullOrEmpty(certificatePaths))
        {
            var password = section["X509Certificate_PASSWORD"]
                ?? throw new InvalidOperationException("CASSANDRA:X509Certificate_PASSWORD must be set if CASSANDRA:X509Certificate_PATHS is set.");
            CustomRootCaCertificateValidator? certificateValidator = null;
            var validationCertificatePath = section["X509Certificate_VALIDATION_PATH"];
            if (!string.IsNullOrEmpty(validationCertificatePath))
            {
                certificateValidator = new CustomRootCaCertificateValidator(new X509Certificate2(validationCertificatePath, password));
            }

            var sslOptions = new SSLOptions(
                SslProtocols.Tls12,
                false,
                (sender, certificate, chain, errors) => certificate != null && chain != null && (certificateValidator?.Validate(certificate, chain, errors) ?? true)
            ).SetCertificateCollection(new X509Certificate2Collection(certificatePaths.Split(',').Select(p => new X509Certificate2(p, password)).ToArray()));
            builder.WithSSL(sslOptions);
            logger.LogInformation("Using Cassandra client certificate TLS");
        }

        var cluster = builder.Build();
        // Connect without a default keyspace first so keyspace creation works against an empty database.
        var session = cluster.Connect(null);
        try
        {
            session.CreateKeyspaceIfNotExists(keyspace, new Dictionary<string, string>
            {
                { "class", section["REPLICATION_CLASS"] ?? "NetworkTopologyStrategy" },
                { "replication_factor", section["REPLICATION_FACTOR"] ?? "3" }
            });
            logger.LogInformation("Cassandra keyspace {Keyspace} ready", keyspace);
        }
        catch (UnauthorizedException)
        {
            logger.LogInformation("Not authorized to create keyspace {Keyspace}, assuming it already exists", keyspace);
        }
        finally
        {
            session.ChangeKeyspace(keyspace);
        }

        return session;
    }
}
