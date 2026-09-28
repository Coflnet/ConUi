namespace RelationshipManager.Api.Auth;

public record FirebaseVerificationResult(string Uid, string? Email, string? Name);

/// <summary>
/// Verifies a Firebase ID token. Kept separate from <see cref="AuthService"/>/AuthController so
/// tests can substitute a fake instead of needing a real Firebase service account, and so the
/// controller never falls back to trusting an unverified token when Firebase isn't configured.
/// </summary>
public interface IFirebaseTokenVerifier
{
    /// <summary>True once a Firebase app has been initialized (see GOOGLE_APPLICATION_CREDENTIALS in RelationshipManagerApp).</summary>
    bool IsConfigured { get; }

    /// <summary>Throws if not configured, or if the token fails verification.</summary>
    Task<FirebaseVerificationResult> VerifyAsync(string idToken, CancellationToken cancellationToken = default);
}
