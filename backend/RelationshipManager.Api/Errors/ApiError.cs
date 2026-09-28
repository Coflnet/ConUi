namespace RelationshipManager.Api.Errors;

/// <summary>
/// Uniform error body for the new/touched endpoints: <c>{ "slug": "...", "message": "..." }</c>.
/// <paramref name="Slug"/> is a stable machine-readable identifier the client can switch on;
/// <paramref name="Message"/> is a human-readable description and may change wording over time.
/// </summary>
public record ApiError(string Slug, string Message);
