using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace RelationshipManager.Api.Services;

public sealed class TrainingSampleQuota(IAnonymousQuotaStore store)
{
    public async Task<string?> ReserveAsync(string ip, string date, Guid id, string hash)
    {
        var key = "training:" + date + ":" + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(ip)));
        for (var attempt = 0; attempt < 20; attempt++)
        {
            var previous = await store.ReadAsync(key);
            var state = previous == null ? new Dictionary<Guid, string>() : JsonSerializer.Deserialize<Dictionary<Guid, string>>(previous)!;
            if (state.TryGetValue(id, out var existing)) return existing == hash ? null : "sample_conflict";
            if (state.Count >= 10) return "training_daily_limit";
            state.Add(id, hash);
            if (await store.CompareExchangeAsync(key, previous, JsonSerializer.Serialize(state))) return null;
        }
        throw new InvalidOperationException("The sample quota is temporarily busy.");
    }
}
