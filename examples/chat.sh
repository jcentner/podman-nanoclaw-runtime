#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# chat.sh — Headless conversation with a nanoclaw agent container
# =============================================================================
#
# Bypasses the nanoclaw host process entirely. Each prompt spawns an ephemeral
# agent container, pipes the entrypoint-contract JSON on stdin, and parses
# the sentinel-wrapped JSON response on stdout.
#
# Session IDs are preserved across prompts to maintain conversation context.
#
# Usage:
#   chat.sh                                  # interactive REPL
#   chat.sh "What is 2+2?"                   # single-shot mode
#   chat.sh --workspace ~/myproject          # agent works on a specific dir
#
# Requires: ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN in environment.
# =============================================================================

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
readonly DEFAULT_NANOCLAW_DIR="$HOME/nanoclaw"
readonly IMAGE="nanoclaw-agent:latest"
readonly START_SENTINEL="---NANOCLAW_OUTPUT_START---"
readonly END_SENTINEL="---NANOCLAW_OUTPUT_END---"
readonly TIMEOUT_SECONDS=300

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
NANOCLAW_DIR=""
GROUP_NAME="headless"
MODEL="${CLAUDE_MODEL:-haiku}"
WORKSPACE_DIR=""
SESSION_ID=""
SESSION_FILE=""
SINGLE_SHOT_PROMPT=""

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [PROMPT]

Headless conversation with a nanoclaw agent container.

Each prompt spawns an ephemeral agent container, bypassing the nanoclaw host
process. Session IDs are preserved across prompts for multi-turn conversations.

If PROMPT is provided as a positional argument, runs in single-shot mode:
prints the response and exits.

Without a PROMPT, enters an interactive REPL.

Options:
  --nanoclaw-dir <path>   Path to the nanoclaw directory (default: ~/nanoclaw)
  --workspace <path>      Directory for the agent to work in (default: auto-created)
  --group <name>          Group name for session isolation (default: headless)
  --model <model>         Claude model to use (default: \$CLAUDE_MODEL or haiku)
  -h, --help              Show this help message

Environment:
  ANTHROPIC_API_KEY          Anthropic API key (required if no OAuth token)
  CLAUDE_CODE_OAUTH_TOKEN    Claude Code OAuth token (alternative to API key)
  CLAUDE_MODEL               Default model (overridden by --model)

Examples:
  $(basename "$0")
  $(basename "$0") "Explain rootless Podman in one paragraph"
  $(basename "$0") --workspace ~/myproject --model sonnet
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

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

validate_prerequisites() {
    if [[ -z "${ANTHROPIC_API_KEY:-}" && -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        die "No API credentials found." \
            "Set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN in your environment."
    fi

    if ! command -v podman &>/dev/null; then
        die "podman not found on PATH." "Install Podman first."
    fi

    if ! podman image exists "$IMAGE" 2>/dev/null; then
        die "Agent image '${IMAGE}' not found." \
            "Run scripts/build-agent-image.sh first."
    fi

    if [[ ! -d "$NANOCLAW_DIR" ]]; then
        die "Nanoclaw directory not found: ${NANOCLAW_DIR}" \
            "Run scripts/setup-host.sh first, or use --nanoclaw-dir."
    fi
}

# ---------------------------------------------------------------------------
# Workspace & session setup
# ---------------------------------------------------------------------------

setup_workspace() {
    # Create group workspace if not using an explicit workspace
    if [[ -z "$WORKSPACE_DIR" ]]; then
        WORKSPACE_DIR="${NANOCLAW_DIR}/groups/${GROUP_NAME}"
    fi
    mkdir -p "$WORKSPACE_DIR"

    # IPC directories (mounted but unused in headless mode)
    mkdir -p "${WORKSPACE_DIR}/ipc/messages" \
             "${WORKSPACE_DIR}/ipc/tasks" \
             "${WORKSPACE_DIR}/ipc/input"

    # Claude session data directory
    local claude_dir="${WORKSPACE_DIR}/.claude"
    mkdir -p "$claude_dir"

    # Session file for persisting session ID across invocations
    SESSION_FILE="${WORKSPACE_DIR}/.chat-session-id"
    if [[ -f "$SESSION_FILE" ]]; then
        SESSION_ID=$(cat "$SESSION_FILE")
    fi
}

# ---------------------------------------------------------------------------
# JSON helpers (uses python3 for safe encoding/decoding)
# ---------------------------------------------------------------------------

json_encode_string() {
    printf '%s' "$1" | python3 -c 'import json, sys; print(json.dumps(sys.stdin.read()))'
}

json_extract_field() {
    local json="$1" field="$2" default="${3:-}"
    echo "$json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('${field}', '${default}'))
except Exception:
    print('${default}')
" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Build entrypoint-contract JSON
# ---------------------------------------------------------------------------

build_input_json() {
    local prompt="$1"
    local encoded_prompt
    encoded_prompt=$(json_encode_string "$prompt")

    local session_field=""
    if [[ -n "$SESSION_ID" ]]; then
        session_field="\"sessionId\": \"${SESSION_ID}\","
    fi

    local secrets=""
    if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
        secrets="\"ANTHROPIC_API_KEY\": \"${ANTHROPIC_API_KEY}\""
    elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
        secrets="\"CLAUDE_CODE_OAUTH_TOKEN\": \"${CLAUDE_CODE_OAUTH_TOKEN}\""
    fi

    cat <<ENDJSON
{
    "prompt": ${encoded_prompt},
    ${session_field}
    "groupFolder": "${GROUP_NAME}",
    "chatJid": "headless@local",
    "isMain": true,
    "isScheduledTask": false,
    "assistantName": "Agent",
    "secrets": {${secrets}}
}
ENDJSON
}

# ---------------------------------------------------------------------------
# Run agent container and parse response
# ---------------------------------------------------------------------------

run_agent() {
    local prompt="$1"
    local input_json
    input_json=$(build_input_json "$prompt")

    local container_name
    container_name="nanoclaw-chat-$(date +%s)"
    local claude_dir="${WORKSPACE_DIR}/.claude"
    local output=""
    local exit_code=0

    # --userns=keep-id maps host UID to container's node user (UID 1000),
    # so bind-mounted directories are writable inside the container.
    output=$(echo "$input_json" | timeout "$TIMEOUT_SECONDS" podman run -i --rm \
        --userns=keep-id \
        --name "$container_name" \
        -v "${WORKSPACE_DIR}:/workspace/group" \
        -v "${NANOCLAW_DIR}:/workspace/project:ro" \
        -v "${claude_dir}:/home/node/.claude" \
        -e "CLAUDE_MODEL=${MODEL}" \
        "$IMAGE" 2>/dev/null) || exit_code=$?

    parse_response "$output" "$exit_code"
}

parse_response() {
    local output="$1" exit_code="$2"

    # Check for sentinel markers
    if ! echo "$output" | grep -qF -- "$START_SENTINEL"; then
        echo ""
        echo "[Error] No valid response from agent (exit code: ${exit_code})"
        echo "Run with stderr visible for details:"
        echo "  podman run -i --rm ${IMAGE} < input.json"
        echo ""
        return 1
    fi

    # Extract JSON between sentinels
    local json_payload
    json_payload=$(echo "$output" \
        | sed -n "/${START_SENTINEL}/,/${END_SENTINEL}/p" \
        | grep -vF -- "$START_SENTINEL" \
        | grep -vF -- "$END_SENTINEL")

    # Extract and display the result text
    local result
    result=$(json_extract_field "$json_payload" "result" "(no result)")

    # Update session ID for conversation continuity
    local new_session
    new_session=$(json_extract_field "$json_payload" "newSessionId" "")
    if [[ -n "$new_session" ]]; then
        SESSION_ID="$new_session"
        echo "$SESSION_ID" > "$SESSION_FILE"
    fi

    # Check status
    local status
    status=$(json_extract_field "$json_payload" "status" "unknown")
    if [[ "$status" != "success" ]]; then
        echo ""
        echo "[Agent error] ${result}"
        echo ""
        return 1
    fi

    echo ""
    echo "$result"
    echo ""
}

# ---------------------------------------------------------------------------
# Interactive REPL
# ---------------------------------------------------------------------------

run_repl() {
    echo "Nanoclaw Headless Chat"
    echo "====================="
    echo "Model: ${MODEL} | Group: ${GROUP_NAME}"
    echo "Workspace: ${WORKSPACE_DIR}"
    if [[ -n "$SESSION_ID" ]]; then
        echo "Resuming session: ${SESSION_ID:0:12}..."
    fi
    echo "Type 'exit' or press Ctrl+D to quit. Type '/new' to reset session."
    echo ""

    while true; do
        printf "> "
        read -r prompt || break
        [[ "$prompt" == "exit" ]] && break

        # Commands
        if [[ "$prompt" == "/new" ]]; then
            SESSION_ID=""
            rm -f "$SESSION_FILE"
            echo "Session reset."
            echo ""
            continue
        fi

        [[ -z "$prompt" ]] && continue

        run_agent "$prompt" || true
    done
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
            --workspace)
                [[ $# -ge 2 ]] || die "--workspace requires a path argument."
                WORKSPACE_DIR="$2"
                shift 2
                ;;
            --group)
                [[ $# -ge 2 ]] || die "--group requires a name argument."
                GROUP_NAME="$2"
                shift 2
                ;;
            --model)
                [[ $# -ge 2 ]] || die "--model requires a model name."
                MODEL="$2"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            -*)
                die "Unknown option: $1" "Run $(basename "$0") --help for usage."
                ;;
            *)
                # Positional argument = single-shot prompt
                SINGLE_SHOT_PROMPT="$1"
                shift
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    parse_args "$@"
    validate_prerequisites
    setup_workspace

    if [[ -n "$SINGLE_SHOT_PROMPT" ]]; then
        run_agent "$SINGLE_SHOT_PROMPT"
    else
        run_repl
    fi
}

main "$@"
