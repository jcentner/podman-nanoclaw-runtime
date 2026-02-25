#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# build-agent-image.sh — Build the nanoclaw agent container image using Podman
# =============================================================================
#
# Thin wrapper around `podman build` using nanoclaw's container/Dockerfile.
# Idempotent: rebuilding replaces the existing image.
#
# Usage:
#   build-agent-image.sh [--nanoclaw-dir <path>] [--tag <tag>]
#
# Examples:
#   build-agent-image.sh
#   build-agent-image.sh --nanoclaw-dir /opt/nanoclaw --tag v1.0
# =============================================================================

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
readonly DEFAULT_NANOCLAW_DIR="$HOME/nanoclaw"
readonly DEFAULT_TAG="latest"
readonly IMAGE_NAME="nanoclaw-agent"

# ---------------------------------------------------------------------------
# Functions
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Build the nanoclaw agent container image using Podman.

Options:
  --nanoclaw-dir <path>   Path to the nanoclaw source directory
                          (default: ~/nanoclaw)
  --tag <tag>             Image tag (default: latest)
  -h, --help              Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --nanoclaw-dir /opt/nanoclaw --tag v1.0
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

validate_nanoclaw_dir() {
    local dir="$1"

    if [[ ! -d "$dir" ]]; then
        die "Nanoclaw directory not found: $dir" \
            "Run setup-host.sh first, or use --nanoclaw-dir to specify the correct path."
    fi

    if [[ ! -f "$dir/container/Dockerfile" ]]; then
        die "Dockerfile not found at $dir/container/Dockerfile" \
            "Ensure this is a valid nanoclaw checkout. Expected: container/Dockerfile"
    fi
}

validate_podman() {
    if ! command -v podman &>/dev/null; then
        die "podman is not installed or not on PATH." \
            "Install Podman: https://podman.io/docs/installation"
    fi
}

format_size() {
    local bytes="$1"
    if [[ "$bytes" -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1073741824}")GB"
    elif [[ "$bytes" -ge 1048576 ]]; then
        echo "$(awk "BEGIN {printf \"%.1f\", $bytes/1048576}")MB"
    else
        echo "${bytes}B"
    fi
}

build_image() {
    local nanoclaw_dir="$1"
    local tag="$2"
    local full_tag="${IMAGE_NAME}:${tag}"

    info "Building image ${full_tag} from ${nanoclaw_dir}/container/"

    # Build using Podman directly (nanoclaw's build.sh respects CONTAINER_RUNTIME,
    # but we call podman build directly for clarity and control).
    if ! podman build -t "$full_tag" "${nanoclaw_dir}/container/"; then
        die "Image build failed." \
            "Check the Podman output above. Common issues:\n  - Network problems (pulling base image)\n  - Insufficient disk space (podman system df)\n  - Corrupted Podman storage (podman system reset)"
    fi

    # Print results
    local image_size
    image_size=$(podman image inspect "$full_tag" --format '{{.Size}}')
    info "Image built: ${full_tag} ($(format_size "$image_size"))"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    NANOCLAW_DIR="$DEFAULT_NANOCLAW_DIR"
    TAG="$DEFAULT_TAG"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nanoclaw-dir)
                [[ $# -ge 2 ]] || die "--nanoclaw-dir requires a path argument."
                NANOCLAW_DIR="$2"
                shift 2
                ;;
            --tag)
                [[ $# -ge 2 ]] || die "--tag requires a tag argument."
                TAG="$2"
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

    validate_podman
    validate_nanoclaw_dir "$NANOCLAW_DIR"
    build_image "$NANOCLAW_DIR" "$TAG"
}

main "$@"
