# syntax=docker/dockerfile:1

# =============================================================================
# Stage 1/2: builder
# =============================================================================
# Full Debian image with the complete C++ toolchain: compiler, CMake, git
# (CMakeLists.txt fetches Crow, nlohmann/json, and libpqxx via FetchContent,
# which needs git), and the *development* headers for PostgreSQL and Asio
# that the build links against.
#
# Deliberately pinned to the same Debian release ("bookworm") as the runtime
# stage below, not e.g. an Ubuntu builder. Mixing distro/version families
# between build and runtime is a classic multi-stage trap: if the builder's
# glibc is newer than the runtime's, the binary fails at container start with
# "version `GLIBC_2.NN' not found", because glibc's dynamic symbol versioning
# is only forward-compatible (newer glibc can run old binaries, not the
# reverse). Same distro family + release == guaranteed matching glibc ABI.
FROM debian:bookworm AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        cmake \
        git \
        ca-certificates \
        libpq-dev \
        libasio-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Copy only what CMake needs to configure and compile. Keeping this narrower
# than a blanket `COPY . .` means editing README.md or docker-compose.yml
# doesn't bust the (expensive) dependency-fetch-and-compile layer cache.
COPY CMakeLists.txt ./
COPY src ./src
COPY include ./include

# Configure + build in Release mode. This is also where CMake's FetchContent
# reaches out to GitHub for pinned versions of Crow/nlohmann-json/libpqxx --
# the build needs outbound network access for this step. `strip` removes
# debug symbols from the final binary: smaller image, less information
# handed to anyone who gets a copy of it.
RUN cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
    && cmake --build build --parallel "$(nproc)" \
    && strip build/telemetry_service

# =============================================================================
# Stage 2/2: runtime
# =============================================================================
# Minimal Debian base with none of the compiler, CMake, git, or -dev headers
# from the builder stage. Only the shared libraries the compiled binary
# actually needs at runtime are installed -- confirmed by running `ldd` on
# the real compiled binary, not guessed: libpq5 (PostgreSQL client library,
# which itself pulls in TLS/SASL/GSSAPI libs via apt's own dependency
# resolution) and bash (for the dependency-free healthcheck script below;
# everything else the binary links against -- libc, libstdc++, libssl -- is
# already part of this base image or a transitive dependency of libpq5).
FROM debian:bookworm-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 \
        ca-certificates \
        bash \
    && rm -rf /var/lib/apt/lists/*

# Dedicated, unprivileged system account that exists only to own and run this
# one process: no login shell, no password, no home directory.
RUN groupadd --system telemetry \
    && useradd --system --no-create-home --shell /usr/sbin/nologin --gid telemetry telemetry

WORKDIR /app

# Copy ONLY the compiled binary out of the builder stage -- no compiler, no
# build cache, no source tree, no package manager metadata. Ownership is set
# directly to the non-root user so no separate `chown` layer is needed.
COPY --from=builder --chown=telemetry:telemetry /build/build/telemetry_service ./telemetry_service
COPY --chown=telemetry:telemetry healthcheck.sh ./healthcheck.sh
RUN chmod 550 ./telemetry_service ./healthcheck.sh

USER telemetry

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["./healthcheck.sh"]

ENTRYPOINT ["./telemetry_service"]
