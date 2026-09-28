using System.Collections.Concurrent;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Tests.Fakes;

/// <summary>In-memory stand-in for <see cref="CassandraSyncStore"/> so tests never need Cassandra.</summary>
public class InMemorySyncStore : ISyncStore
{
    private readonly ConcurrentBag<SyncEntry> _syncEntries = new();
    private readonly ConcurrentDictionary<(Guid UserId, string BlobType, string BlobId), UserObject> _userObjects = new();
    private readonly ConcurrentDictionary<(Guid UserId, string DeviceId), UserDevice> _devices = new();
    private readonly ConcurrentDictionary<Guid, UserStorageLimit> _storageLimits = new();

    public Task InsertSyncEntryAsync(SyncEntry entry)
    {
        _syncEntries.Add(entry);
        return Task.CompletedTask;
    }

    public Task<List<SyncEntry>> GetSyncEntriesAsync(Guid userId)
        => Task.FromResult(_syncEntries.Where(e => e.UserId == userId).ToList());

    public Task<UserObject?> GetUserObjectAsync(Guid userId, string blobType, string blobId)
        => Task.FromResult(_userObjects.TryGetValue((userId, blobType, blobId), out var obj) ? obj : null);

    public Task<List<UserObject>> GetUserObjectsAsync(Guid userId)
        => Task.FromResult(_userObjects.Values.Where(o => o.UserId == userId).ToList());

    public Task UpsertUserObjectAsync(UserObject userObject)
    {
        _userObjects[(userObject.UserId, userObject.BlobType, userObject.BlobId)] = userObject;
        return Task.CompletedTask;
    }

    public Task<UserDevice?> GetDeviceAsync(Guid userId, string deviceId)
        => Task.FromResult(_devices.TryGetValue((userId, deviceId), out var device) ? device : null);

    public Task<List<UserDevice>> GetDevicesAsync(Guid userId)
        => Task.FromResult(_devices.Values.Where(d => d.UserId == userId).ToList());

    public Task UpsertDeviceAsync(UserDevice device)
    {
        _devices[(device.UserId, device.DeviceId)] = device;
        return Task.CompletedTask;
    }

    public Task<UserStorageLimit?> GetStorageLimitAsync(Guid userId)
        => Task.FromResult(_storageLimits.TryGetValue(userId, out var limit) ? limit : null);

    public Task UpsertStorageLimitAsync(UserStorageLimit limit)
    {
        _storageLimits[limit.UserId] = limit;
        return Task.CompletedTask;
    }
}
