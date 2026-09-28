using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Services;

public class SyncService
{
    private readonly ISyncStore _store;
    private readonly IS3Service _s3Service;
    private readonly ILogger<SyncService> _logger;
    private const long DefaultStorageLimit = 100 * 1024 * 1024; // 100MB

    public SyncService(ISyncStore store, IS3Service s3Service, ILogger<SyncService> logger)
    {
        _store = store;
        _s3Service = s3Service;
        _logger = logger;
    }

    public async Task<SyncResponse> GetUpdatesAsync(Guid userId, SyncRequest request)
    {
        // Fetch all entries for user, then filter by version in memory
        // Cassandra LINQ can't do range queries on clustering keys without ALLOW FILTERING
        var allEntriesResult = await _store.GetSyncEntriesAsync(userId);

        var newEntries = allEntriesResult
            .Where(e => e.Version > request.LastSyncVersion)
            .ToList();

        if (request.BlobTypes?.Count > 0)
        {
            newEntries = newEntries.Where(e => request.BlobTypes.Contains(e.BlobType)).ToList();
        }

        // Update device sync info if device ID provided
        if (!string.IsNullOrEmpty(request.DeviceId))
        {
            await UpdateDeviceSyncAsync(userId, request.DeviceId,
                newEntries.Count > 0 ? newEntries.Max(e => e.Version) : request.LastSyncVersion);
        }

        // Get storage info
        var storageInfo = await GetStorageInfoAsync(userId);

        return new SyncResponse
        {
            Entries = newEntries,
            LatestVersion = newEntries.Count > 0 ? newEntries.Max(e => e.Version) : request.LastSyncVersion,
            StorageInfo = storageInfo
        };
    }

    public async Task<BlobUploadResponse> GetUploadUrlAsync(Guid userId, BlobUploadRequest request)
    {
        // Check for version conflicts using the user_objects table
        var existing = await _store.GetUserObjectAsync(userId, request.BlobType, request.BlobId);
        if (existing != null && request.ExpectedVersion > 0 && existing.Version != request.ExpectedVersion)
        {
            throw new InvalidOperationException($"Version conflict: expected {request.ExpectedVersion}, current is {existing.Version}");
        }

        var newVersion = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var s3Key = $"{userId}/{request.BlobType}/{request.BlobId}_{newVersion}";

        var uploadUrl = await _s3Service.GetUploadUrlAsync(s3Key, TimeSpan.FromMinutes(15));

        return new BlobUploadResponse
        {
            UploadUrl = uploadUrl,
            S3Key = s3Key,
            Version = newVersion
        };
    }

    public async Task<BlobDownloadResponse?> GetDownloadUrlAsync(Guid userId, string blobType, string blobId)
    {
        var entry = await _store.GetUserObjectAsync(userId, blobType, blobId);
        if (entry == null || entry.IsDeleted)
        {
            return null;
        }

        var downloadUrl = await _s3Service.GetDownloadUrlAsync(entry.S3Key, TimeSpan.FromMinutes(15));

        return new BlobDownloadResponse
        {
            DownloadUrl = downloadUrl,
            Version = entry.Version,
            Checksum = string.Empty
        };
    }

    public async Task CommitUploadAsync(Guid userId, CommitEntry commit)
    {
        var version = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var now = DateTime.UtcNow;

        // Get existing object for size delta calculation
        var existing = await _store.GetUserObjectAsync(userId, commit.BlobType, commit.BlobId);

        // Calculate size delta for storage tracking
        long sizeDelta = commit.Size;
        if (existing != null)
        {
            sizeDelta = commit.Size - existing.Size;
        }

        // Create sync entry for the update log
        var syncEntry = new SyncEntry
        {
            UserId = userId,
            BlobType = commit.BlobType,
            BlobId = commit.BlobId,
            S3Key = commit.S3Key,
            Version = version,
            CreatedAt = existing?.CreatedAt ?? now,
            UpdatedAt = now,
            Checksum = commit.Checksum,
            Size = commit.Size,
            IsDeleted = commit.IsDeleted
        };

        // Create/update user object entry
        var userObject = new UserObject
        {
            UserId = userId,
            BlobType = commit.BlobType,
            BlobId = commit.BlobId,
            S3Key = commit.S3Key,
            Version = version,
            Size = commit.Size,
            IsDeleted = commit.IsDeleted,
            CreatedAt = existing?.CreatedAt ?? now,
            UpdatedAt = now
        };

        // Insert sync entry (append-only log)
        await _store.InsertSyncEntryAsync(syncEntry);

        // Upsert user object (current state)
        await _store.UpsertUserObjectAsync(userObject);

        // Update storage usage
        await UpdateStorageUsageAsync(userId, sizeDelta);

        _logger.LogInformation("Committed blob: {BlobType}/{BlobId} for user {UserId}",
            commit.BlobType, commit.BlobId, userId);
    }

    public async Task BatchCommitAsync(Guid userId, BatchCommitRequest request)
    {
        foreach (var commit in request.Entries)
        {
            await CommitUploadAsync(userId, commit);
        }
    }

    public async Task<SyncEntry?> GetEntryAsync(Guid userId, string blobType, string blobId)
    {
        var obj = await _store.GetUserObjectAsync(userId, blobType, blobId);
        if (obj == null)
        {
            return null;
        }

        return new SyncEntry
        {
            UserId = obj.UserId,
            BlobType = obj.BlobType,
            BlobId = obj.BlobId,
            S3Key = obj.S3Key,
            Version = obj.Version,
            Size = obj.Size,
            IsDeleted = obj.IsDeleted,
            CreatedAt = obj.CreatedAt,
            UpdatedAt = obj.UpdatedAt
        };
    }

    public async Task<List<SyncEntry>> GetAllEntriesAsync(Guid userId)
    {
        // Return current state from user_objects, converted to SyncEntry format
        var objects = await _store.GetUserObjectsAsync(userId);

        return objects.Select(o => new SyncEntry
        {
            UserId = o.UserId,
            BlobType = o.BlobType,
            BlobId = o.BlobId,
            S3Key = o.S3Key,
            Version = o.Version,
            Size = o.Size,
            IsDeleted = o.IsDeleted,
            CreatedAt = o.CreatedAt,
            UpdatedAt = o.UpdatedAt,
            Checksum = string.Empty
        }).ToList();
    }

    public async Task DeleteEntryAsync(Guid userId, string blobType, string blobId)
    {
        var entry = await _store.GetUserObjectAsync(userId, blobType, blobId);
        if (entry != null)
        {
            // Mark as deleted via commit
            await CommitUploadAsync(userId, new CommitEntry
            {
                BlobType = blobType,
                BlobId = blobId,
                S3Key = entry.S3Key,
                Checksum = string.Empty,
                Size = 0,
                IsDeleted = true
            });
        }
    }

    // Device management
    public async Task<UserDevice?> RegisterDeviceAsync(Guid userId, DeviceRegistrationRequest request)
    {
        var now = DateTime.UtcNow;
        var existing = await _store.GetDeviceAsync(userId, request.DeviceId);

        var device = new UserDevice
        {
            UserId = userId,
            DeviceId = request.DeviceId,
            DeviceName = request.DeviceName,
            Platform = request.Platform,
            LastSyncVersion = existing?.LastSyncVersion ?? 0,
            LastSyncTime = existing?.LastSyncTime ?? now,
            FirstSeen = existing?.FirstSeen ?? now,
            LastSeen = now
        };

        await _store.UpsertDeviceAsync(device);
        return device;
    }

    public async Task<List<UserDevice>> GetUserDevicesAsync(Guid userId)
    {
        return await _store.GetDevicesAsync(userId);
    }

    private async Task UpdateDeviceSyncAsync(Guid userId, string deviceId, long version)
    {
        var device = await _store.GetDeviceAsync(userId, deviceId);
        if (device != null)
        {
            device.LastSyncVersion = version;
            device.LastSyncTime = DateTime.UtcNow;
            device.LastSeen = DateTime.UtcNow;
            await _store.UpsertDeviceAsync(device);
        }
    }

    // Storage management
    public async Task<StorageInfoResponse> GetStorageInfoAsync(Guid userId)
    {
        var limit = await _store.GetStorageLimitAsync(userId);

        if (limit == null)
        {
            // Create default storage limit
            limit = new UserStorageLimit
            {
                UserId = userId,
                LimitBytes = DefaultStorageLimit,
                UsedBytes = 0,
                UpdatedAt = DateTime.UtcNow
            };
            await _store.UpsertStorageLimitAsync(limit);
        }

        return new StorageInfoResponse
        {
            LimitBytes = limit.LimitBytes,
            UsedBytes = limit.UsedBytes
        };
    }

    private async Task UpdateStorageUsageAsync(Guid userId, long sizeDelta)
    {
        var limit = await _store.GetStorageLimitAsync(userId);

        if (limit == null)
        {
            limit = new UserStorageLimit
            {
                UserId = userId,
                LimitBytes = DefaultStorageLimit,
                UsedBytes = Math.Max(0, sizeDelta),
                UpdatedAt = DateTime.UtcNow
            };
        }
        else
        {
            limit.UsedBytes = Math.Max(0, limit.UsedBytes + sizeDelta);
            limit.UpdatedAt = DateTime.UtcNow;
        }

        await _store.UpsertStorageLimitAsync(limit);
    }

    public async Task SetStorageLimitAsync(Guid userId, long limitBytes)
    {
        var info = await GetStorageInfoAsync(userId);
        var limit = new UserStorageLimit
        {
            UserId = userId,
            LimitBytes = limitBytes,
            UsedBytes = info.UsedBytes,
            UpdatedAt = DateTime.UtcNow
        };
        await _store.UpsertStorageLimitAsync(limit);
    }
}
