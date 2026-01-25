namespace RelationshipManager.Api.Models;

/// <summary>
/// Represents a sync entry stored in Cassandra
/// Partition key: UserId, Clustering key: Version DESC, BlobType, BlobId
/// This allows efficient queries for changes since a specific version
/// </summary>
public class SyncEntry
{
    public Guid UserId { get; set; }
    public string BlobType { get; set; } = string.Empty; // "index", "person", "event_month", "file", "place", "object"
    public string BlobId { get; set; } = string.Empty; // Unique identifier for the blob
    public string S3Key { get; set; } = string.Empty; // S3 object key
    public long Version { get; set; } // Timestamp-based version for conflict resolution (DESC ordering)
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
    public string Checksum { get; set; } = string.Empty; // SHA256 checksum for integrity
    public long Size { get; set; }
    public bool IsDeleted { get; set; }
}

/// <summary>
/// Tracks each user's objects and their current state
/// Partition key: UserId, Clustering key: BlobType, BlobId
/// </summary>
public class UserObject
{
    public Guid UserId { get; set; }
    public string BlobType { get; set; } = string.Empty;
    public string BlobId { get; set; } = string.Empty;
    public string S3Key { get; set; } = string.Empty;
    public long Version { get; set; }
    public long Size { get; set; }
    public bool IsDeleted { get; set; }
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
}

/// <summary>
/// Tracks user devices and their sync state
/// Partition key: UserId, Clustering key: DeviceId
/// </summary>
public class UserDevice
{
    public Guid UserId { get; set; }
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceName { get; set; } = string.Empty;
    public string Platform { get; set; } = string.Empty; // "web", "android", "ios", "windows", "macos", "linux"
    public long LastSyncVersion { get; set; }
    public DateTime LastSyncTime { get; set; }
    public DateTime FirstSeen { get; set; }
    public DateTime LastSeen { get; set; }
}

/// <summary>
/// Stores storage limits per user
/// Partition key: UserId
/// </summary>
public class UserStorageLimit
{
    public Guid UserId { get; set; }
    public long LimitBytes { get; set; } = 100 * 1024 * 1024; // Default 100MB
    public long UsedBytes { get; set; }
    public DateTime UpdatedAt { get; set; }
}

/// <summary>
/// Response with user storage info
/// </summary>
public class StorageInfoResponse
{
    public long LimitBytes { get; set; }
    public long UsedBytes { get; set; }
    public long AvailableBytes => LimitBytes - UsedBytes;
    public double UsedPercent => LimitBytes > 0 ? (double)UsedBytes / LimitBytes * 100 : 0;
}

/// <summary>
/// Request to register/update device info
/// </summary>
public class DeviceRegistrationRequest
{
    public string DeviceId { get; set; } = string.Empty;
    public string DeviceName { get; set; } = string.Empty;
    public string Platform { get; set; } = string.Empty;
}

/// <summary>
/// Request to get sync updates since a specific version
/// </summary>
public class SyncRequest
{
    public long LastSyncVersion { get; set; }
    public List<string>? BlobTypes { get; set; } // Optional filter by blob type
    public string? DeviceId { get; set; } // Optional device identifier
}

/// <summary>
/// Response with sync updates
/// </summary>
public class SyncResponse
{
    public List<SyncEntry> Entries { get; set; } = new();
    public long LatestVersion { get; set; }
    public StorageInfoResponse? StorageInfo { get; set; }
}

/// <summary>
/// Request to upload a blob
/// </summary>
public class BlobUploadRequest
{
    public string BlobType { get; set; } = string.Empty;
    public string BlobId { get; set; } = string.Empty;
    public string Checksum { get; set; } = string.Empty;
    public long ExpectedVersion { get; set; } // For optimistic concurrency
}

/// <summary>
/// Response for blob upload with pre-signed URL
/// </summary>
public class BlobUploadResponse
{
    public string UploadUrl { get; set; } = string.Empty;
    public string S3Key { get; set; } = string.Empty;
    public long Version { get; set; }
}

/// <summary>
/// Response for blob download
/// </summary>
public class BlobDownloadResponse
{
    public string DownloadUrl { get; set; } = string.Empty;
    public long Version { get; set; }
    public string Checksum { get; set; } = string.Empty;
}

/// <summary>
/// Batch commit request
/// </summary>
public class BatchCommitRequest
{
    public List<CommitEntry> Entries { get; set; } = new();
}

public class CommitEntry
{
    public string BlobType { get; set; } = string.Empty;
    public string BlobId { get; set; } = string.Empty;
    public string S3Key { get; set; } = string.Empty;
    public string Checksum { get; set; } = string.Empty;
    public long Size { get; set; }
    public bool IsDeleted { get; set; }
}
