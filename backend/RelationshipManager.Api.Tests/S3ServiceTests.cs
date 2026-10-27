using System.Net;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.WebUtilities;
using Microsoft.AspNetCore.Hosting.Server;
using Microsoft.AspNetCore.Hosting.Server.Features;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using RelationshipManager.Api.Services;

namespace RelationshipManager.Api.Tests;

public class S3ServiceTests
{
    [TestCase(200)]
    [TestCase(403)]
    [TestCase(404)]
    public async Task Readiness_UsesOnlyThePreprovisionedBucket_AndRetriesFailure(int firstStatus)
    {
        var requests = new List<string>();
        var builder = WebApplication.CreateBuilder();
        builder.Logging.ClearProviders();
        builder.WebHost.ConfigureKestrel(options => options.Listen(IPAddress.Loopback, 0));
        await using var app = builder.Build();
        app.Run(async context =>
        {
            requests.Add($"{context.Request.Method} {context.Request.Path}{context.Request.QueryString}");
            context.Response.StatusCode = requests.Count == 1 ? firstStatus : 200;
            context.Response.ContentType = "application/xml";
            await context.Response.WriteAsync(context.Response.StatusCode == 200
                ? """<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>con-stories</Name><KeyCount>0</KeyCount><MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated></ListBucketResult>"""
                : $"<Error><Code>{(firstStatus == 403 ? "AccessDenied" : "NoSuchBucket")}</Code></Error>");
        });
        await app.StartAsync();
        var endpoint = app.Services.GetRequiredService<IServer>().Features.Get<IServerAddressesFeature>()!.Addresses.Single();
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["S3:ENDPOINT"] = endpoint,
            ["S3:ACCESS_KEY"] = "synthetic-key",
            ["S3:SECRET_KEY"] = "synthetic-secret",
            ["S3:BUCKET"] = "con-stories"
        }).Build();
        var service = new S3Service(config, NullLogger<S3Service>.Instance);
        Assert.That(requests, Is.Empty, "Construction must not access storage");
        if (firstStatus != 200)
            Assert.ThrowsAsync<S3UnavailableException>(() => service.GetUploadUrlAsync("synthetic", TimeSpan.FromMinutes(1)));
        var url = await service.GetUploadUrlAsync("synthetic", TimeSpan.FromMinutes(1));
        await service.GetDownloadUrlAsync("synthetic", TimeSpan.FromMinutes(1));
        Assert.That(new Uri(url).AbsolutePath, Is.EqualTo("/con-stories/synthetic"));
        Assert.That(requests, Has.Count.EqualTo(firstStatus == 200 ? 1 : 2));
        Assert.That(requests, Is.All.EqualTo("GET /con-stories/?list-type=2&max-keys=1"));
    }

    [TestCase("https://synthetic.eu.r2.cloudflarestorage.com", "auto")]
    [TestCase("http://localhost:9000", "us-east-1")]
    public async Task PresignedUrls_UseSigV4_AndPreserveObjectKeys(string endpoint, string region)
    {
        var http = new BucketHttpClientFactory();
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["S3:ENDPOINT"] = endpoint,
            ["S3:ACCESS_KEY"] = "synthetic-key",
            ["S3:SECRET_KEY"] = "synthetic-secret",
            ["S3:BUCKET"] = "con-stories"
        }).Build();
        var service = new S3Service(config, NullLogger<S3Service>.Instance, http);
        const string key = "user/person/a b+%/ü.json";
        var upload = new Uri(await service.GetUploadUrlAsync(key, TimeSpan.FromMinutes(5)));
        var download = new Uri(await service.GetDownloadUrlAsync(key, TimeSpan.FromMinutes(5)));
        foreach (var url in new[] { upload, download })
        {
            var query = QueryHelpers.ParseQuery(url.Query);
            Assert.Multiple(() =>
            {
                Assert.That(url.Host, Is.EqualTo(new Uri(endpoint).Host));
                Assert.That(url.Port, Is.EqualTo(new Uri(endpoint).Port));
                Assert.That(url.AbsolutePath, Is.EqualTo("/con-stories/user/person/a%20b%2B%25/%C3%BC.json"));
                Assert.That(query["X-Amz-Algorithm"].ToString(), Is.EqualTo("AWS4-HMAC-SHA256"));
                Assert.That(query["X-Amz-Credential"].ToString(), Does.StartWith("synthetic-key/").And.EndWith($"/{region}/s3/aws4_request"));
                Assert.That(query["X-Amz-Signature"].ToString(), Does.Match("^[0-9a-f]{64}$"));
                Assert.That(query["X-Amz-Expires"].ToString(), Is.EqualTo("300"));
                Assert.That(query.ContainsKey("AWSAccessKeyId"), Is.False);
                Assert.That(query.ContainsKey("Signature"), Is.False);
            });
        }
        var uploadQuery = QueryHelpers.ParseQuery(upload.Query);
        Assert.That(uploadQuery["X-Amz-SignedHeaders"].ToString(), Is.EqualTo("content-type;host"));
        AssertPresignedSignature(upload, "PUT", "application/octet-stream");
        AssertPresignedSignature(download, "GET", null);
        Assert.That(upload.Query, Is.Not.EqualTo(download.Query), "PUT content type/verb must be signed differently from GET");
        Assert.That(http.Requests, Is.EqualTo(1), "Only the bucket access check may use HTTP");
    }

    [TestCase("valid")]
    [TestCase("wrong-range")]
    [TestCase("ignored-range")]
    [TestCase("truncated")]
    [TestCase("oversized")]
    [TestCase("missing")]
    public async Task PackedRange_RequiresExactBoundedPartialResponse(string mode)
    {
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["S3:ENDPOINT"] = "http://localhost:9000", ["S3:ACCESS_KEY"] = "synthetic-key",
            ["S3:SECRET_KEY"] = "synthetic-secret", ["S3:BUCKET"] = "con-stories"
        }).Build();
        var factory = new RangeHttpClientFactory(mode);
        var service = new S3Service(config, NullLogger<S3Service>.Instance, factory);
        if (mode == "valid")
        {
            using var stream = await service.DownloadRangeAsync("owner/.packs/v1/pack", 2, 3);
            using var data = new MemoryStream();
            await stream!.CopyToAsync(data);
            Assert.That(data.ToArray(), Is.EqualTo(new byte[] { 2, 3, 4 }));
        }
        else if (mode == "missing")
            Assert.That(await service.DownloadRangeAsync("owner/.packs/v1/pack", 2, 3), Is.Null);
        else Assert.ThrowsAsync<S3UnavailableException>(() => service.DownloadRangeAsync("owner/.packs/v1/pack", 2, 3));
        Assert.That(factory.ObjectRequests, Is.EqualTo(1));
        Assert.ThrowsAsync<ArgumentOutOfRangeException>(() => service.DownloadRangeAsync("key", long.MaxValue, 3));
        Assert.That(factory.ObjectRequests, Is.EqualTo(1));
    }

    private sealed class RangeHttpClientFactory(string mode) : Amazon.Runtime.HttpClientFactory
    {
        public int ObjectRequests { get; private set; }
        public override HttpClient CreateHttpClient(Amazon.Runtime.IClientConfig clientConfig) => new(new RangeHandler(this, mode));
        public override bool UseSDKHttpClientCaching(Amazon.Runtime.IClientConfig clientConfig) => false;

        private sealed class RangeHandler(RangeHttpClientFactory owner, string mode) : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                if (request.RequestUri!.Query.Length > 0)
                    return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                    {
                        Content = new StringContent("""<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>con-stories</Name><KeyCount>0</KeyCount><MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated></ListBucketResult>""")
                    });
                owner.ObjectRequests++;
                Assert.That(request.RequestUri.AbsolutePath, Is.EqualTo("/con-stories/owner/.packs/v1/pack"));
                Assert.That(request.Headers.Range!.ToString(), Is.EqualTo("bytes=2-4"));
                if (mode == "missing") return Task.FromResult(new HttpResponseMessage(HttpStatusCode.NotFound)
                {
                    Content = new StringContent("<Error><Code>NoSuchKey</Code></Error>")
                });
                var content = new ByteArrayContent(mode == "truncated" ? new byte[] { 2, 3 } :
                    mode == "oversized" ? new byte[] { 2, 3, 4, 5 } : new byte[] { 2, 3, 4 });
                content.Headers.ContentLength = 3;
                content.Headers.ContentRange = new System.Net.Http.Headers.ContentRangeHeaderValue(mode == "wrong-range" ? 1 : 2, 4, 10);
                return Task.FromResult(new HttpResponseMessage(mode == "ignored-range" ? HttpStatusCode.OK : HttpStatusCode.PartialContent) { Content = content });
            }
        }
    }

    [Test]
    public async Task Upload_UsesPayloadSignatureWithoutStreamingChunkFrames()
    {
        var http = new UploadHttpClientFactory();
        var config = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["S3:ENDPOINT"] = "https://synthetic.eu.r2.cloudflarestorage.com", ["S3:ACCESS_KEY"] = "synthetic-key",
            ["S3:SECRET_KEY"] = "synthetic-secret", ["S3:BUCKET"] = "con-stories"
        }).Build();
        var service = new S3Service(config, NullLogger<S3Service>.Instance, http);
        var payload = Encoding.UTF8.GetBytes("con:v1:synthetic ciphertext, unchanged bytes");
        await service.UploadAsync("owner/.packs/v1/pack", new MemoryStream(payload));
        Assert.That(http.Uploads, Has.Count.EqualTo(1));
        var upload = http.Uploads.Single();
        Assert.That(upload.Hash, Is.EqualTo(Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant()));
        Assert.That(upload.Encoding, Is.Empty);
        Assert.That(upload.Body, Is.EqualTo(payload));
        Assert.That(upload.Checksum, Is.EqualTo("k6PZYg=="));

    }

    private sealed class UploadHttpClientFactory : Amazon.Runtime.HttpClientFactory
    {
        public List<(string Hash, string Encoding, string Checksum, byte[] Body)> Uploads { get; } = new();
        public override HttpClient CreateHttpClient(Amazon.Runtime.IClientConfig clientConfig) => new(new UploadHandler(this));
        public override bool UseSDKHttpClientCaching(Amazon.Runtime.IClientConfig clientConfig) => false;

        private sealed class UploadHandler(UploadHttpClientFactory owner) : HttpMessageHandler
        {
            protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                if (request.Method == HttpMethod.Get)
                    return new HttpResponseMessage(HttpStatusCode.OK)
                    {
                        Content = new StringContent("""<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>con-stories</Name><KeyCount>0</KeyCount><MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated></ListBucketResult>""")
                    };
                Assert.That(request.Method, Is.EqualTo(HttpMethod.Put));
                Assert.That(request.Headers.GetValues("Authorization").Single(), Does.StartWith("AWS4-HMAC-SHA256 "));
                var hash = request.Headers.GetValues("x-amz-content-sha256").Single();
                var encoding = string.Join(",", request.Content!.Headers.ContentEncoding);
                var checksum = request.Headers.TryGetValues("x-amz-checksum-crc32", out var values) ? values.Single() : "";
                owner.Uploads.Add((hash, encoding, checksum, await request.Content.ReadAsByteArrayAsync(cancellationToken)));
                return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("") };
            }
        }
    }

    private static void AssertPresignedSignature(Uri url, string verb, string? contentType)
    {
        var query = QueryHelpers.ParseQuery(url.Query);
        var credential = query["X-Amz-Credential"].ToString().Split('/');
        var signedHeaders = query["X-Amz-SignedHeaders"].ToString();
        var canonicalQuery = string.Join("&", query.Where(pair => pair.Key != "X-Amz-Signature")
            .OrderBy(pair => pair.Key, StringComparer.Ordinal)
            .Select(pair => $"{Uri.EscapeDataString(pair.Key)}={Uri.EscapeDataString(pair.Value.ToString())}"));
        var headers = (contentType == null ? "" : $"content-type:{contentType}\n") + $"host:{url.Authority}\n";
        var canonical = $"{verb}\n{url.AbsolutePath}\n{canonicalQuery}\n{headers}\n{signedHeaders}\nUNSIGNED-PAYLOAD";
        var scope = string.Join("/", credential.Skip(1));
        var toSign = $"AWS4-HMAC-SHA256\n{query["X-Amz-Date"]}\n{scope}\n{Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(canonical))).ToLowerInvariant()}";
        var signingKey = Encoding.UTF8.GetBytes("AWS4synthetic-secret");
        foreach (var component in credential.Skip(1))
            signingKey = HMACSHA256.HashData(signingKey, Encoding.UTF8.GetBytes(component));
        Assert.That(query["X-Amz-Signature"].ToString(),
            Is.EqualTo(Convert.ToHexString(HMACSHA256.HashData(signingKey, Encoding.UTF8.GetBytes(toSign))).ToLowerInvariant()),
            "The signature must bind the HTTP verb, exact object path, and upload MIME type");
    }

    private sealed class BucketHttpClientFactory : Amazon.Runtime.HttpClientFactory
    {
        public int Requests { get; private set; }
        public override HttpClient CreateHttpClient(Amazon.Runtime.IClientConfig clientConfig) =>
            new(new BucketHandler(this));
        public override bool UseSDKHttpClientCaching(Amazon.Runtime.IClientConfig clientConfig) => false;

        private sealed class BucketHandler(BucketHttpClientFactory owner) : HttpMessageHandler
        {
            protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
            {
                owner.Requests++;
                Assert.That(request.Method, Is.EqualTo(HttpMethod.Get));
                Assert.That(request.RequestUri!.PathAndQuery, Is.EqualTo("/con-stories/?list-type=2&max-keys=1"));
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent("""<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>con-stories</Name><KeyCount>0</KeyCount><MaxKeys>1</MaxKeys><IsTruncated>false</IsTruncated></ListBucketResult>""")
                });
            }
        }
    }

}
