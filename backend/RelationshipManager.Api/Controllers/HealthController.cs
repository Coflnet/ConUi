using Microsoft.AspNetCore.Mvc;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Controllers;

/// <summary>
/// Liveness/readiness probes.
/// Note: minimal-API endpoints (<c>app.MapGet(...)</c> returning <c>Results.Ok(...)</c>) hit a
/// PipeWriter.UnflushedBytes serialization bug under this environment's TestServer, so these are
/// plain MVC actions like the rest of the API instead.
/// </summary>
[ApiController]
[Route("health")]
public class HealthController : ControllerBase
{
    /// <summary>Liveness: always OK, never touches Cassandra/S3/transcription.</summary>
    [HttpGet]
    public IActionResult Live() => Ok(new HealthStatus { Status = "healthy", Timestamp = DateTime.UtcNow });
}
