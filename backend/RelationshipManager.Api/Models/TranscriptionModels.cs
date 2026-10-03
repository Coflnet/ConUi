namespace RelationshipManager.Api.Models;

public class TranscriptionResult
{
    public string Text { get; set; } = string.Empty;
}

public class TranscriptionStatus
{
    public bool Available { get; set; }
    public int? RemainingRecordings { get; set; }
    public int DailyLimit { get; set; } = 3;
    public int MaxDurationSeconds { get; set; } = 60;
}
