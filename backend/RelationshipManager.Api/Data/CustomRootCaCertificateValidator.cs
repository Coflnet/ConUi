using System.Net.Security;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;

namespace RelationshipManager.Api.Data;

/// <summary>
/// Validates a server certificate chain against a pinned root CA instead of the system trust
/// store, including when the server omits its root certificate from the presented chain.
/// </summary>
public class CustomRootCaCertificateValidator
{
    private readonly X509Certificate2 _trustedRootCertificateAuthority;

    public CustomRootCaCertificateValidator(X509Certificate2 trustedRootCertificateAuthority)
    {
        _trustedRootCertificateAuthority = trustedRootCertificateAuthority;
    }

    public bool Validate(X509Certificate cert, X509Chain chain, SslPolicyErrors errors)
    {
        if ((errors & SslPolicyErrors.RemoteCertificateNotAvailable) != 0)
        {
            Console.WriteLine("SSL validation failed due to SslPolicyErrors.RemoteCertificateNotAvailable.");
            return false;
        }

        if ((errors & SslPolicyErrors.RemoteCertificateNameMismatch) != 0)
        {
            Console.WriteLine("SSL validation failed due to SslPolicyErrors.RemoteCertificateNameMismatch.");
            return false;
        }

        using var trustedChain = new X509Chain();
        trustedChain.ChainPolicy.TrustMode = X509ChainTrustMode.CustomRootTrust;
        trustedChain.ChainPolicy.CustomTrustStore.Add(_trustedRootCertificateAuthority);
        trustedChain.ChainPolicy.RevocationMode = X509RevocationMode.NoCheck;
        trustedChain.ChainPolicy.ApplicationPolicy.Add(new Oid("1.3.6.1.5.5.7.3.1")); // TLS server authentication
        foreach (var element in chain.ChainElements)
            trustedChain.ChainPolicy.ExtraStore.Add(element.Certificate);
        using var serverCertificate = new X509Certificate2(cert);
        return trustedChain.Build(serverCertificate);
    }
}
