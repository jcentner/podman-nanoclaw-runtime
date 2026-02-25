#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# run-nanoclaw.sh — Start the nanoclaw host process
# =============================================================================
#
# Runs nanoclaw's host process in the foreground. On first run, nanoclaw will
# display a WhatsApp QR code to scan for authentication.
#
# Usage:
#   run-nanoclaw.sh [--nanoclaw-dir <path>]
#
# Examples:
#   run-nanoclaw.sh
#   run-nanoclaw.sh --nanoclaw-dir /opt/nanoclaw
# =============================================================================

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
readonly DEFAULT_NANOCLAW_DIR="$HOME/nanoclaw"

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Start the nanoclaw host process in the foreground.

Pre-flight checks verify that the setup is complete (compiled code, .env,
container image, Podman). On first run, nanoclaw will display a WhatsApp
QR code for authentication — scan it with your phone.

Options:
  --nanoclaw-dir <path>   Path to the nanoclaw directory (default: ~/nanoclaw)
  -h, --help              Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --nanoclaw-dir /opt/nanoclaw
EOF
}

die() {
    echo "ERROR: $1" >&2
    if [[ -n "${2:-}" ]]; then
        echo "  → $2" >&2
    fi
    exit "${3:-1}"
}

info() {
    echo "▸ $1"
}

# ---------------------------------------------------------------------------
# Pre-flight checks
# ---------------------------------------------------------------------------

preflight() {
    local nanoclaw_dir="$1"
    local failures=0

    info "Running pre-flight checks..."

    # Nanoclaw directory exists
    if [[ ! -d "$nanoclaw_dir" ]]; then
        echo "  ✗ Nanoclaw directory not found: ${nanoclaw_dir}" >&2
        echo "    → Run setup-host.sh first, or use --nanoclaw-dir." >&2
        ((failures++))
    fi

    # Compiled output exists
    if [[ ! -f "$nanoclaw_dir/dist/index.js" ]]; then
        echo "  ✗ dist/index.js not found (TypeScript not compiled)" >&2
        echo "    → Run setup-host.sh, or: cd ${nanoclaw_dir} && npm run build" >&2
        ((failures++))
    fi

    # .env exists and is non-empty
    if [[ ! -s "$nanoclaw_dir/.env" ]]; then
        echo "  ✗ .env is missing or empty in ${nanoclaw_dir}" >&2
        echo "    → Run setup-host.sh, or copy examples/env.example to ${nanoclaw_dir}/.env" >&2
        ((failures++))
    fi

    # Agent image exists
    if ! podman image exists nanoclaw-agent:latest 2>/dev/null; then
        echo "  ✗ Agent image nanoclaw-agent:latest not found" >&2
        echo "    → Run: scripts/build-agent-image.sh --nanoclaw-dir ${nanoclaw_dir}" >&2
        ((failures++))
    fi

    # Podman is functional
    if ! command -v podman &>/dev/null; then
        echo "  ✗ podman not found on PATH" >&2
        echo "    → Install Podman: https://podman.io/docs/installation" >&2
        ((failures++))
    fi

    # Docker shim is functional
    if ! command -v docker &>/dev/null; then
        echo "  ✗ docker shim (podman-docker) not found on PATH" >&2
        echo "    → Install: sudo apt install podman-docker" >&2
        ((failures++))
    fi

    if [[ "$failures" -gt 0 ]]; then
        die "$failures pre-flight check(s) failed. Fix the issues above and try again."
    fi

    info "All pre-flight checks passed."
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

    preflight "$NANOCLAW_DIR"

    echo ""
    info "Starting nanoclaw host process..."
    info "Directory: ${NANOCLAW_DIR}"
    echo ""
    echo "  On first run, a WhatsApp QR code will appear — scan it with your phone."
    echo "  Press Ctrl+C to stop."
    echo ""

    cd "$NANOCLAW_DIR"
    exec node dist/index.js
}

main "$@"
