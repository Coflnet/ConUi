using RelationshipManager.Api.Models;

namespace RelationshipManager.Api.Data;

public interface ITrainingSampleStore
{
    Task<TrainingSample?> GetAsync(string date, Guid id);
    // Returns the published sample, or an existing sample if another upload won publication.
    Task<TrainingSample> PublishAsync(TrainingSample sample, byte[]? audio);
    Task<TrainingSamplePage> ListAsync(string date, int limit, Guid? after);
    Task<byte[]?> AudioAsync(string date, Guid id);
    Task DeleteAsync(string date, Guid id);
}
