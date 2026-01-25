using RelationshipManager.Api.Services;
using RelationshipManager.Api.Auth;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.IdentityModel.Tokens;
using System.Text;
using Microsoft.IdentityModel.JsonWebTokens;
using Cassandra;
using CassandraSession = Cassandra.ISession;

var builder = WebApplication.CreateBuilder(args);

// Add services to the container
builder.Services.AddControllers();
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

// Cassandra/ScyllaDB
builder.Services.AddSingleton<Cassandra.ISession>(sp =>
{
    var config = sp.GetRequiredService<IConfiguration>();
    var hosts = config["CASSANDRA:HOSTS"] ?? "localhost";
    var keyspace = config["CASSANDRA:KEYSPACE"] ?? "relationship_manager";
    var user = config["CASSANDRA:USER"] ?? "cassandra";
    var password = config["CASSANDRA:PASSWORD"] ?? "cassandra";

    var cluster = Cluster.Builder()
        .AddContactPoints(hosts.Split(","))
        .WithCredentials(user, password)
        .WithDefaultKeyspace(keyspace)
        .Build();

    var session = cluster.Connect();
    
    // Create keyspace if not exists
    session.Execute($@"
        CREATE KEYSPACE IF NOT EXISTS {keyspace} 
        WITH replication = {{'class': 'SimpleStrategy', 'replication_factor': 1}}
    ");
    session.ChangeKeyspace(keyspace);
    
    return session;
});

// S3 Service
builder.Services.AddSingleton<IS3Service, S3Service>();

// Auth Service
var issuer = builder.Configuration["jwt:issuer"] ?? "relationship-manager";
var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(
    builder.Configuration["jwt:secret"] ?? "super-secret-key-for-development-only-32chars!"));

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

// CORS for Flutter web
builder.Services.AddCors(options =>
{
    options.AddDefaultPolicy(policy =>
    {
        policy.AllowAnyOrigin()
              .AllowAnyMethod()
              .AllowAnyHeader();
    });
});

var app = builder.Build();

// Initialize database tables
using (var scope = app.Services.CreateScope())
{
    var session = scope.ServiceProvider.GetRequiredService<Cassandra.ISession>();
    var syncService = scope.ServiceProvider.GetRequiredService<SyncService>();
    syncService.InitializeTables();
}

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseCors();
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

// Health check endpoint
app.MapGet("/health", () => Results.Ok(new { status = "healthy", timestamp = DateTime.UtcNow }));

app.Run();
