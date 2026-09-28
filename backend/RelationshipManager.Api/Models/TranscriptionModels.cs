namespace RelationshipManager.Api.Models;

public class TranscriptionResult
{
    public string Text { get; set; } = string.Empty;
}

public class TranscriptionStatus
{
    public bool Available { get; set; }
}
