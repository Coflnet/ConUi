using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Data;

/// <summary>
/// Cassandra access for the sync tables. Kept separate from <see cref="Services.SyncService"/> so
/// tests can substitute an in-memory implementation instead of talking to a real cluster. This does
/// not change the table layout the Flutter app depends on - it only moves the existing queries
/// behind an interface.
/// </summary>
public interface ISyncStore
{
    Task InsertSyncEntryAsync(SyncEntry entry);
    Task<List<SyncEntry>> GetSyncEntriesAsync(Guid userId);

    Task<UserObject?> GetUserObjectAsync(Guid userId, string blobType, string blobId);
    Task<List<UserObject>> GetUserObjectsAsync(Guid userId);
    Task UpsertUserObjectAsync(UserObject userObject);

    Task<UserDevice?> GetDeviceAsync(Guid userId, string deviceId);
    Task<List<UserDevice>> GetDevicesAsync(Guid userId);
    Task UpsertDeviceAsync(UserDevice device);

    Task<UserStorageLimit?> GetStorageLimitAsync(Guid userId);
    Task UpsertStorageLimitAsync(UserStorageLimit limit);
}
