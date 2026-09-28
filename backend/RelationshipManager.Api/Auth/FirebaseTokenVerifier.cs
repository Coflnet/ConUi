using FirebaseAdmin;
using FirebaseAdmin.Auth;

namespace RelationshipManager.Api.Auth;

public class FirebaseTokenVerifier : IFirebaseTokenVerifier
{
    public bool IsConfigured => FirebaseApp.DefaultInstance != null;

    public async Task<FirebaseVerificationResult> VerifyAsync(string idToken, CancellationToken cancellationToken = default)
    {
        if (FirebaseApp.DefaultInstance == null)
        {
            throw new InvalidOperationException("Firebase is not configured.");
        }

        var decoded = await FirebaseAuth.DefaultInstance.VerifyIdTokenAsync(idToken, cancellationToken);
        var email = decoded.Claims.TryGetValue("email", out var e) ? e?.ToString() : null;
        var name = decoded.Claims.TryGetValue("name", out var n) ? n?.ToString() : null;
        return new FirebaseVerificationResult(decoded.Uid, email, name);
    }
}
