#!/bin/bash
# Minimal, dependency-free liveness check for the telemetry service.
#
# The runtime image deliberately has no curl/wget installed (fewer packages
# == smaller attack surface), so this uses bash's built-in /dev/tcp
# pseudo-device to open a raw connection, send a real HTTP request, and
# check for a 200 response -- no extra tooling required beyond bash+grep,
# both already present in the runtime image.
set -euo pipefail

PORT="${APP_PORT:-8080}"

exec 3<>"/dev/tcp/127.0.0.1/${PORT}"
printf 'GET /healthz HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
grep -q "200 OK" <&3
