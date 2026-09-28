using System.Net;

namespace RelationshipManager.Api.Tests;

public class StaticFilesFallbackTests
{
    [Test]
    public async Task ApiPath_UnknownRoute_Returns404WithJsonBody()
    {
        // No wwwroot in this test project's own output, so this also covers "wwwroot missing" -
        // the API behaves as before: an unmatched /api/... path is still a 404 with a JSON body,
        // never index.html.
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/api/this-does-not-exist");
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That(response.Content.Headers.ContentType?.MediaType, Is.EqualTo("application/json"));
        Assert.That(body, Does.Contain("not_found"));
    }

    [Test]
    public async Task NoWwwroot_UnknownNonApiPath_Returns404_NotIndexHtml()
    {
        await using var factory = new TestWebApplicationFactory();
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/some/deep/client-route");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
    }

    private sealed class TempWwwroot : IDisposable
    {
        public string ContentRoot { get; }
        public string WwwrootPath { get; }

        public TempWwwroot()
        {
            ContentRoot = Directory.CreateTempSubdirectory("rm-api-wwwroot-test-").FullName;
            WwwrootPath = Path.Combine(ContentRoot, "wwwroot");
            Directory.CreateDirectory(WwwrootPath);
        }

        public void WriteFile(string relativePath, string content)
        {
            var fullPath = Path.Combine(WwwrootPath, relativePath);
            Directory.CreateDirectory(Path.GetDirectoryName(fullPath)!);
            File.WriteAllText(fullPath, content);
        }

        public void Dispose()
        {
            try
            {
                Directory.Delete(ContentRoot, recursive: true);
            }
            catch
            {
                // best effort - temp dir, not load-bearing if this fails
            }
        }
    }

    [Test]
    public async Task WithWwwroot_UnknownNonApiPath_ServesIndexHtml_WithNoCache()
    {
        using var www = new TempWwwroot();
        www.WriteFile("index.html", "<html><body>flutter app shell</body></html>");

        await using var factory = new TestWebApplicationFactory { ContentRootPath = www.ContentRoot };
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/persons/123");
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(body, Does.Contain("flutter app shell"));
        Assert.That(response.Headers.CacheControl?.NoCache, Is.True);
    }

    [Test]
    public async Task WithWwwroot_ApiPath_StillReturns404Json_NotIndexHtml()
    {
        using var www = new TempWwwroot();
        www.WriteFile("index.html", "<html><body>flutter app shell</body></html>");

        await using var factory = new TestWebApplicationFactory { ContentRootPath = www.ContentRoot };
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/api/still-not-found");
        var body = await response.Content.ReadAsStringAsync();

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.NotFound));
        Assert.That(body, Does.Contain("not_found"));
        Assert.That(body, Does.Not.Contain("flutter app shell"));
    }

    [Test]
    public async Task WithWwwroot_WasmFile_ServedWithCorrectContentType()
    {
        using var www = new TempWwwroot();
        www.WriteFile("index.html", "<html></html>");
        www.WriteFile("main.dart.wasm", "not-really-wasm-but-good-enough-for-a-content-type-check");

        await using var factory = new TestWebApplicationFactory { ContentRootPath = www.ContentRoot };
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/main.dart.wasm");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(response.Content.Headers.ContentType?.MediaType, Is.EqualTo("application/wasm"));
    }

    [Test]
    public async Task WithWwwroot_HashedFileName_GetsLongTermCaching()
    {
        using var www = new TempWwwroot();
        www.WriteFile("index.html", "<html></html>");
        www.WriteFile("main.a1b2c3d4e5f6.js", "console.log('hi');");

        await using var factory = new TestWebApplicationFactory { ContentRootPath = www.ContentRoot };
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/main.a1b2c3d4e5f6.js");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(response.Headers.CacheControl?.MaxAge, Is.EqualTo(TimeSpan.FromSeconds(31536000)));
    }

    [Test]
    public async Task WithWwwroot_NonHashedRegularFile_DoesNotGetLongTermCaching()
    {
        using var www = new TempWwwroot();
        www.WriteFile("index.html", "<html></html>");
        www.WriteFile("robots.txt", "User-agent: *\nDisallow:");

        await using var factory = new TestWebApplicationFactory { ContentRootPath = www.ContentRoot };
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/robots.txt");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(response.Headers.CacheControl?.MaxAge, Is.Not.EqualTo(TimeSpan.FromSeconds(31536000)));
    }

    [Test]
    public async Task WithWwwroot_FlutterServiceWorker_GetsNoCache()
    {
        using var www = new TempWwwroot();
        www.WriteFile("index.html", "<html></html>");
        www.WriteFile("flutter_service_worker.js", "// sw");

        await using var factory = new TestWebApplicationFactory { ContentRootPath = www.ContentRoot };
        using var client = await factory.StartAsync();

        var response = await client.GetAsync("/flutter_service_worker.js");

        Assert.That(response.StatusCode, Is.EqualTo(HttpStatusCode.OK));
        Assert.That(response.Headers.CacheControl?.NoCache, Is.True);
    }
}
