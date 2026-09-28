using Cassandra.Data.Linq;
using Cassandra.Mapping;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Data;

public class CassandraUserStore : IUserStore
{
    private readonly ICassandraConnection _connection;
    private readonly Lazy<Table<User>> _table;

    public CassandraUserStore(ICassandraConnection connection)
    {
        _connection = connection;
        // The Table<T> (and the CreateIfNotExists it needs) is only built on first use, so
        // constructing this store never opens a Cassandra connection by itself.
        _table = new Lazy<Table<User>>(() =>
        {
            var mapping = new MappingConfiguration()
                .Define(new Map<User>()
                    .TableName("users")
                    .PartitionKey(u => u.AuthProviderId)
                    .Column(u => u.Id, cm => cm.WithSecondaryIndex())
                    .Column(u => u.Email, cm => cm.WithSecondaryIndex())
                );
            var table = new Table<User>(_connection.Session, mapping);
            table.CreateIfNotExists();
            return table;
        });
    }

    public async Task<User?> GetByAuthProviderIdAsync(string authProviderId)
    {
        var users = await _table.Value.Where(u => u.AuthProviderId == authProviderId).ExecuteAsync();
        return users.FirstOrDefault();
    }

    public async Task<User?> GetByIdAsync(Guid id)
    {
        var users = await _table.Value.Where(u => u.Id == id).ExecuteAsync();
        return users.FirstOrDefault();
    }

    public async Task UpsertAsync(User user)
    {
        await _table.Value.Insert(user).ExecuteAsync();
    }
}
