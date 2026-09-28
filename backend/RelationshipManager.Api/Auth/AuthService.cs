using Microsoft.IdentityModel.Tokens;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;

namespace RelationshipManager.Api.Auth;

public class AuthService
{
    private readonly IUserStore _userStore;
    private readonly IConfiguration _config;
    private readonly ILogger<AuthService> _logger;

    public AuthService(IUserStore userStore, IConfiguration config, ILogger<AuthService> logger)
    {
        _userStore = userStore;
        _config = config;
        _logger = logger;
    }

    public async Task<User?> GetUser(string authProviderId)
    {
        return await _userStore.GetByAuthProviderIdAsync(authProviderId);
    }

    public async Task<User?> GetUserById(Guid userId)
    {
        return await _userStore.GetByIdAsync(userId);
    }

    public async Task<Guid> CreateUser(string authProviderId, string? name = null, string? email = null)
    {
        var salt = Convert.ToBase64String(System.Security.Cryptography.RandomNumberGenerator.GetBytes(32));
        var user = new User
        {
            Id = Guid.NewGuid(),
            Name = name,
            Email = email,
            AuthProviderId = authProviderId,
            CreatedAt = DateTime.UtcNow,
            LastSeenAt = DateTime.UtcNow,
            EncryptionKeySalt = salt
        };
        await _userStore.UpsertAsync(user);
        return user.Id;
    }

    public async Task UpdateUserLastSeen(User user)
    {
        user.LastSeenAt = DateTime.UtcNow;
        await _userStore.UpsertAsync(user);
    }

    public string CreateTokenFor(Guid userId, int validForDays = 30, params Claim[] additionalClaims)
    {
        var key = _config["jwt:secret"] ?? throw new InvalidOperationException("jwt:secret not set");
        var issuer = _config["jwt:issuer"] ?? throw new InvalidOperationException("jwt:issuer not set");

        var securityKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(key));
        var credentials = new SigningCredentials(securityKey, SecurityAlgorithms.HmacSha256);

        var claims = new List<Claim>
        {
            new(JwtRegisteredClaimNames.Jti, Guid.NewGuid().ToString()),
            new(JwtRegisteredClaimNames.Sub, userId.ToString())
        };
        claims.AddRange(additionalClaims);

        var token = new JwtSecurityToken(
            issuer,
            issuer,
            claims,
            expires: DateTime.UtcNow.AddDays(validForDays),
            signingCredentials: credentials);

        return new JwtSecurityTokenHandler().WriteToken(token);
    }
}
