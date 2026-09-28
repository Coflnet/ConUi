namespace RelationshipManager.Api.Tests.Fakes;

/// <summary>Captures the last outgoing request and answers it with a canned response/exception.</summary>
public class RecordingHttpMessageHandler : HttpMessageHandler
{
    private readonly Func<HttpRequestMessage, Task<HttpResponseMessage>> _respond;

    public HttpRequestMessage? LastRequest { get; private set; }

    /// <summary>
    /// Snapshotted eagerly in SendAsync: MultipartContent.Dispose() clears its nested content
    /// list, so reading field names from LastRequest.Content after the caller's `using` block
    /// has run (i.e. after TranscribeAsync returns) would just find an empty multipart body.
    /// </summary>
    public List<string>? LastMultipartFieldNames { get; private set; }

    public RecordingHttpMessageHandler(Func<HttpRequestMessage, HttpResponseMessage> respond)
    {
        _respond = req => Task.FromResult(respond(req));
    }

    public RecordingHttpMessageHandler(Func<HttpRequestMessage, Task<HttpResponseMessage>> respond)
    {
        _respond = respond;
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        LastRequest = request;
        if (request.Content is MultipartFormDataContent multipart)
        {
            LastMultipartFieldNames = multipart.Select(c => c.Headers.ContentDisposition?.Name?.Trim('"') ?? "").ToList();
        }
        return await _respond(request);
    }
}

/// <summary>Hands out an <see cref="HttpClient"/> wired to a single shared handler, for any client name.</summary>
public class FakeHttpClientFactory : IHttpClientFactory
{
    private readonly HttpMessageHandler _handler;

    public FakeHttpClientFactory(HttpMessageHandler handler)
    {
        _handler = handler;
    }

    public HttpClient CreateClient(string name) => new(_handler, disposeHandler: false);
}
