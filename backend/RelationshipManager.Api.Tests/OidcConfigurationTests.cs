using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using RelationshipManager.Api.Auth;
using RelationshipManager.Api;

namespace RelationshipManager.Api.Tests;

[NonParallelizable]
public class OidcConfigurationTests
{
    private static Dictionary<string, string?> Settings(string issuer) => new()
    {
        ["jwt:issuer"] = "test-api",
        ["jwt:secret"] = "test-only-secret-that-is-at-least-32-characters",
        ["Oidc:Issuer"] = issuer,
        ["Oidc:ClientId"] = "con-app",
        ["Oidc:Audience"] = "con-api"
    };

    [TestCase("http://identity.example.test/realms/con")]
    [TestCase("http://localhost:8080/realms/con")]
    [TestCase("https://identity.example.test/realms/con?x=y")]
    [TestCase("https://identity.example.test/realms/con#fragment")]
    [TestCase("https://user@identity.example.test/realms/con")]
    [TestCase("https://identity.example.test/realms/con/")]
    [TestCase("not-a-url")]
    public void InvalidIssuer_RefusesStartup(string issuer)
    {
        Assert.Throws<InvalidOperationException>(() => RelationshipManagerApp.Build([], builder =>
            builder.Configuration.AddInMemoryCollection(Settings(issuer)), environmentName: "Production"));
    }

    [Test]
    public void IncompleteConfiguration_RefusesStartup()
    {
        var config = Settings("https://identity.example.test/realms/con");
        config.Remove("Oidc:Audience");
        Assert.Throws<InvalidOperationException>(() => RelationshipManagerApp.Build([], builder =>
            builder.Configuration.AddInMemoryCollection(config), environmentName: "Development"));
    }

    [TestCase("Development", true, true)]
    [TestCase("Development", false, false)]
    [TestCase("Production", true, false)]
    public async Task HttpLoopback_RequiresExplicitDevelopmentOptIn(string environment, bool allow, bool succeeds)
    {
        var config = Settings("http://localhost:8080/realms/con");
        config["Oidc:AllowInsecureLocalhost"] = allow.ToString();
        if (succeeds)
        {
            await using var app = RelationshipManagerApp.Build([], builder =>
                builder.Configuration.AddInMemoryCollection(config), environmentName: environment);
            Assert.That(app, Is.Not.Null);
        }
        else
            Assert.Throws<InvalidOperationException>(() => RelationshipManagerApp.Build([], builder =>
                builder.Configuration.AddInMemoryCollection(config), environmentName: environment));
    }

    [Test]
    public async Task RuntimeFile_IsLoadedBeforeJwtValidation()
    {
        var path = Path.GetTempFileName();
        try
        {
            await File.WriteAllTextAsync(path, """{"jwt":{"secret":"test-only-file-secret-at-least-32-characters"},"Oidc":{"Issuer":"https://identity.example.test/realms/con","ClientId":"con-app","Audience":"con-api"}}""");
            await using var app = RelationshipManagerApp.Build([], builder =>
                builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?> { ["CON_CONFIG_FILE"] = path }), environmentName: "Production");
            Assert.That(app.Configuration["jwt:secret"], Is.EqualTo("test-only-file-secret-at-least-32-characters"));
            Assert.That(app.Configuration["Oidc:ClientId"], Is.EqualTo("con-app"));
        }
        finally { File.Delete(path); }
    }

    [Test]
    public async Task EnvironmentFeatureGates_OverrideRuntimeFile_WithoutChangingOtherSettings()
    {
        var path = Path.GetTempFileName();
        var keys = new[] { "Oidc__Issuer", "Oidc__ClientId", "Oidc__Audience", "S3__ENDPOINT", "CASSANDRA__HOSTS" };
        var previous = keys.ToDictionary(key => key, Environment.GetEnvironmentVariable);
        try
        {
            await File.WriteAllTextAsync(path, """{"jwt":{"secret":"test-only-file-secret-at-least-32-characters"},"Oidc":{"Issuer":"https://identity.example.test/realms/con","ClientId":"con-app","Audience":"con-api"},"S3":{"ENDPOINT":"https://storage.example.test"},"CASSANDRA":{"HOSTS":"database.example.test"}}""");
            foreach (var key in keys) Environment.SetEnvironmentVariable(key, "");
            await using var app = RelationshipManagerApp.Build([], builder =>
                builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?> { ["CON_CONFIG_FILE"] = path }), environmentName: "Production");
            Assert.That(app.Services.GetRequiredService<OidcSettings>().Enabled, Is.False);
            Assert.That(app.Configuration["S3:ENDPOINT"], Is.Empty);
            Assert.That(app.Configuration["CASSANDRA:HOSTS"], Is.Empty);
            Assert.That(app.Configuration["jwt:secret"], Is.EqualTo("test-only-file-secret-at-least-32-characters"));
        }
        finally
        {
            foreach (var (key, value) in previous) Environment.SetEnvironmentVariable(key, value);
            File.Delete(path);
        }
    }

    [Test]
    public void SpecifiedMissingRuntimeFile_RefusesStartup()
    {
        Assert.Throws<FileNotFoundException>(() => RelationshipManagerApp.Build([], builder =>
            builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?>
            { ["CON_CONFIG_FILE"] = Path.Combine(Path.GetTempPath(), Guid.NewGuid() + ".json") }), environmentName: "Production"));
    }

    [Test]
    public void InvalidRuntimeFile_RefusesStartup()
    {
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, "not JSON");
            Assert.Throws<InvalidDataException>(() => RelationshipManagerApp.Build([], builder =>
                builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?> { ["CON_CONFIG_FILE"] = path }), environmentName: "Production"));
        }
        finally { File.Delete(path); }
    }
}
