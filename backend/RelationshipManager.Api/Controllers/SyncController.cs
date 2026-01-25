using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using RelationshipManager.Api.Models;
using RelationshipManager.Api.Services;

namespace RelationshipManager.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class SyncController : ControllerBase
{
    private readonly SyncService _syncService;
    private readonly IS3Service _s3Service;
    private readonly ILogger<SyncController> _logger;

    public SyncController(SyncService syncService, IS3Service s3Service, ILogger<SyncController> logger)
    {
        _syncService = syncService;
        _s3Service = s3Service;
        _logger = logger;
    }

    /// <summary>
    /// Get sync updates since a specific version
    /// </summary>
    [HttpPost("updates")]
    public async Task<ActionResult<SyncResponse>> GetUpdates([FromBody] SyncRequest request)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        var response = await _syncService.GetUpdatesAsync(userId.Value, request);
        return Ok(response);
    }

    /// <summary>
    /// Get all sync entries for the current user
    /// </summary>
    [HttpGet("all")]
    public async Task<ActionResult<List<SyncEntry>>> GetAllEntries()
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        var entries = await _syncService.GetAllEntriesAsync(userId.Value);
        return Ok(entries);
    }

    /// <summary>
    /// Get a pre-signed URL to upload a blob
    /// </summary>
    [HttpPost("upload")]
    public async Task<ActionResult<BlobUploadResponse>> GetUploadUrl([FromBody] BlobUploadRequest request)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        try
        {
            var response = await _syncService.GetUploadUrlAsync(userId.Value, request);
            return Ok(response);
        }
        catch (InvalidOperationException ex)
        {
            return Conflict(new { error = "version_conflict", message = ex.Message });
        }
    }

    /// <summary>
    /// Get a pre-signed URL to download a blob
    /// </summary>
    [HttpGet("download/{blobType}/{blobId}")]
    public async Task<ActionResult<BlobDownloadResponse>> GetDownloadUrl(string blobType, string blobId)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        var response = await _syncService.GetDownloadUrlAsync(userId.Value, blobType, blobId);
        if (response == null)
        {
            return NotFound();
        }

        return Ok(response);
    }

    /// <summary>
    /// Commit an uploaded blob (call after successful upload to S3)
    /// </summary>
    [HttpPost("commit")]
    public async Task<ActionResult> CommitUpload([FromBody] CommitEntry commit)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        await _syncService.CommitUploadAsync(userId.Value, commit);
        return Ok();
    }

    /// <summary>
    /// Batch commit multiple blobs
    /// </summary>
    [HttpPost("commit/batch")]
    public async Task<ActionResult> BatchCommit([FromBody] BatchCommitRequest request)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        await _syncService.BatchCommitAsync(userId.Value, request);
        return Ok();
    }

    /// <summary>
    /// Mark a blob as deleted
    /// </summary>
    [HttpDelete("{blobType}/{blobId}")]
    public async Task<ActionResult> DeleteEntry(string blobType, string blobId)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        await _syncService.DeleteEntryAsync(userId.Value, blobType, blobId);
        return Ok();
    }

    /// <summary>
    /// Register or update device info
    /// </summary>
    [HttpPost("device")]
    public async Task<ActionResult<UserDevice>> RegisterDevice([FromBody] DeviceRegistrationRequest request)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        var device = await _syncService.RegisterDeviceAsync(userId.Value, request);
        return Ok(device);
    }

    /// <summary>
    /// Get all devices for the current user
    /// </summary>
    [HttpGet("devices")]
    public async Task<ActionResult<List<UserDevice>>> GetDevices()
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        var devices = await _syncService.GetUserDevicesAsync(userId.Value);
        return Ok(devices);
    }

    /// <summary>
    /// Get storage info for the current user
    /// </summary>
    [HttpGet("storage")]
    public async Task<ActionResult<StorageInfoResponse>> GetStorageInfo()
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        var info = await _syncService.GetStorageInfoAsync(userId.Value);
        return Ok(info);
    }

    /// <summary>
    /// Proxy upload - uploads blob data directly through the backend
    /// </summary>
    [HttpPost("proxy-upload/{blobType}/{blobId}")]
    [RequestSizeLimit(52_428_800)] // 50MB limit
    public async Task<ActionResult> ProxyUpload(string blobType, string blobId, [FromQuery] long version)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        try
        {
            var key = $"{userId}/{blobType}/{blobId}";
            
            // Verify version conflict before uploading
            var existingEntry = await _syncService.GetEntryAsync(userId.Value, blobType, blobId);
            if (existingEntry != null && existingEntry.Version >= version)
            {
                return Conflict(new { error = "version_conflict", message = "A newer version already exists" });
            }

            // Upload to S3 through backend
            await _s3Service.UploadAsync(key, Request.Body);

            _logger.LogInformation("Proxy uploaded blob {BlobType}/{BlobId} for user {UserId}", blobType, blobId, userId);
            
            return Ok(new { key, message = "Upload successful" });
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error in proxy upload for {BlobType}/{BlobId}", blobType, blobId);
            return StatusCode(500, new { error = "upload_failed", message = ex.Message });
        }
    }

    /// <summary>
    /// Proxy download - downloads blob data directly through the backend
    /// </summary>
    [HttpGet("proxy-download/{blobType}/{blobId}")]
    public async Task<ActionResult> ProxyDownload(string blobType, string blobId)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized();

        try
        {
            var key = $"{userId}/{blobType}/{blobId}";
            var stream = await _s3Service.DownloadAsync(key);
            
            if (stream == null)
            {
                return NotFound(new { error = "not_found", message = "Blob not found" });
            }

            return File(stream, "application/octet-stream");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error in proxy download for {BlobType}/{BlobId}", blobType, blobId);
            return StatusCode(500, new { error = "download_failed", message = ex.Message });
        }
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
