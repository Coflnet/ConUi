namespace RelationshipManager.Api.Models;

public sealed record TrainingPerson(string Name, string? Company, List<string> Facts);
public sealed record TrainingConnection(string Person1Name, string Person2Name, string Type);
public sealed record TrainingSampleInput(Guid SampleId, bool Consent, string Transcript, string? Correction,
    string? Language, List<TrainingPerson> People, List<TrainingConnection> Connections);
public sealed record TrainingSample(Guid Id, string Date, DateTimeOffset CreatedAt, string ConsentVersion,
    string Transcript, string? Correction, string? Language, List<TrainingPerson> People,
    List<TrainingConnection> Connections, int AudioSize, string? AudioSha256, string DataSha256);
public sealed record TrainingSamplePage(List<TrainingSample> Items, string? NextCursor);
