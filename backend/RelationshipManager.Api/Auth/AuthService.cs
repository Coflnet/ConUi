using Cassandra;
using Cassandra.Data.Linq;
using Cassandra.Mapping;
using RelationshipManager.Api.Models;
using Microsoft.IdentityModel.Tokens;
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using CassandraSession = Cassandra.ISession;

namespace RelationshipManager.Api.Auth;

public class AuthService
{
    private readonly Table<User> _userTable;
    private readonly IConfiguration _config;
    private readonly ILogger<AuthService> _logger;

    public AuthService(CassandraSession session, IConfiguration config, ILogger<AuthService> logger)
    {
        var mapping = new MappingConfiguration()
            .Define(new Map<User>()
                .TableName("users")
                .PartitionKey(u => u.AuthProviderId)
                .Column(u => u.Id, cm => cm.WithSecondaryIndex())
                .Column(u => u.Email, cm => cm.WithSecondaryIndex())
            );
        _userTable = new Table<User>(session, mapping);
        _userTable.CreateIfNotExists();
        _config = config;
        _logger = logger;
    }

    public async Task<Guid> GetUserId(string authProviderId)
    {
        var users = await _userTable.Where(u => u.AuthProviderId == authProviderId)
            .Select(u => u.Id)
            .ExecuteAsync();
        return users.FirstOrDefault();
    }

    public async Task<User?> GetUser(string authProviderId)
    {
        var users = await _userTable.Where(u => u.AuthProviderId == authProviderId)
            .ExecuteAsync();
        return users.FirstOrDefault();
    }

    public async Task<User?> GetUserById(Guid userId)
    {
        var users = await _userTable.Where(u => u.Id == userId)
            .ExecuteAsync();
        return users.FirstOrDefault();
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
        await _userTable.Insert(user).ExecuteAsync();
        return user.Id;
    }

    public async Task UpdateUserLastSeen(User user)
    {
        user.LastSeenAt = DateTime.UtcNow;
        await _userTable.Insert(user).ExecuteAsync();
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
