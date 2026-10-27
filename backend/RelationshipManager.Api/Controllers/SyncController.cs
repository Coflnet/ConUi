using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using RelationshipManager.Api.Errors;
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
    private readonly PackedSyncService _packedSync;
    private readonly ILogger<SyncController> _logger;

    public SyncController(SyncService syncService, IS3Service s3Service, ILogger<SyncController> logger, PackedSyncService packedSync)
    {
        _syncService = syncService;
        _s3Service = s3Service;
        _logger = logger;
        _packedSync = packedSync;
    }

    /// <summary>
    /// Get sync updates since a specific version
    /// </summary>
    [HttpPost("updates")]
    public async Task<ActionResult<SyncResponse>> GetUpdates([FromBody] SyncRequest request)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

        var response = await _syncService.GetUpdatesAsync(userId.Value, request);
        response.Batching = _packedSync.Capabilities;
        return Ok(response);
    }

    /// <summary>
    /// Get all sync entries for the current user
    /// </summary>
    [HttpGet("all")]
    public async Task<ActionResult<List<SyncEntry>>> GetAllEntries()
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

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
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

        try
        {
            var response = await _syncService.GetUploadUrlAsync(userId.Value, request);
            return Ok(response);
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new ApiError("invalid_blob_key", ex.Message));
        }
        catch (InvalidOperationException ex)
        {
            return Conflict(new ApiError("version_conflict", ex.Message));
        }
        catch (S3UnavailableException ex)
        {
            _logger.LogWarning(ex, "Blob storage unavailable while creating an upload URL");
            return StorageUnavailable();
        }
    }

    /// <summary>
    /// Get a pre-signed URL to download a blob
    /// </summary>
    [HttpGet("download/{blobType}/{blobId}")]
    public async Task<ActionResult<BlobDownloadResponse>> GetDownloadUrl(string blobType, string blobId)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

        try
        {
            var response = await _syncService.GetDownloadUrlAsync(userId.Value, blobType, blobId);
            if (response == null)
            {
                return NotFound(new ApiError("not_found", "Blob not found"));
            }

            return Ok(response);
        }
        catch (S3UnavailableException ex)
        {
            _logger.LogWarning(ex, "Blob storage unavailable while creating a download URL");
            return StorageUnavailable();
        }
    }

    /// <summary>
    /// Commit an uploaded blob (call after successful upload to S3)
    /// </summary>
    [HttpPost("commit")]
    public async Task<ActionResult> CommitUpload([FromBody] CommitEntry commit)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

        try
        {
            await _syncService.CommitUploadAsync(userId.Value, commit);
            return Ok();
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new ApiError("invalid_blob_key", ex.Message));
        }
    }

    /// <summary>
    /// Batch commit multiple blobs
    /// </summary>
    [HttpPost("commit/batch")]
    public async Task<ActionResult> BatchCommit([FromBody] BatchCommitRequest request)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

        try
        {
            await _syncService.BatchCommitAsync(userId.Value, request);
            return Ok();
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new ApiError("invalid_blob_key", ex.Message));
        }
    }

    /// <summary>
    /// Mark a blob as deleted
    /// </summary>
    [HttpDelete("{blobType}/{blobId}")]
    public async Task<ActionResult> DeleteEntry(string blobType, string blobId)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

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
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

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
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

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
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

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
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

        try
        {
            var key = SyncService.GetBlobKey(userId.Value, blobType, blobId);
            
            // Verify version conflict before uploading
            var existingEntry = await _syncService.GetEntryAsync(userId.Value, blobType, blobId);
            if (existingEntry != null && existingEntry.Version >= version)
            {
                return Conflict(new ApiError("version_conflict", "A newer version already exists"));
            }

            // Upload to S3 through backend
            await _s3Service.UploadAsync(key, Request.Body);

            _logger.LogInformation("Proxy uploaded blob {BlobType}/{BlobId} for user {UserId}", blobType, blobId, userId);

            return Ok(new { key, message = "Upload successful" });
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new ApiError("invalid_blob_key", ex.Message));
        }
        catch (S3UnavailableException ex)
        {
            _logger.LogWarning(ex, "Blob storage unavailable during proxy upload for {BlobType}/{BlobId}", blobType, blobId);
            return StorageUnavailable();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error in proxy upload for {BlobType}/{BlobId}", blobType, blobId);
            return StatusCode(500, new ApiError("upload_failed", "The upload could not be completed."));
        }
    }

    /// <summary>
    /// Proxy download - downloads blob data directly through the backend
    /// </summary>
    [HttpGet("proxy-download/{blobType}/{blobId}")]
    public async Task<ActionResult> ProxyDownload(string blobType, string blobId)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));

        try
        {
            var key = SyncService.GetBlobKey(userId.Value, blobType, blobId);
            var stream = await _s3Service.DownloadAsync(key);

            if (stream == null)
            {
                return NotFound(new ApiError("not_found", "Blob not found"));
            }

            return File(stream, "application/octet-stream");
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new ApiError("invalid_blob_key", ex.Message));
        }
        catch (S3UnavailableException ex)
        {
            _logger.LogWarning(ex, "Blob storage unavailable during proxy download for {BlobType}/{BlobId}", blobType, blobId);
            return StorageUnavailable();
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error in proxy download for {BlobType}/{BlobId}", blobType, blobId);
            return StatusCode(500, new ApiError("download_failed", "The download could not be completed."));
        }
    }

    [HttpPost("upload/batch")]
    [RequestSizeLimit(8 * 1024 * 1024)]
    public async Task<ActionResult> UploadPackedBatch([FromBody] PackedUploadRequest request)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));
        try
        {
            await _packedSync.UploadAsync(userId.Value, request);
            return Ok();
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new ApiError("invalid_batch", ex.Message));
        }
        catch (InvalidOperationException ex) when (ex.Message == "packing_disabled")
        {
            return Conflict(new ApiError("packing_disabled", "Packed uploads are not enabled."));
        }
        catch (S3UnavailableException)
        {
            return StorageUnavailable();
        }
    }

    [HttpPost("download/batch")]
    [RequestSizeLimit(8 * 1024 * 1024)]
    public async Task<ActionResult<PackedDownloadResponse>> DownloadPackedBatch([FromBody] PackedDownloadRequest request)
    {
        var userId = GetUserId();
        if (userId == null) return Unauthorized(new ApiError("unauthorized", "Authentication is required."));
        try
        {
            return Ok(await _packedSync.DownloadAsync(userId.Value, request));
        }
        catch (ArgumentException ex)
        {
            return BadRequest(new ApiError("invalid_batch", ex.Message));
        }
        catch (KeyNotFoundException)
        {
            return Conflict(new ApiError("blob_missing", "A requested blob is no longer available. Retry synchronization."));
        }
        catch (S3UnavailableException)
        {
            return StorageUnavailable();
        }
    }

    // The short-lived capability grants access to exactly one encrypted slice, including for
    // older clients that follow their existing single-blob download URLs without app JWTs.
    [AllowAnonymous]
    [HttpGet("packed/{ticket}")]
    public async Task<IActionResult> DownloadPackedSlice(string ticket)
    {
        Response.Headers.CacheControl = "private, no-store";
        try
        {
            var stream = await _packedSync.DownloadTicketAsync(ticket);
            return stream == null ? NotFound(new ApiError("not_found", "Blob not found"))
                : File(stream, "application/octet-stream");
        }
        catch (S3UnavailableException)
        {
            return StorageUnavailable();
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

    private ObjectResult StorageUnavailable()
        => StatusCode(StatusCodes.Status503ServiceUnavailable, new ApiError("storage_unavailable", "Blob storage is not available right now."));
}
