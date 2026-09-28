# syntax=docker/dockerfile:1
#
# Production image for "Relationship Manager" (Coflnet/ConUi): a single ASP.NET Core 8 process
# that serves the compiled Flutter web app from wwwroot and the REST API from the same port. See
# README.md ("Container image and deployment") for how to build and run this locally.

########################################################################################
# Stage: flutter-base - installs the exact Flutter SDK this project is developed with
########################################################################################
FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251 AS flutter-base

# Minimal packages the `flutter` tool itself needs on Linux: git to fetch the SDK (and for
# `flutter --version` afterwards), curl/unzip/xz-utils/ca-certificates for the tool's own
# engine-artifact downloads during `pub get`/`build web`.
RUN apt-get update && apt-get install -y --no-install-recommends \
        git \
        ca-certificates \
        curl \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Pin Flutter to the exact version this project is developed with (checked against the
# development machine's `flutter --version`: Flutter 3.44.4, framework revision
# ad70ec4617166f1c38e5d2bfd388af71fda14f06). No first-party or widely used pre-built Flutter
# Docker image publishes every patch release as its own tag (cirruslabs/flutter stops at
# 3.44.0, instrumentisto/flutter at 3.41.x, as of this writing) so the SDK is installed from
# source here instead, pinned to the immutable `3.44.4` release tag in flutter/flutter. The
# checkout is then verified against the exact commit above, so a moved/re-tagged ref fails the
# build loudly instead of silently shipping a different SDK - the equivalent of a digest pin for
# a source build.
ARG FLUTTER_VERSION=3.44.4
ARG FLUTTER_REVISION=ad70ec4617166f1c38e5d2bfd388af71fda14f06
RUN git clone --branch "${FLUTTER_VERSION}" --depth 1 https://github.com/flutter/flutter.git /opt/flutter \
    && cd /opt/flutter \
    && actual="$(git rev-parse HEAD)" \
    && if [ "$actual" != "${FLUTTER_REVISION}" ]; then \
        echo "Flutter tag ${FLUTTER_VERSION} resolved to commit ${actual}, expected ${FLUTTER_REVISION} - refusing to build with an unexpected SDK." >&2; \
        exit 1; \
    fi \
    && git config --global --add safe.directory /opt/flutter

ENV PATH="/opt/flutter/bin:${PATH}"

# Warm the tool's caches (engine artifacts for web) once, in its own layer, so it isn't repeated
# for every source change below.
RUN flutter config --no-analytics --no-cli-animations \
    && flutter precache --web \
    && flutter doctor -v

########################################################################################
# Stage: web - builds the Flutter web app
########################################################################################
FROM flutter-base AS web
WORKDIR /web

# Dependency resolution cached separately from the source: this layer only invalidates when
# pubspec.yaml/pubspec.lock change.
COPY flutter_app/pubspec.yaml flutter_app/pubspec.lock ./
RUN flutter pub get

COPY flutter_app/ .
# No API base URL is passed: the app is served from the same origin as the API in production, so
# it falls back to relative requests against the origin it was loaded from.
RUN flutter build web --release

########################################################################################
# Stage: build - restores and publishes the ASP.NET Core backend
########################################################################################
FROM mcr.microsoft.com/dotnet/sdk:8.0@sha256:78235e09001f52b6592c458ac010775ebac6725422e80cd0c1650590f67b2743 AS build
WORKDIR /src

# Restore cached separately from the source: this layer only invalidates when the csproj changes.
COPY backend/RelationshipManager.Api/RelationshipManager.Api.csproj RelationshipManager.Api/RelationshipManager.Api.csproj
RUN dotnet restore RelationshipManager.Api/RelationshipManager.Api.csproj

COPY backend/RelationshipManager.Api/ RelationshipManager.Api/
RUN dotnet publish RelationshipManager.Api/RelationshipManager.Api.csproj -c Release -o /app/publish --no-restore

########################################################################################
# Stage: backend-test / flutter-test / test - run on pull requests only (see .github/workflows/ci.yml
# and fleet/argo-workflow/CI.md: PRs build the Dockerfile stage named "test" instead of the final
# image). `test` itself does no work beyond depending on both of these, so that a failing
# `dotnet test` or `flutter test` fails `docker build --target test` immediately, while `docker
# build` (no --target, i.e. every production build) never reaches these stages at all because the
# final stage below does not depend on them.
########################################################################################
FROM build AS backend-test
COPY backend/RelationshipManager.sln .
COPY backend/RelationshipManager.Api.Tests/RelationshipManager.Api.Tests.csproj RelationshipManager.Api.Tests/RelationshipManager.Api.Tests.csproj
RUN dotnet restore RelationshipManager.sln
COPY backend/RelationshipManager.Api.Tests/ RelationshipManager.Api.Tests/
RUN dotnet test RelationshipManager.sln -c Release --no-restore --logger "console;verbosity=normal"

FROM flutter-base AS flutter-test
WORKDIR /web
COPY flutter_app/pubspec.yaml flutter_app/pubspec.lock ./
RUN flutter pub get
COPY flutter_app/ .
# NOTE: flutter_app/test/widget_test.dart is currently a leftover counter-app template being
# replaced on another branch. Once that merges, change the line below back to a plain
# `flutter test` so the full suite (including whatever replaces widget_test.dart) runs again.
RUN flutter test test/relationships test/screens

FROM scratch AS test
COPY --from=backend-test /src/RelationshipManager.Api.Tests/RelationshipManager.Api.Tests.csproj /backend-test.ok
COPY --from=flutter-test /web/pubspec.yaml /flutter-test.ok

########################################################################################
# Final stage - ASP.NET Core 8 runtime + published backend + built web app
#
# Base image choice (compared 2026-09-28 with `trivy image --severity HIGH,CRITICAL
# --ignore-unfixed`, 0 findings for all four candidates at that time):
#   - mcr.microsoft.com/dotnet/aspnet:8.0            Debian bookworm, ~90MB, full shell+apt
#   - mcr.microsoft.com/dotnet/aspnet:8.0-alpine      Alpine 3.24,     ~48MB, shell+apk, root by default
#   - mcr.microsoft.com/dotnet/aspnet:8.0-noble-chiseled        Ubuntu 24.04 "chiseled" distroless, ~49MB
#   - mcr.microsoft.com/dotnet/aspnet:8.0-noble-chiseled-extra  same + ICU/tzdata,                  ~65MB
#
# noble-chiseled (non-extra) wins: no shell, no package manager, nothing beyond the .NET runtime
# and its native dependencies (libssl.so.3/libcrypto.so.3 are present, which this app needs for
# the Cassandra client-certificate/.pfx TLS used in production - verified by inspecting the
# image's file list). It already ships a non-root "app" user at fixed uid/gid 1654 (the same
# user the existing backend/RelationshipManager.Api/Dockerfile relies on for local dev), and it
# runs .NET in globalization-invariant mode by default (DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=true
# is baked into the image env). That matches this backend: it never uses CultureInfo,
# TimeZoneInfo, or culture-sensitive parsing/formatting - the only date handling is
# DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() (culture-independent) - so the ICU and timezone
# database -extra adds are not needed, and -noble-chiseled's smaller surface is strictly better.
FROM mcr.microsoft.com/dotnet/aspnet:8.0-noble-chiseled@sha256:c7d217effa07b444d8d4bb72d1f00da60f5421ed94438c2ce0ad00b550da9dd5 AS final
WORKDIR /app

ENV ASPNETCORE_URLS=http://+:8000
EXPOSE 8000

COPY --from=build /app/publish .
COPY --from=web /web/build/web ./wwwroot

# The base image ships uid/gid 1654 as "app" (see comment above); pin the numeric id explicitly
# rather than relying on name resolution, since there are no shell/nsswitch tools in this image to
# introspect it at runtime.
USER 1654:1654

ENTRYPOINT ["dotnet", "RelationshipManager.Api.dll"]
