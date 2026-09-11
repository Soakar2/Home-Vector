#!/usr/bin/env bash
#
# scan.sh — Local pre-push security gate.
#
# Runs two independent checks before you push to GitHub:
#   1. TruffleHog — scans the working directory for hardcoded secrets
#      (API keys, tokens, private keys, database credentials, etc.)
#   2. Trivy      — builds the Docker image and scans it for known CVEs,
#      failing the gate only on HIGH/CRITICAL severity findings.
#
# Exit code 0 means every gate passed and it's safe to push. Any non-zero
# exit code means STOP -- read the ✗ line(s) above and fix the reported
# issue before pushing.
#
# Usage:
#   ./scan.sh [image_name] [image_tag]
# Defaults: image_name=iot-telemetry-service, image_tag=local-scan

set -euo pipefail

# --------------------------------------------------------------------------
# Configuration
# --------------------------------------------------------------------------
IMAGE_NAME="${1:-iot-telemetry-service}"
IMAGE_TAG="${2:-local-scan}"
FULL_IMAGE="${IMAGE_NAME}:${IMAGE_TAG}"
SEVERITY_GATE="HIGH,CRITICAL" # the actual gate threshold for requirement #4

# --------------------------------------------------------------------------
# Cosmetics -- plain ANSI colors, safe on any modern Linux or macOS terminal
# --------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m' # reset

section() { echo -e "\n${BOLD}==> $1${NC}"; }
pass()    { echo -e "${GREEN}✓ $1${NC}"; }
fail()    { echo -e "${RED}✗ $1${NC}"; }

# ==========================================================================
# STEP 1 -- Verify Trivy and TruffleHog are installed
# ==========================================================================
# Both tools are checked before anything else runs, and we report every
# missing tool at once (not just the first one hit) so a fresh machine
# doesn't need three runs of this script to discover three missing tools.
section "Checking required tools"

MISSING=0
OS_NAME="$(uname -s)" # "Linux" or "Darwin" (macOS) -- tailors the install hints below

check_tool() {
    local tool="$1"
    if command -v "$tool" >/dev/null 2>&1; then
        pass "$tool found: $(command -v "$tool")"
    else
        fail "$tool is NOT installed"
        MISSING=1
    fi
}

check_tool trivy
check_tool trufflehog

if [ "$MISSING" -eq 1 ]; then
    echo
    echo -e "${YELLOW}One or more required tools are missing. Install instructions:${NC}\n"

    if ! command -v trivy >/dev/null 2>&1; then
        echo "  Trivy:"
        if [ "$OS_NAME" = "Darwin" ]; then
            echo "    brew install trivy"
        else
            echo "    curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b /usr/local/bin"
            echo "    (or see https://trivy.dev/docs/latest/getting-started/installation/ for apt/yum repo setup)"
        fi
        echo
    fi

    if ! command -v trufflehog >/dev/null 2>&1; then
        echo "  TruffleHog:"
        if [ "$OS_NAME" = "Darwin" ]; then
            echo "    brew install trufflehog"
        else
            echo "    curl -sSfL https://raw.githubusercontent.com/trufflesecurity/trufflehog/main/scripts/install.sh | sh -s -- -b /usr/local/bin"
        fi
        echo
    fi

    echo -e "${YELLOW}NOTE: if you just installed one of these via Homebrew, open a NEW${NC}"
    echo -e "${YELLOW}terminal window before re-running this script -- an already-open shell${NC}"
    echo -e "${YELLOW}won't see the updated PATH.${NC}"
    exit 1
fi

# Docker isn't one of the two named tools, but steps 3-4 can't run without
# it, so fail here with a clear message instead of a confusing error later.
if ! command -v docker >/dev/null 2>&1; then
    fail "docker is NOT installed or not on PATH"
    echo "  Install Docker Desktop: https://docker.com/products/docker-desktop"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    fail "Docker is installed but the daemon isn't running"
    echo "  Start Docker Desktop and wait for the whale icon to go steady, then re-run."
    exit 1
fi
pass "docker found and daemon is running"

# ==========================================================================
# STEP 2 -- TruffleHog: scan the working directory for hardcoded secrets
# ==========================================================================
# --results=verified,unknown
#   Report both LIVE-confirmed credentials ("verified" -- TruffleHog
#   actually tested the value against the real service and it worked) AND
#   high-confidence pattern matches it could NOT verify one way or the
#   other ("unknown" -- e.g. no network access to check, or the credential
#   type has no live check at all). Without this flag TruffleHog only
#   reports "verified" results by default, silently missing anything it
#   can't actively test.
# --exclude-paths=.trufflehog-exclude.txt
#   Skips build/ (and any cmake-build-*/ dir), which holds the FULL fetched
#   source of Crow/nlohmann-json/libpqxx once you've run a local CMake
#   build. This isn't just about speed: those vendored trees carry their
#   own .git history and docs, which can trip detectors on content that
#   has nothing to do with YOUR project (I hit this directly -- a stray
#   commit hash and a doc string in a dependency's own repo tripped two
#   detectors once, purely as noise). Never scan vendored/fetched
#   dependency code for "your" secrets.
# --fail
#   Exit with a non-zero code (183) if anything is found. This is what
#   turns "a secret was found" into "stop the script" -- without it,
#   TruffleHog just reports and exits 0 regardless of findings.
#
# Scope note (found by testing this exact script against this project):
# TruffleHog's ~800 detectors target *specific, recognizable* credential
# formats -- AWS/GCP keys, GitHub/Slack/Stripe tokens, private keys, JWTs,
# etc. It does NOT reliably catch an arbitrary hardcoded string like
# `DB_PASSWORD = "mypassword123"` -- there's no universal "shape" for a
# Postgres password to pattern-match against. A fake AWS key and a
# hardcoded password string both went undetected in testing, while a
# dropped-in private key was caught immediately. The real defense against
# hardcoded DB credentials in this project is architectural: Config.hpp
# only ever reads DB_PASSWORD from the environment and throws if it's
# absent, so there's no code path that could hold a literal secret. This
# scan is the backstop for the credential *types* it's actually good at,
# not a substitute for that design. For stronger generic-secret coverage,
# gitleaks' default ruleset adds keyword+entropy-based generic rules that
# TruffleHog v3 deliberately dropped in favor of precision.
section "Running TruffleHog secret scan"

TRUFFLEHOG_EXIT=0
trufflehog filesystem . --results=verified,unknown --exclude-paths=.trufflehog-exclude.txt --fail || TRUFFLEHOG_EXIT=$?

case "$TRUFFLEHOG_EXIT" in
    0)
        pass "No secrets detected"
        ;;
    183)
        fail "TruffleHog found a potential secret above. Fix it before pushing."
        exit 1
        ;;
    *)
        fail "TruffleHog could not complete the scan (exit code ${TRUFFLEHOG_EXIT}) -- this is a scan failure (e.g. a missing/misconfigured --exclude-paths file, as I hit while testing this), not a secret finding. See the output above."
        exit 1
        ;;
esac

# ==========================================================================
# STEP 3 -- Build the Docker image
# ==========================================================================
section "Building Docker image: ${FULL_IMAGE}"

if [ ! -f "Dockerfile" ]; then
    fail "No Dockerfile found in $(pwd) -- run this script from the project root."
    exit 1
fi

if ! docker build -t "${FULL_IMAGE}" .; then
    fail "Docker build failed -- fix the build error above before scanning."
    exit 1
fi
pass "Image built: ${FULL_IMAGE}"

# ==========================================================================
# STEP 4 -- Trivy: scan the image, gated on HIGH/CRITICAL only
# ==========================================================================
# --severity HIGH,CRITICAL
#   Both DISPLAYS and GATES on only these two levels. LOW/MEDIUM/UNKNOWN
#   findings still exist in the image but won't show in this output or
#   affect the exit code -- this is the actual gating logic requirement #4
#   asked for.
# --exit-code 2
#   Deliberately NOT 1. Trivy uses exit code 1 internally for its own
#   runtime failures (can't reach the vulnerability DB, bad image
#   reference, network error, etc.) regardless of what --exit-code is set
#   to -- I confirmed this directly: forcing a DB-download failure still
#   produced exit code 1 even with --exit-code 2 configured. Using 2 here
#   means we can tell "Trivy found HIGH/CRITICAL vulnerabilities" (exit 2)
#   apart from "Trivy itself couldn't complete the scan" (exit 1) instead
#   of both collapsing into the same generic failure message.
# --ignore-unfixed
#   Skip CVEs with no available patch yet. Without this, the gate can fail
#   permanently on issues you have no way to act on right now (common with
#   base-image OS packages waiting on an upstream fix) -- this makes the
#   gate mean "is there something I can do about this today", not "does a
#   CVE exist somewhere in this image". Remove this flag if you'd rather
#   see (and block on) every matching CVE regardless of fix availability.
section "Running Trivy image scan (gate: ${SEVERITY_GATE})"

TRIVY_EXIT=0
trivy image --severity "${SEVERITY_GATE}" --exit-code 2 --ignore-unfixed "${FULL_IMAGE}" || TRIVY_EXIT=$?

case "$TRIVY_EXIT" in
    0)
        pass "No HIGH/CRITICAL vulnerabilities found"
        ;;
    2)
        fail "HIGH or CRITICAL severity vulnerabilities found in ${FULL_IMAGE}. Fix before pushing."
        exit 1
        ;;
    *)
        fail "Trivy could not complete the scan (exit code ${TRIVY_EXIT}) -- this is a scan failure (DB download, network, or bad image reference), not a vulnerability finding. See the output above."
        exit 1
        ;;
esac

# ==========================================================================
section "All security gates passed"
echo "Safe to push to GitHub."
exit 0
