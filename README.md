# IoT Telemetry Service

A lightweight C++ HTTP service that ingests IoT device telemetry and persists it to PostgreSQL. Built with [Crow](https://crowcpp.org/) (HTTP), [nlohmann/json](https://github.com/nlohmann/json) (validation/parsing), and [libpqxx](https://github.com/jtv/libpqxx) (PostgreSQL access).

This was built and verified end-to-end (compiled, linked, run against a live PostgreSQL instance, and exercised with valid/invalid/malformed/adversarial payloads) as part of putting this together.

## API

### `POST /api/v1/telemetry`

```json
{
  "device_id": "sensor-001",
  "timestamp": "2026-09-09T12:34:56Z",
  "temperature": 23.5,
  "location": { "lat": 40.7128, "lon": -74.0060 }
}
```

| Status | Meaning |
|---|---|
| `201` | Reading validated and persisted. Returns `{"status":"accepted","device_id":"..."}`. |
| `400` | Malformed JSON or a failed validation rule. Returns `{"error":"..."}` describing the first problem found. |
| `500` | Payload was valid but the database write failed. |

### `GET /healthz`

Returns `{"status":"ok"}` — for load balancer / container health checks.

## Project layout

```
.
├── CMakeLists.txt
├── src/main.cpp                 # HTTP routes, wiring, DB insert
├── include/Config.hpp           # env-var based configuration (fail-fast)
├── include/ConnectionPool.hpp   # thread-safe RAII pqxx connection pool
├── include/TelemetryPayload.hpp # JSON validation + parsing, no HTTP/DB deps
├── sql/schema.sql               # table + index for telemetry_readings
└── .env.example                 # documents required env vars (no real secrets)
```

Keeping validation, DB pooling, and config loading in separate headers (rather than one large `main.cpp`) means each piece can be unit-tested or swapped independently — e.g. the validation logic in `TelemetryPayload.hpp` has zero dependency on Crow or libpqxx.

## Running with Docker Compose

The fastest way to run this end-to-end — no local C++ toolchain or PostgreSQL install needed:

```bash
cp .env.example .env   # then edit DB_NAME / DB_USER / DB_PASSWORD to real values
docker compose up --build
```

This builds the multi-stage image (see `Dockerfile`) and starts both containers:

- `db` — official `postgres:16-alpine`, schema auto-applied from `sql/schema.sql` on first start, **no port published to the host** — reachable only from `telemetry-service` over the isolated `backend` network.
- `telemetry-service` — the compiled binary running as a non-root user, published on `http://localhost:8080`.

```bash
curl http://localhost:8080/healthz
curl -X POST http://localhost:8080/api/v1/telemetry \
  -H "Content-Type: application/json" \
  -d '{"device_id":"sensor-001","timestamp":"2026-09-09T12:34:56Z","temperature":23.5,"location":{"lat":40.7128,"lon":-74.0060}}'
```

Note: inside Docker, `DB_HOST`/`DB_PORT` are fixed to `db`/`5432` directly in `docker-compose.yml` (Docker's embedded DNS resolves the service name) — the values in `.env`/`.env.example` for those two are only used when running the binary natively outside a container.

## Building

**Prerequisites** (system packages, not fetched by CMake):
- A C++17 compiler (GCC 9+/Clang 10+)
- CMake 3.16+
- PostgreSQL client headers/library (`libpq`)
- Standalone Asio headers (Crow's transport dependency)

```bash
# Debian/Ubuntu
sudo apt-get install build-essential cmake libpq-dev libasio-dev

# Fedora/RHEL
sudo dnf install gcc-c++ cmake libpq-devel asio-devel

# macOS (Homebrew)
brew install cmake libpq asio
```

Crow, nlohmann/json, and libpqxx themselves are fetched and built automatically by CMake's `FetchContent`, pinned to specific tagged releases (not `master`) for reproducible builds:

- Crow `v1.3.4`
- nlohmann/json `v3.12.0`
- libpqxx `7.10.7` (the 7.x line, not 8.x — see note below)

> **Why libpqxx 7.x, not 8.x?** libpqxx 8.x requires C++20 and its headers use `std::format` (`<format>`), which needs GCC 13+. The Docker build (see `Dockerfile`) uses `debian:bookworm`, which ships GCC 12 — whose libstdc++ doesn't have `<format>` at all, so an 8.x build fails there with `fatal error: format: No such file or directory`. Staying on 7.x avoids that entirely without having to chase a newer compiler into the container; the API used here (`pqxx::params` + `exec(query, params)`) is available on 7.10.7 too.

```bash
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j"$(nproc)"
```

This produces `build/telemetry_service`.

## Database setup

```bash
createdb telemetry_db
psql telemetry_db -f sql/schema.sql
```

In production, create a dedicated least-privilege role for the service rather than using a superuser:

```sql
CREATE ROLE telemetry_app LOGIN PASSWORD '...';
GRANT INSERT, SELECT ON telemetry_readings TO telemetry_app;
GRANT USAGE, SELECT ON SEQUENCE telemetry_readings_id_seq TO telemetry_app;
```

## Configuration

All configuration is read from environment variables — nothing is hardcoded, and the service **fails fast at startup** (before opening a listening socket) if a required variable is missing, rather than silently falling back to a default credential. See `.env.example` for the full list.

```bash
export DB_HOST=127.0.0.1
export DB_NAME=telemetry_db
export DB_USER=telemetry_app
export DB_PASSWORD='...'
# DB_PORT, DB_SSLMODE, DB_POOL_SIZE, APP_PORT are optional (see .env.example)

./build/telemetry_service
```

## Security & reliability notes

- **No hardcoded credentials.** `Config.hpp` reads everything from the environment and throws (causing a non-zero exit before the socket opens) if a required variable is absent.
- **SQL injection is not possible via this endpoint.** `main.cpp` uses `pqxx::params` with `exec(query, params)` exclusively — every field from the request body is sent as a bound parameter, never concatenated into SQL. This was verified by sending a `device_id` containing `; DROP TABLE telemetry_readings;--` and confirming it was stored as inert string data.
- **Untrusted input never reaches the DB or throws past the request boundary.** `parseTelemetryPayload()` validates every field's presence, type, and range (including basic sanity bounds on temperature/lat/lon) before anything is used to build a query, and returns a normal `std::optional` rather than throwing.
- **Thread-safe DB access.** Crow serves requests from multiple worker threads; `pqxx::connection` is not thread-safe, so `ConnectionPool` hands each in-flight request its own connection via an RAII guard, which returns the connection to the pool automatically even if an exception is thrown mid-request.
- **Compiler hardening.** The build enables `-Wall -Wextra -Wpedantic`, `-fstack-protector-strong`, and `_FORTIFY_SOURCE=2` in Release builds.
- **Pinned dependencies.** All three fetched dependencies are pinned to specific release tags, not floating branches, so builds are reproducible and dependency updates are a deliberate, reviewable change.

## CI security pipeline

`.github/workflows/security-scan.yml` runs the same two gates as `scan.sh`, automatically, on every PR and every push to `main`: TruffleHog scans the actual commit diff for secrets, then the Docker image is built and scanned by Trivy, which fails the job on any HIGH/CRITICAL CVE. See the comments in that file for the specific reasoning behind each setting — including why the Trivy action is pinned to a commit SHA rather than a version tag (a real supply-chain incident affected nearly every tag of that action in March 2026).

## Security scanning before you push

`scan.sh` is a local pre-push gate: it checks that Trivy and TruffleHog are installed, scans the working directory for hardcoded secrets, builds the Docker image, and scans that image for HIGH/CRITICAL CVEs.

```bash
chmod +x scan.sh   # first time only
./scan.sh
```

Exit code `0` means it's safe to push. Any non-zero exit means something needs fixing first — read the `✗` line(s) it printed. See the comments in `scan.sh` for exactly what each gate checks and why.

## Suggested next steps

Not included here, but natural additions for this portfolio project:
- A GitHub Actions workflow running the build plus a static analyzer (`clang-tidy`, `cppcheck`) and a dependency/SBOM scan
- Unit tests for `parseTelemetryPayload()` (it has no framework dependencies, so it's easy to test in isolation)
- TLS termination in front of the service (e.g. a reverse proxy) and an auth layer on the ingest endpoint

Happy to build out any of these if useful.
< testing PR trigger -->
