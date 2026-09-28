using Microsoft.AspNetCore.Mvc;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;
using RelationshipManager.Api.Services;

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
    private readonly ICassandraConnection _cassandra;
    private readonly IS3Service _s3;

    public HealthController(ICassandraConnection cassandra, IS3Service s3)
    {
        _cassandra = cassandra;
        _s3 = s3;
    }

    /// <summary>Liveness: always OK, never touches Cassandra/S3/transcription.</summary>
    [HttpGet]
    public IActionResult Live() => Ok(new HealthStatus { Status = "healthy", Timestamp = DateTime.UtcNow });

    /// <summary>
    /// Readiness: checks Cassandra answers a trivial query, and reports whether S3 is configured.
    /// Never reveals hosts or credentials - only booleans. 503 when Cassandra is unavailable.
    /// </summary>
    [HttpGet("ready")]
    public async Task<IActionResult> Ready()
    {
        bool cassandraOk;
        try
        {
            await _cassandra.PingAsync(HttpContext.RequestAborted);
            cassandraOk = true;
        }
        catch
        {
            cassandraOk = false;
        }

        var status = new ReadinessStatus
        {
            Cassandra = cassandraOk,
            S3Configured = _s3.IsConfigured
        };

        return cassandraOk ? Ok(status) : StatusCode(StatusCodes.Status503ServiceUnavailable, status);
    }
}
