namespace RelationshipManager.Api.Models;

public class User
{
    public Guid Id { get; set; }
    public string? Name { get; set; }
    public string? Email { get; set; }
    public string AuthProviderId { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; }
    public DateTime LastSeenAt { get; set; }
    public string? EncryptionKeySalt { get; set; } // Salt used for key derivation
}

public class TokenContainer
{
    public string AuthToken { get; set; } = string.Empty;
}

public class LoginRequest
{
    public string FirebaseToken { get; set; } = string.Empty;
}

// For mock login in development
public class DevLoginRequest
{
    public string UserId { get; set; } = string.Empty;
    public string? Name { get; set; }
    public string? Email { get; set; }
}
