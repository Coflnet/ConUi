namespace RelationshipManager.Api.Models;

public class TranscriptionResult : TranscriptionStatus
{
    public string Text { get; set; } = string.Empty;
}

public class TranscriptionStatus
{
    public bool Available { get; set; }
    public double UsedSeconds { get; set; }
    public double RemainingSeconds { get; set; }
    public int DailyLimitSeconds { get; set; }
    public int? WarningAfterSeconds { get; set; }
    public DateTimeOffset ResetAt { get; set; }
}
