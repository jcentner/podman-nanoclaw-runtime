#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# smoke.sh — End-to-end validation that the nanoclaw + Podman setup works
# =============================================================================
#
# Runs a series of tests to verify the agent image builds, the container starts,
# and (with an API key) the agent responds with valid sentinel-wrapped JSON.
#
# Without an API key, runs a partial test that verifies the container starts
# and the entrypoint script begins execution.
#
# Usage:
#   smoke.sh [--nanoclaw-dir <path>]
#
# Examples:
#   smoke.sh
#   ANTHROPIC_API_KEY=sk-... smoke.sh
# =============================================================================

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
readonly DEFAULT_NANOCLAW_DIR="$HOME/nanoclaw"
readonly CONTAINER_NAME="nanoclaw-smoke-test"
readonly IMAGE="nanoclaw-agent:latest"
readonly START_SENTINEL="---NANOCLAW_OUTPUT_START---"
readonly END_SENTINEL="---NANOCLAW_OUTPUT_END---"

# Resolve the directory where this script lives (for locating sibling scripts).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
NANOCLAW_DIR=""
TEMP_DIR=""
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_TESTS=0
HAS_API_KEY=false

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

End-to-end smoke test for the nanoclaw + Podman setup.

Tests:
  1. Agent image builds successfully
  2. Container starts and runs entrypoint
  3. Agent responds with valid sentinel-wrapped JSON (requires API key)
  4. Response status is 'success' (requires API key)

Without ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN set, only tests 1-2 run
(credential-free partial test).

Options:
  --nanoclaw-dir <path>   Path to the nanoclaw directory (default: ~/nanoclaw)
  -h, --help              Show this help message

Examples:
  $(basename "$0")
  ANTHROPIC_API_KEY=sk-... $(basename "$0")
EOF
}

die() {
    echo "ERROR: $1" >&2
    if [[ -n "${2:-}" ]]; then
        echo "  → $2" >&2
    fi
    exit "${3:-1}"
}

pass() {
    echo "[PASS] $1"
    ((PASS_COUNT++))
    ((TOTAL_TESTS++))
}

fail() {
    echo "[FAIL] $1" >&2
    if [[ -n "${2:-}" ]]; then
        echo "       $2" >&2
    fi
    ((FAIL_COUNT++))
    ((TOTAL_TESTS++))
}

skip() {
    echo "[SKIP] $1"
}

# ---------------------------------------------------------------------------
# Cleanup (runs on EXIT)
# ---------------------------------------------------------------------------

cleanup() {
    # Kill any leftover smoke test containers.
    # Use a name prefix to catch both "-start" and main containers.
    local name
    for name in "$CONTAINER_NAME" "${CONTAINER_NAME}-start"; do
        if podman container exists "$name" 2>/dev/null; then
            podman kill "$name" &>/dev/null || true
            podman rm -f "$name" &>/dev/null || true
        fi
    done

    # Remove temp directory if it exists
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf "$TEMP_DIR"
    fi
}

trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Helper: run a container with a hard timeout via podman stop
# ---------------------------------------------------------------------------
# Usage: run_container_with_timeout <timeout_seconds> <container_name> <podman_run_args...>
#   Writes stdout to $CONTAINER_STDOUT and stderr to $CONTAINER_STDERR (temp files).
#   Sets $CONTAINER_EXIT_CODE.
#
# Why not `timeout podman run`?
#   `timeout` kills the podman CLI client but the container keeps running as
#   a separate process (managed by conmon). This leaves orphans that can't be
#   stopped with Ctrl+C, requiring `wsl --shutdown` or manual `podman kill`.
#   Instead, we launch a background watchdog that runs `podman stop` after
#   the timeout, while podman run stays in the foreground (preserving stdin).

CONTAINER_STDOUT=""
CONTAINER_STDERR=""
CONTAINER_EXIT_CODE=0

run_container_with_timeout() {
    local timeout_secs="$1" cname="$2"
    shift 2

    CONTAINER_STDOUT=$(mktemp)
    CONTAINER_STDERR=$(mktemp)
    CONTAINER_EXIT_CODE=0

    # Watchdog: stop the container after timeout (runs in background)
    (
        sleep "$timeout_secs"
        podman stop -t 5 "$cname" &>/dev/null || true
    ) &
    local watchdog_pid=$!

    # Run podman in the foreground so stdin piping works correctly
    podman run --name "$cname" "$@" \
        >"$CONTAINER_STDOUT" 2>"$CONTAINER_STDERR" || CONTAINER_EXIT_CODE=$?

    # Clean up watchdog
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Test: Image build
# ---------------------------------------------------------------------------

test_image_build() {
    local build_script="${SCRIPT_DIR}/../scripts/build-agent-image.sh"

    if [[ ! -x "$build_script" ]]; then
        fail "Agent image builds successfully" "build-agent-image.sh not found at ${build_script}"
        return 1
    fi

    if "$build_script" --nanoclaw-dir "$NANOCLAW_DIR" &>/dev/null; then
        pass "Agent image builds successfully"
    else
        fail "Agent image builds successfully" "podman build exited non-zero"
        return 1
    fi

    # Verify image exists
    if ! podman image exists "$IMAGE" 2>/dev/null; then
        fail "Agent image exists after build" "podman image exists ${IMAGE} returned false"
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# Test: Container starts (credential-free)
# ---------------------------------------------------------------------------

test_container_starts() {
    TEMP_DIR=$(mktemp -d)
    local claude_dir
    claude_dir=$(mktemp -d)

    # Run the container with a trivial command to verify the entrypoint starts.
    # Without an API key the agent will error out, but we just want to see
    # that the container started and the entrypoint ran.
    run_container_with_timeout 60 "${CONTAINER_NAME}-start" \
        -i --rm \
        --userns=keep-id \
        -v "${TEMP_DIR}:/workspace/group" \
        -v "${claude_dir}:/home/node/.claude" \
        "$IMAGE" <<< '{}'

    local output stderr_output
    output=$(cat "$CONTAINER_STDOUT" 2>/dev/null || true)
    stderr_output=$(cat "$CONTAINER_STDERR" 2>/dev/null || true)

    # We accept any exit code here — without valid input/API key, the agent will
    # error out. We just want to verify the container started and the entrypoint ran.
    # Look for signs that the entrypoint script executed (TypeScript compilation, etc.)
    if [[ -n "$output" || -n "$stderr_output" ]]; then
        pass "Container starts and runs entrypoint"
    else
        fail "Container starts and runs entrypoint" "No output from container (entrypoint may not have run)"
        return 1
    fi

    rm -rf "$claude_dir"
    return 0
}

# ---------------------------------------------------------------------------
# Test: Full agent run (requires API key)
# ---------------------------------------------------------------------------

test_agent_response() {
    if [[ "$HAS_API_KEY" == false ]]; then
        skip "Agent responds with valid sentinel-wrapped JSON (no API key)"
        skip "Response status is 'success' (no API key)"
        return 0
    fi

    TEMP_DIR=$(mktemp -d)
    mkdir -p "${TEMP_DIR}/ipc/messages" "${TEMP_DIR}/ipc/tasks" "${TEMP_DIR}/ipc/input"

    # Construct test input JSON
    local input_json
    input_json=$(cat <<'ENDJSON'
{
    "prompt": "Reply with exactly: SMOKE_TEST_OK",
    "groupFolder": "smoke-test",
    "chatJid": "smoke@test",
    "isMain": false,
    "isScheduledTask": false,
    "assistantName": "SmokeTest",
    "secrets": {}
}
ENDJSON
)

    # Inject the actual API key into the secrets object
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        input_json="${input_json//\"secrets\": \{\}/\"secrets\": \{\"ANTHROPIC_API_KEY\": \"${ANTHROPIC_API_KEY}\"\}}"
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        input_json="${input_json//\"secrets\": \{\}/\"secrets\": \{\"CLAUDE_CODE_OAUTH_TOKEN\": \"${CLAUDE_CODE_OAUTH_TOKEN}\"\}}"
    fi

    local claude_dir
    claude_dir=$(mktemp -d)

    # Pipe input JSON via a temp file + redirect, since the background-process
    # approach used by run_container_with_timeout can't pipe stdin directly.
    local input_file
    input_file=$(mktemp)
    echo "$input_json" > "$input_file"

    # The agent-runner loops waiting for IPC messages after each query.
    # Monitor stdout for end sentinel, then write _close so it exits.
    local ipc_input_dir="${TEMP_DIR}/ipc/input"
    (
        while true; do
            if [[ -f "$CONTAINER_STDOUT" ]] && grep -qF -- "$END_SENTINEL" "$CONTAINER_STDOUT" 2>/dev/null; then
                sleep 1
                touch "${ipc_input_dir}/_close"
                break
            fi
            sleep 0.5
        done
    ) &
    local ipc_watcher_pid=$!

    # Run the full agent — allow up to 180s for the agent to respond.
    # Uses run_container_with_timeout for reliable cleanup (no orphaned containers).
    run_container_with_timeout 180 "$CONTAINER_NAME" \
        -i --rm \
        --userns=keep-id \
        -v "${TEMP_DIR}:/workspace/group" \
        -v "${NANOCLAW_DIR}:/workspace/project:ro" \
        -v "${claude_dir}:/home/node/.claude" \
        -e "CLAUDE_MODEL=${CLAUDE_MODEL:-haiku}" \
        "$IMAGE" < "$input_file"

    # Clean up IPC watcher
    kill "$ipc_watcher_pid" 2>/dev/null || true
    wait "$ipc_watcher_pid" 2>/dev/null || true

    local output stderr_output exit_code
    output=$(cat "$CONTAINER_STDOUT" 2>/dev/null || true)
    stderr_output=$(cat "$CONTAINER_STDERR" 2>/dev/null || true)
    exit_code="$CONTAINER_EXIT_CODE"
    rm -f "$input_file"

    # Test: sentinel markers present
    if echo "$output" | grep -qF -- "$START_SENTINEL" && echo "$output" | grep -qF -- "$END_SENTINEL"; then
        pass "Agent responds with valid sentinel-wrapped JSON"
    else
        fail "Agent responds with valid sentinel-wrapped JSON" \
            "Sentinels not found in output (exit code: ${exit_code})"
        if [[ -n "$stderr_output" ]]; then
            echo "       Container stderr (last 20 lines):" >&2
            echo "$stderr_output" | tail -20 | sed 's/^/         /' >&2
        fi
        rm -rf "$claude_dir"
        return 1
    fi

    # Test: extract JSON and check status
    local json_payload
    json_payload=$(echo "$output" | sed -n "/${START_SENTINEL}/,/${END_SENTINEL}/p" \
        | grep -vF -- "$START_SENTINEL" | grep -vF -- "$END_SENTINEL")

    if echo "$json_payload" | grep -q '"status"'; then
        local status
        status=$(echo "$json_payload" | grep -o '"status"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 | sed 's/.*"status"[[:space:]]*:[[:space:]]*"//' | sed 's/"//')
        if [[ "$status" == "success" ]]; then
            pass "Response status is 'success'"
        else
            local result
            result=$(echo "$json_payload" | grep -o '"result"[[:space:]]*:[[:space:]]*"[^"]*"' \
                | head -1 | sed 's/.*"result"[[:space:]]*:[[:space:]]*"//' | sed 's/"$//')
            fail "Response status is 'success'" "Got status: '${status}'"
            if [[ -n "$result" ]]; then
                echo "       Agent result: ${result}" >&2
            fi
            echo "       Response JSON: ${json_payload}" >&2
            if [[ -n "$stderr_output" ]]; then
                echo "       Container stderr (last 20 lines):" >&2
                echo "$stderr_output" | tail -20 | sed 's/^/         /' >&2
            fi
        fi
    else
        fail "Response status is 'success'" "No 'status' field found in response JSON"
    fi

    rm -rf "$claude_dir"
    return 0
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    echo ""
    echo "Smoke test: ${PASS_COUNT}/${TOTAL_TESTS} passed"

    if [[ "$HAS_API_KEY" == false ]]; then
        echo ""
        echo "PARTIAL PASS — container starts but no API key for full test."
        echo "Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN for a complete test."
    fi

    if [[ "$FAIL_COUNT" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    NANOCLAW_DIR="$DEFAULT_NANOCLAW_DIR"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nanoclaw-dir)
                [[ $# -ge 2 ]] || die "--nanoclaw-dir requires a path argument."
                NANOCLAW_DIR="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1" "Run $(basename "$0") --help for usage."
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"

    echo "Nanoclaw Smoke Test"
    echo "==================="
    echo ""

    # Check for API key availability
    if [[ -n "${ANTHROPIC_API_KEY:-}" || -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        HAS_API_KEY=true
        echo "API key detected — running full test suite."
    else
        echo "No API key detected — running credential-free partial test."
        echo "Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN for full testing."
    fi
    echo ""

    # Validate nanoclaw dir exists
    if [[ ! -d "$NANOCLAW_DIR" ]]; then
        die "Nanoclaw directory not found: ${NANOCLAW_DIR}" \
            "Run setup-host.sh first, or use --nanoclaw-dir."
    fi

    # Run tests
    test_image_build || true
    test_container_starts || true
    test_agent_response || true

    print_summary
}

main "$@"
