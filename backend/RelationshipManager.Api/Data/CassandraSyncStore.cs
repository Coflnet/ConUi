using Cassandra;
using Cassandra.Data.Linq;
using Cassandra.Mapping;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Data;

public class CassandraSyncStore : ISyncStore
{
    private readonly ICassandraConnection _connection;
    private readonly Lazy<Table<SyncEntry>> _syncTable;
    private readonly Lazy<Table<UserObject>> _userObjectsTable;
    private readonly Lazy<Table<UserDevice>> _userDevicesTable;
    private readonly Lazy<Table<UserStorageLimit>> _storageLimitsTable;

    public CassandraSyncStore(ICassandraConnection connection)
    {
        _connection = connection;

        // Every table is built lazily (and CreateIfNotExists only runs then), so constructing
        // this store never opens a Cassandra connection by itself.
        _syncTable = new Lazy<Table<SyncEntry>>(() =>
        {
            var mapping = new MappingConfiguration()
                .Define(new Map<SyncEntry>()
                    .TableName("sync_entries")
                    .PartitionKey(e => e.UserId)
                    .ClusteringKey(e => e.Version, SortOrder.Descending)
                    .ClusteringKey(e => e.BlobType)
                    .ClusteringKey(e => e.BlobId)
                );
            var table = new Table<SyncEntry>(_connection.Session, mapping);
            table.CreateIfNotExists();
            return table;
        });

        _userObjectsTable = new Lazy<Table<UserObject>>(() =>
        {
            var mapping = new MappingConfiguration()
                .Define(new Map<UserObject>()
                    .TableName("user_objects")
                    .PartitionKey(e => e.UserId)
                    .ClusteringKey(e => e.BlobType)
                    .ClusteringKey(e => e.BlobId)
                );
            var table = new Table<UserObject>(_connection.Session, mapping);
            table.CreateIfNotExists();
            return table;
        });

        _userDevicesTable = new Lazy<Table<UserDevice>>(() =>
        {
            var mapping = new MappingConfiguration()
                .Define(new Map<UserDevice>()
                    .TableName("user_devices")
                    .PartitionKey(e => e.UserId)
                    .ClusteringKey(e => e.DeviceId)
                );
            var table = new Table<UserDevice>(_connection.Session, mapping);
            table.CreateIfNotExists();
            return table;
        });

        _storageLimitsTable = new Lazy<Table<UserStorageLimit>>(() =>
        {
            var mapping = new MappingConfiguration()
                .Define(new Map<UserStorageLimit>()
                    .TableName("user_storage_limits")
                    .PartitionKey(e => e.UserId)
                );
            var table = new Table<UserStorageLimit>(_connection.Session, mapping);
            table.CreateIfNotExists();
            return table;
        });
    }

    public async Task InsertSyncEntryAsync(SyncEntry entry)
        => await _syncTable.Value.Insert(entry).ExecuteAsync();

    public async Task<List<SyncEntry>> GetSyncEntriesAsync(Guid userId)
    {
        var entries = await _syncTable.Value.Where(e => e.UserId == userId).ExecuteAsync();
        return entries.ToList();
    }

    public async Task<UserObject?> GetUserObjectAsync(Guid userId, string blobType, string blobId)
    {
        var objects = await _userObjectsTable.Value
            .Where(e => e.UserId == userId && e.BlobType == blobType && e.BlobId == blobId)
            .ExecuteAsync();
        return objects.FirstOrDefault();
    }

    public async Task<List<UserObject>> GetUserObjectsAsync(Guid userId)
    {
        var objects = await _userObjectsTable.Value.Where(e => e.UserId == userId).ExecuteAsync();
        return objects.ToList();
    }

    public async Task UpsertUserObjectAsync(UserObject userObject)
        => await _userObjectsTable.Value.Insert(userObject).ExecuteAsync();

    public async Task<UserDevice?> GetDeviceAsync(Guid userId, string deviceId)
    {
        var devices = await _userDevicesTable.Value
            .Where(d => d.UserId == userId && d.DeviceId == deviceId)
            .ExecuteAsync();
        return devices.FirstOrDefault();
    }

    public async Task<List<UserDevice>> GetDevicesAsync(Guid userId)
    {
        var devices = await _userDevicesTable.Value.Where(d => d.UserId == userId).ExecuteAsync();
        return devices.ToList();
    }

    public async Task UpsertDeviceAsync(UserDevice device)
        => await _userDevicesTable.Value.Insert(device).ExecuteAsync();

    public async Task<UserStorageLimit?> GetStorageLimitAsync(Guid userId)
    {
        var limits = await _storageLimitsTable.Value.Where(s => s.UserId == userId).ExecuteAsync();
        return limits.FirstOrDefault();
    }

    public async Task UpsertStorageLimitAsync(UserStorageLimit limit)
        => await _storageLimitsTable.Value.Insert(limit).ExecuteAsync();
}
