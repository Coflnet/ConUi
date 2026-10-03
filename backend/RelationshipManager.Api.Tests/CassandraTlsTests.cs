using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using SSLOptions = Cassandra.SSLOptions;
using RelationshipManager.Api.Data;

namespace RelationshipManager.Api.Tests;

public class CassandraTlsTests
{
    [TestCase("sky-client", true, false, true)]
    [TestCase("incorrect-name", true, false, false)]
    [TestCase("sky-client", false, false, false)]
    [TestCase("sky-client", true, true, false)]
    public async Task PinnedCaTls_RequiresExpectedServerNameAndTrustedRoot(string expectedName, bool trustRoot, bool expired, bool accepted)
    {
        using var rootKey = RSA.Create(2048);
        var rootRequest = new CertificateRequest("CN=scylla-client", rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        rootRequest.CertificateExtensions.Add(new X509BasicConstraintsExtension(true, false, 0, true));
        rootRequest.CertificateExtensions.Add(new X509KeyUsageExtension(X509KeyUsageFlags.KeyCertSign, true));
        using var root = rootRequest.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        using var serverKey = RSA.Create(2048);
        // Match the deployed certificate's CN-only identity (no SAN).
        var serverRequest = new CertificateRequest("CN=sky-client", serverKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var publicServer = serverRequest.Create(root, DateTimeOffset.UtcNow.AddHours(-2), DateTimeOffset.UtcNow.AddHours(expired ? -1 : 1), RandomNumberGenerator.GetBytes(16));
        using var serverCertificate = publicServer.CopyWithPrivateKey(serverKey);
        using var otherRoot = new CertificateRequest("CN=unrelated-ca", rootKey, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1)
            .CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        var validator = new CustomRootCaCertificateValidator(trustRoot ? root : otherRoot);
        SslPolicyErrors observedErrors = SslPolicyErrors.None;
        var ssl = new SSLOptions(SslProtocols.Tls12, false, (_, certificate, chain, errors) =>
        {
            observedErrors = errors;
            return certificate != null && chain != null && validator.Validate(certificate, chain, errors);
        }).SetHostNameResolver(_ => expectedName);

        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        var serverTask = AuthenticateServer();
        using var client = new TcpClient();
        await client.ConnectAsync(IPAddress.Loopback, ((IPEndPoint)listener.LocalEndpoint).Port, deadline.Token);
        using var stream = new SslStream(client.GetStream(), false, ssl.RemoteCertValidationCallback);
        var options = new SslClientAuthenticationOptions
        {
            TargetHost = ssl.HostNameResolver(IPAddress.Loopback),
            EnabledSslProtocols = ssl.SslProtocol,
            CertificateRevocationCheckMode = X509RevocationMode.NoCheck
        };
        if (accepted)
            await stream.AuthenticateAsClientAsync(options, deadline.Token);
        else
            Assert.ThrowsAsync<AuthenticationException>(() => stream.AuthenticateAsClientAsync(options, deadline.Token));
        await serverTask;
        Assert.That(observedErrors.HasFlag(SslPolicyErrors.RemoteCertificateNameMismatch), Is.EqualTo(expectedName != "sky-client"));
        Assert.That(observedErrors.HasFlag(SslPolicyErrors.RemoteCertificateChainErrors), Is.True, "The synthetic root must require explicit CA pinning");

        async Task AuthenticateServer()
        {
            using var connection = await listener.AcceptTcpClientAsync(deadline.Token);
            using var serverStream = new SslStream(connection.GetStream());
            try
            {
                await serverStream.AuthenticateAsServerAsync(new SslServerAuthenticationOptions
                {
                    ServerCertificate = serverCertificate,
                    EnabledSslProtocols = SslProtocols.Tls12,
                    CertificateRevocationCheckMode = X509RevocationMode.NoCheck
                }, deadline.Token);
            }
            catch (AuthenticationException) when (!accepted) { }
            catch (IOException) when (!accepted) { }
        }
    }
}
