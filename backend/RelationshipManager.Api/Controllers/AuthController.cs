using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Extensions.Hosting;
using RelationshipManager.Api.Auth;
using RelationshipManager.Api.Errors;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class AuthController : ControllerBase
{
    private readonly AuthService _authService;
    private readonly IFirebaseTokenVerifier _firebaseVerifier;
    private readonly IHostEnvironment _environment;
    private readonly ILogger<AuthController> _logger;
    private readonly IConfiguration _config;

    public AuthController(
        AuthService authService,
        IFirebaseTokenVerifier firebaseVerifier,
        IHostEnvironment environment,
        ILogger<AuthController> logger,
        IConfiguration config)
    {
        _authService = authService;
        _firebaseVerifier = firebaseVerifier;
        _environment = environment;
        _logger = logger;
        _config = config;
    }

    /// <summary>
    /// Login with a Firebase ID token. 503 (sign_in_not_configured) when Firebase isn't set up.
    /// </summary>
    [HttpPost("firebase")]
    public async Task<ActionResult<TokenContainer>> LoginWithFirebase([FromBody] LoginRequest request)
    {
        if (!_firebaseVerifier.IsConfigured)
        {
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new ApiError("sign_in_not_configured", "Firebase sign-in is not configured on this server."));
        }

        FirebaseVerificationResult verified;
        try
        {
            verified = await _firebaseVerifier.VerifyAsync(request.FirebaseToken);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Firebase token verification failed");
            return Unauthorized(new ApiError("invalid_token", "The provided Firebase token could not be verified."));
        }

        var user = await _authService.GetUser(verified.Uid);
        Guid userId;

        if (user == null)
        {
            userId = await _authService.CreateUser(verified.Uid, verified.Name, verified.Email);
            _logger.LogInformation("Created new user: {UserId}", userId);
        }
        else
        {
            userId = user.Id;
            await _authService.UpdateUserLastSeen(user);
        }

        var token = _authService.CreateTokenFor(userId);

        return Ok(new TokenContainer { AuthToken = token });
    }

    /// <summary>
    /// Development-only login for testing. 404 unless the environment is Development AND
    /// ENABLE_DEV_AUTH is true (default false).
    /// </summary>
    [HttpPost("dev")]
    public async Task<ActionResult<TokenContainer>> DevLogin([FromBody] DevLoginRequest request)
    {
        if (!_environment.IsDevelopment() || !_config.GetValue("ENABLE_DEV_AUTH", false))
        {
            return NotFound();
        }

        var externalUserId = $"dev_{request.UserId}";
        var user = await _authService.GetUser(externalUserId);
        Guid userId;

        if (user == null)
        {
            userId = await _authService.CreateUser(externalUserId, request.Name, request.Email);
            _logger.LogInformation("Created new dev user: {UserId}", userId);
        }
        else
        {
            userId = user.Id;
            await _authService.UpdateUserLastSeen(user);
        }

        var token = _authService.CreateTokenFor(userId);

        return Ok(new TokenContainer { AuthToken = token });
    }

    /// <summary>
    /// Get current user info
    /// </summary>
    [Authorize]
    [HttpGet("me")]
    public async Task<ActionResult<User>> GetCurrentUser()
    {
        var userId = GetUserId();
        if (userId == null)
        {
            return Unauthorized();
        }

        var user = await _authService.GetUserById(userId.Value);
        if (user == null)
        {
            return NotFound();
        }

        return Ok(user);
    }

    private Guid? GetUserId()
    {
        var sub = User.Claims.FirstOrDefault(c => c.Type == "sub")?.Value;
        if (Guid.TryParse(sub, out var userId))
        {
            return userId;
        }
        return null;
    }
}
