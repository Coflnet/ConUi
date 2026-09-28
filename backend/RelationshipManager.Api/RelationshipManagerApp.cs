using RelationshipManager.Api.Services;
using RelationshipManager.Api.Auth;
using RelationshipManager.Api.Data;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.IdentityModel.Tokens;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;

namespace RelationshipManager.Api;

/// <summary>
/// Builds the application. This is called from Program.cs's top-level statements, and also
/// directly by the test project, which hosts the same app on a real (loopback) Kestrel server
/// instead of WebApplicationFactory's in-memory TestServer - see
/// RelationshipManager.Api.Tests/TestWebApplicationFactory.cs for why.
/// </summary>
public static class RelationshipManagerApp
{
    /// <summary>Placeholder JWT secret shipped in appsettings.json for local development only.</summary>
    public const string DevJwtSecretPlaceholder = "super-secret-key-for-development-only-32chars!";

    /// <param name="args">Command-line args, forwarded to <see cref="WebApplication.CreateBuilder(WebApplicationOptions)"/>.</param>
    /// <param name="configureBuilder">Hook to override configuration/services before the app is built (used by tests).</param>
    /// <param name="environmentName">
    /// Overrides the ASPNETCORE_ENVIRONMENT value. Must be set here rather than via
    /// <c>configureBuilder</c>: once <see cref="WebApplication.CreateBuilder(WebApplicationOptions)"/> has run,
    /// the unified WebApplicationBuilder no longer allows changing the environment.
    /// </param>
    public static WebApplication Build(string[] args, Action<WebApplicationBuilder>? configureBuilder = null, string? environmentName = null)
    {
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions
        {
            Args = args,
            EnvironmentName = environmentName
        });
        configureBuilder?.Invoke(builder);

        // Add services to the container. AddApplicationPart is explicit (rather than relying on
        // MVC's default entry-assembly discovery) because that discovery keys off
        // Assembly.GetEntryAssembly(), which under `dotnet test` is the VSTest host, not this
        // assembly - without it, controllers silently fail to register when tests build the app
        // directly via RelationshipManagerApp.Build instead of running Program.Main.
        builder.Services.AddControllers()
            .AddApplicationPart(typeof(RelationshipManagerApp).Assembly);
        builder.Services.AddEndpointsApiExplorer();
        builder.Services.AddSwaggerGen(c =>
        {
            c.SwaggerDoc("v1", new Microsoft.OpenApi.Models.OpenApiInfo
            {
                Title = "RelationshipManager API",
                Version = "v1"
            });
            c.AddSecurityDefinition("Bearer", new Microsoft.OpenApi.Models.OpenApiSecurityScheme
            {
                Description = "JWT Authorization header using the Bearer scheme",
                In = Microsoft.OpenApi.Models.ParameterLocation.Header,
                Name = "Authorization",
                Type = Microsoft.OpenApi.Models.SecuritySchemeType.ApiKey,
                Scheme = "Bearer"
            });
            c.AddSecurityRequirement(new Microsoft.OpenApi.Models.OpenApiSecurityRequirement
            {
                {
                    new Microsoft.OpenApi.Models.OpenApiSecurityScheme
                    {
                        Reference = new Microsoft.OpenApi.Models.OpenApiReference
                        {
                            Type = Microsoft.OpenApi.Models.ReferenceType.SecurityScheme,
                            Id = "Bearer"
                        }
                    },
                    Array.Empty<string>()
                }
            });
        });

        // Cassandra/ScyllaDB - the session is only opened the first time something actually queries it.
        // TryAdd (not Add) so that configureBuilder can pre-register fakes for these interfaces
        // (as the test project does) without a real implementation being layered on top of them.
        builder.Services.TryAddSingleton<ICassandraConnection, CassandraConnection>();
        builder.Services.TryAddSingleton<IUserStore, CassandraUserStore>();
        builder.Services.TryAddSingleton<ISyncStore, CassandraSyncStore>();

        // S3 Service - lazy, optional. See Services/S3Service.cs.
        builder.Services.TryAddSingleton<IS3Service, S3Service>();

        // JWT secret: refuse to start outside Development with a missing, too-short, or placeholder secret.
        var jwtSecret = builder.Configuration["jwt:secret"];
        if (!builder.Environment.IsDevelopment())
        {
            if (string.IsNullOrEmpty(jwtSecret) || jwtSecret.Length < 32 || jwtSecret == DevJwtSecretPlaceholder)
            {
                Console.Error.WriteLine(
                    "Configuration error: 'jwt:secret' is missing, shorter than 32 characters, or still set to " +
                    "the development placeholder. Set a unique secret via the jwt:secret configuration key " +
                    "(Jwt__Secret environment variable) before starting outside Development.");
                throw new InvalidOperationException("jwt:secret is not configured securely for this environment.");
            }
        }
        else if (string.IsNullOrEmpty(jwtSecret))
        {
            jwtSecret = DevJwtSecretPlaceholder;
        }

        var issuer = builder.Configuration["jwt:issuer"] ?? "relationship-manager";
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(jwtSecret));

        JsonWebTokenHandler.DefaultInboundClaimTypeMap.Clear();
        builder.Services
            .AddAuthorization()
            .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(options =>
            {
                options.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidateAudience = true,
                    ValidateIssuerSigningKey = true,
                    ValidIssuer = issuer,
                    ValidAudience = issuer,
                    IssuerSigningKey = key
                };
            });

        builder.Services.AddSingleton<AuthService>();
        builder.Services.AddSingleton<SyncService>();

        // CORS: origins come from Cors:AllowedOrigins. Empty means no cross-origin access. In
        // Development, localhost on any port is also allowed so `flutter run -d chrome` works.
        var allowedOrigins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? Array.Empty<string>();
        var isDevelopment = builder.Environment.IsDevelopment();
        builder.Services.AddCors(options =>
        {
            options.AddDefaultPolicy(policy =>
            {
                policy.AllowAnyMethod().AllowAnyHeader();
                if (isDevelopment)
                {
                    policy.SetIsOriginAllowed(origin => IsLocalhostOrigin(origin) || allowedOrigins.Contains(origin));
                }
                else if (allowedOrigins.Length > 0)
                {
                    policy.WithOrigins(allowedOrigins);
                }
                // else: no origins configured -> no cross-origin access allowed.
            });
        });

        var app = builder.Build();

        if (app.Environment.IsDevelopment())
        {
            app.UseSwagger();
            app.UseSwaggerUI();
        }

        app.UseCors();
        app.UseAuthentication();
        app.UseAuthorization();
        app.MapControllers();

        return app;
    }

    private static bool IsLocalhostOrigin(string origin)
    {
        if (!Uri.TryCreate(origin, UriKind.Absolute, out var uri))
        {
            return false;
        }
        return uri.Host is "localhost" or "127.0.0.1" or "::1";
    }
}
