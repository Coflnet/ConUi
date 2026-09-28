FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Copy project file and restore
COPY RelationshipManager.Api.csproj .
RUN dotnet restore

# Copy source and build
COPY . .
RUN dotnet publish -c Release -o /app/publish

# Runtime image
FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app

# Kubernetes readiness/liveness probes are what production actually uses (see /health and
# /health/ready); this image intentionally has no HEALTHCHECK, since the base image ships
# neither curl nor wget to run one with.
ENV ASPNETCORE_URLS=http://+:8000
EXPOSE 8000

COPY --from=build /app/publish .

# mcr.microsoft.com/dotnet/aspnet:8.0 ships a pre-created non-root "app" user (uid/gid 1654).
USER app

ENTRYPOINT ["dotnet", "RelationshipManager.Api.dll"]
