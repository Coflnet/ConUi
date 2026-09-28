using RelationshipManager.Api.Auth;

namespace RelationshipManager.Api.Tests.Fakes;

/// <summary>
/// Stand-in for <see cref="IFirebaseTokenVerifier"/>. Defaults to "not configured" (matching a
/// server with no Firebase service account). Tests can flip <see cref="IsConfigured"/> and set
/// <see cref="Result"/>/<see cref="ThrowOnVerify"/> to exercise the configured paths without a
/// real Firebase project.
/// </summary>
public class FakeFirebaseTokenVerifier : IFirebaseTokenVerifier
{
    public bool IsConfigured { get; set; }
    public FirebaseVerificationResult? Result { get; set; }
    public Exception? ThrowOnVerify { get; set; }

    public Task<FirebaseVerificationResult> VerifyAsync(string idToken, CancellationToken cancellationToken = default)
    {
        if (!IsConfigured)
        {
            throw new InvalidOperationException("Firebase is not configured.");
        }
        if (ThrowOnVerify != null)
        {
            throw ThrowOnVerify;
        }
        return Task.FromResult(Result ?? new FirebaseVerificationResult(idToken, null, null));
    }
}
