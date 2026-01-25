using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using RelationshipManager.Api.Auth;
using RelationshipManager.Api.Models;
using FirebaseAdmin.Auth;

namespace RelationshipManager.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class AuthController : ControllerBase
{
    private readonly AuthService _authService;
    private readonly ILogger<AuthController> _logger;
    private readonly IConfiguration _config;

    public AuthController(AuthService authService, ILogger<AuthController> logger, IConfiguration config)
    {
        _authService = authService;
        _logger = logger;
        _config = config;
    }

    /// <summary>
    /// Login with Firebase token
    /// </summary>
    [HttpPost("firebase")]
    public async Task<ActionResult<TokenContainer>> LoginWithFirebase([FromBody] LoginRequest request)
    {
        try
        {
            string externalUserId;
            string? email = null;
            string? name = null;

            if (FirebaseAuth.DefaultInstance != null)
            {
                var decodedToken = await FirebaseAuth.DefaultInstance.VerifyIdTokenAsync(request.FirebaseToken);
                externalUserId = decodedToken.Uid;
                email = decodedToken.Claims.TryGetValue("email", out var e) ? e.ToString() : null;
                name = decodedToken.Claims.TryGetValue("name", out var n) ? n.ToString() : null;
            }
            else
            {
                // Development mode - mock token
                _logger.LogWarning("Firebase not initialized, using development mode");
                externalUserId = $"dev_{request.FirebaseToken}";
            }

            var user = await _authService.GetUser(externalUserId);
            Guid userId;

            if (user == null)
            {
                userId = await _authService.CreateUser(externalUserId, name, email);
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
        catch (Exception ex)
        {
            _logger.LogError(ex, "Firebase login failed");
            return BadRequest(new { error = "authentication_failed", message = ex.Message });
        }
    }

    /// <summary>
    /// Development-only login for testing
    /// </summary>
    [HttpPost("dev")]
    public async Task<ActionResult<TokenContainer>> DevLogin([FromBody] DevLoginRequest request)
    {
        if (!_config.GetValue<bool>("ENABLE_DEV_AUTH", true))
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
