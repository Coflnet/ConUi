using RelationshipManager.Api.Data;
using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Tests.Fakes;

public sealed class InMemoryTrainingSampleStore : ITrainingSampleStore
{
    private readonly Dictionary<(string, Guid), (TrainingSample Sample, byte[]? Audio)> _samples = new();
    public bool Unavailable { get; set; }
    private void Check() { if (Unavailable) throw new InvalidOperationException("Sample storage unavailable (fake)."); }
    public Task<TrainingSample?> GetAsync(string date, Guid id)
    {
        Check();
        lock (_samples) return Task.FromResult(_samples.TryGetValue((date, id), out var value) ? value.Sample : null);
    }
    public Task<TrainingSample> PublishAsync(TrainingSample sample, byte[]? audio)
    {
        Check();
        lock (_samples)
        {
            if (_samples.TryGetValue((sample.Date, sample.Id), out var previous)) return Task.FromResult(previous.Sample);
            _samples.Add((sample.Date, sample.Id), (sample, audio));
            return Task.FromResult(sample);
        }
    }
    public Task<TrainingSamplePage> ListAsync(string date, int limit, Guid? after)
    {
        Check();
        lock (_samples)
        {
            var samples = _samples.Values.Select(v => v.Sample).Where(s => s.Date == date && (after == null || s.Id.CompareTo(after.Value) > 0))
                .OrderBy(s => s.Id).Take(limit + 1).ToList();
            var more = samples.Count > limit;
            if (more) samples.RemoveAt(limit);
            return Task.FromResult(new TrainingSamplePage(samples, more ? Convert.ToBase64String(samples[^1].Id.ToByteArray()) : null));
        }
    }
    public Task<byte[]?> AudioAsync(string date, Guid id)
    {
        Check();
        lock (_samples) return Task.FromResult(_samples.TryGetValue((date, id), out var value) ? value.Audio : null);
    }
    public Task DeleteAsync(string date, Guid id)
    {
        Check();
        lock (_samples) _samples.Remove((date, id));
        return Task.CompletedTask;
    }
}
