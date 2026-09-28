using Microsoft.Extensions.Configuration;
using RelationshipManager.Api;

namespace RelationshipManager.Api.Tests;

/// <summary>
/// Regression coverage for: outside Development, the app used to happily start with a missing or
/// placeholder jwt:secret (anyone could forge tokens). RelationshipManagerApp.Build now refuses
/// to build the app in that case. These call Build() directly (never Start()), so nothing is
/// actually listening and no real Cassandra/S3 is touched - the validation happens before either
/// is ever used.
/// </summary>
public class JwtSecretValidationTests
{
    [Test]
    public void Build_Throws_WhenJwtSecretMissing_OutsideDevelopment()
    {
        Assert.Throws<InvalidOperationException>(() =>
            RelationshipManagerApp.Build(Array.Empty<string>(), _ => { }, environmentName: "Production"));
    }

    [Test]
    public void Build_Throws_WhenJwtSecretIsTheDevelopmentPlaceholder_OutsideDevelopment()
    {
        Assert.Throws<InvalidOperationException>(() =>
            RelationshipManagerApp.Build(Array.Empty<string>(), builder =>
            {
                builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["jwt:secret"] = RelationshipManagerApp.DevJwtSecretPlaceholder
                });
            }, environmentName: "Production"));
    }

    [Test]
    public void Build_Throws_WhenJwtSecretTooShort_OutsideDevelopment()
    {
        Assert.Throws<InvalidOperationException>(() =>
            RelationshipManagerApp.Build(Array.Empty<string>(), builder =>
            {
                builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
                {
                    ["jwt:secret"] = "too-short"
                });
            }, environmentName: "Production"));
    }

    [Test]
    public async Task Build_Succeeds_WhenJwtSecretIsValid_OutsideDevelopment()
    {
        await using var app = RelationshipManagerApp.Build(Array.Empty<string>(), builder =>
        {
            builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["jwt:secret"] = "a-real-production-secret-that-is-long-enough-1234",
                ["CASSANDRA:KEYSPACE"] = "unused_in_this_test"
            });
        }, environmentName: "Production");

        Assert.That(app, Is.Not.Null);
    }
}
