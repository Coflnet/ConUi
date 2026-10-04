using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using RelationshipManager.Api;
using RelationshipManager.Api.Auth;
using RelationshipManager.Api.Data;
using RelationshipManager.Api.Services;
using RelationshipManager.Api.Tests.Fakes;

namespace RelationshipManager.Api.Tests;

/// <summary>
/// Boots the real API pipeline (routing, auth, controllers, middleware) against in-memory fakes
/// for Cassandra, so tests never need a running database. S3 and transcription are left
/// unconfigured by default (blank base URL/endpoint), which the app already handles by reporting
/// itself unavailable rather than connecting anywhere.
///
/// This hosts the app on a real (loopback-only) Kestrel server instead of
/// Microsoft.AspNetCore.Mvc.Testing's WebApplicationFactory/TestServer: under this machine's
/// .NET 10 runtime (the target framework is net8.0, run here via RollForward=LatestMajor),
/// TestServer's in-memory ResponseBodyPipeWriter does not implement PipeWriter.UnflushedBytes,
/// which System.Text.Json's PipeWriter fast path requires - every JSON response (minimal API and
/// MVC alike) fails with "PipeWriter.UnflushedBytes" before a single byte is written, and
/// WebApplicationFactory hard-casts IServer to TestServer so a Kestrel-backed IHost can't be
/// substituted through it either. A real loopback Kestrel server does not have that problem.
///
/// Set <see cref="Environment"/> and/or add to <see cref="ConfigOverrides"/> before calling
/// <see cref="StartAsync"/> to exercise non-Development / non-default-config scenarios.
/// </summary>
public class TestWebApplicationFactory : IAsyncDisposable
{
    public InMemoryUserStore UserStore { get; } = new();
    public InMemorySyncStore SyncStore { get; } = new();
    public InMemoryTrainingSampleStore TrainingSampleStore { get; set; } = new();
    public FakeCassandraConnection CassandraConnection { get; } = new();
    public FakeFirebaseTokenVerifier FirebaseVerifier { get; } = new();
    public FakeTranscriptionService TranscriptionService { get; } = new();
    public InMemoryAnonymousQuotaStore AnonymousQuotaStore { get; set; } = new();
    public TimeProvider Clock { get; set; } = TimeProvider.System;

    public string Environment { get; set; } = "Development";
    public HttpMessageHandler? OidcHttpHandler { get; set; }

    /// <summary>Override the content root (where wwwroot is looked up from) to test the static-file/SPA-fallback behaviour.</summary>
    public string? ContentRootPath { get; set; }

    public Dictionary<string, string?> ConfigOverrides { get; } = new()
    {
        ["jwt:issuer"] = "relationship-manager-tests",
        ["jwt:secret"] = "test-only-secret-key-that-is-at-least-32-characters!",
        ["ENABLE_DEV_AUTH"] = "true",
        ["CASSANDRA:KEYSPACE"] = "unused_in_tests",
        ["S3:ENDPOINT"] = "",
        ["S3:ACCESS_KEY"] = "",
        ["S3:SECRET_KEY"] = "",
        ["S3:BUCKET"] = "",
        ["Transcription:BaseUrl"] = "",
        ["Cors:AllowedOrigins:0"] = "http://example-app.test",
    };

    private WebApplication? _app;

    public async Task<HttpClient> StartAsync()
    {
        _app = RelationshipManagerApp.Build(Array.Empty<string>(), builder =>
        {
            builder.WebHost.UseKestrel(o => o.Listen(IPAddress.Loopback, 0));
            builder.Configuration.AddInMemoryCollection(ConfigOverrides);
            if (OidcHttpHandler != null)
                builder.Services.AddHttpClient("oidc").ConfigurePrimaryHttpMessageHandler(() => OidcHttpHandler);

            // RelationshipManagerApp registers its Cassandra-backed defaults with TryAddSingleton,
            // so registering the fakes here first (before the real ones are added) makes them win.
            builder.Services.AddSingleton<IUserStore>(UserStore);
            builder.Services.AddSingleton<ISyncStore>(SyncStore);
            builder.Services.AddSingleton<ITrainingSampleStore>(TrainingSampleStore);
            builder.Services.AddSingleton<ICassandraConnection>(CassandraConnection);
            builder.Services.AddSingleton<IFirebaseTokenVerifier>(FirebaseVerifier);
            builder.Services.AddSingleton<ITranscriptionService>(TranscriptionService);
            builder.Services.AddSingleton<IAnonymousQuotaStore>(AnonymousQuotaStore);
            builder.Services.AddSingleton(Clock);
        }, environmentName: Environment, contentRootPath: ContentRootPath);

        await _app.StartAsync();
        var baseAddress = _app.Urls.First();
        return new HttpClient { BaseAddress = new Uri(baseAddress) };
    }

    public async ValueTask DisposeAsync()
    {
        if (_app != null)
        {
            await _app.StopAsync();
            await _app.DisposeAsync();
        }
    }
}
