using System.Net;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
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
}
