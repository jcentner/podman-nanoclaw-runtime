#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-host.sh — Clone nanoclaw, install dependencies, and configure the
#                 environment for running AI agents in rootless Podman.
# =============================================================================
#
# Usage:
#   setup-host.sh [--nanoclaw-dir <path>] [--commit <hash>] [--non-interactive]
#
# Examples:
#   setup-host.sh
#   setup-host.sh --nanoclaw-dir /opt/nanoclaw --commit abc1234
#   setup-host.sh --non-interactive
# =============================================================================

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
readonly DEFAULT_NANOCLAW_DIR="$HOME/nanoclaw"

# TODO: Replace with a known-good commit hash after testing against nanoclaw main.
# To find a good commit: clone nanoclaw, run the smoke test, record the hash.
readonly DEFAULT_NANOCLAW_COMMIT="main"

readonly NANOCLAW_REPO="https://github.com/qwibitai/nanoclaw.git"

# Resolve the directory where this script lives (for locating sibling scripts).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# ---------------------------------------------------------------------------
# State (set by parse_args)
# ---------------------------------------------------------------------------
NANOCLAW_DIR=""
NANOCLAW_COMMIT=""
NON_INTERACTIVE=false

# Platform detection results (set by detect_platform)
PLATFORM=""          # "wsl2" or "bare-metal"
UBUNTU_VERSION=""    # e.g. "24.04"
UBUNTU_PRETTY=""     # e.g. "Ubuntu 24.04 LTS"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Clone nanoclaw, install dependencies, and configure the environment for
running AI agents in rootless Podman containers.

Steps performed:
  1. Detect platform (WSL2 / bare-metal) and print summary
  2. Validate prerequisites (Podman, Node.js, git, etc.)
  3. Clone nanoclaw (or update to the pinned commit)
  4. Install Node.js dependencies
  5. Create .env from template (interactive or non-interactive)
  6. Build the agent container image
  7. Print next steps

Options:
  --nanoclaw-dir <path>   Where to clone/find nanoclaw (default: ~/nanoclaw)
  --commit <hash>         Nanoclaw git commit to pin to
                          (default: $DEFAULT_NANOCLAW_COMMIT)
                          Can also be set via NANOCLAW_COMMIT env var.
  --non-interactive       Skip interactive prompts. Requires .env to exist
                          or credentials set via environment variables.
  -h, --help              Show this help message

Examples:
  $(basename "$0")
  $(basename "$0") --nanoclaw-dir /opt/nanoclaw
  $(basename "$0") --commit abc1234def --non-interactive
EOF
}

die() {
    echo "ERROR: $1" >&2
    if [[ -n "${2:-}" ]]; then
        echo "  → $2" >&2
    fi
    exit "${3:-1}"
}

warn() {
    echo "WARNING: $1" >&2
}

info() {
    echo "▸ $1"
}

step() {
    echo ""
    echo "═══ $1 ═══"
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

detect_platform() {
    step "Step 1/6: Detecting platform"

    # Detect WSL2 vs bare-metal
    if [[ -f /proc/version ]] && grep -qi 'microsoft' /proc/version; then
        PLATFORM="wsl2"
    else
        PLATFORM="bare-metal"
    fi

    # Detect Ubuntu version from /etc/os-release
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        UBUNTU_VERSION="${VERSION_ID:-unknown}"
        UBUNTU_PRETTY="${PRETTY_NAME:-Linux}"
    else
        UBUNTU_VERSION="unknown"
        UBUNTU_PRETTY="Linux (unknown distribution)"
    fi

    local platform_label
    if [[ "$PLATFORM" == "wsl2" ]]; then
        platform_label="WSL2"
    else
        platform_label="bare-metal"
    fi

    info "Running on: ${UBUNTU_PRETTY} (${platform_label})"

    # Warn if Ubuntu version is below 23.04
    if [[ "$UBUNTU_VERSION" != "unknown" ]]; then
        local major minor
        major="${UBUNTU_VERSION%%.*}"
        minor="${UBUNTU_VERSION#*.}"
        if [[ "$major" -lt 23 ]] || { [[ "$major" -eq 23 ]] && [[ "$minor" -lt 4 ]]; }; then
            warn "Ubuntu ${UBUNTU_VERSION} detected. 23.04+ is recommended (24.04 LTS preferred)."
            warn "Podman packaging and rootless support may be limited on older versions."
        fi
    fi
}

# ---------------------------------------------------------------------------
# Prerequisite validation
# ---------------------------------------------------------------------------

check_prereq() {
    local name="$1"
    local check_cmd="$2"
    local fail_msg="$3"
    local remediation="$4"

    if eval "$check_cmd" &>/dev/null; then
        info "  ✓ $name"
        return 0
    else
        echo "  ✗ $name" >&2
        echo "    $fail_msg" >&2
        echo "    → $remediation" >&2
        return 1
    fi
}

validate_prerequisites() {
    step "Step 2/6: Validating prerequisites"

    local failures=0

    # Podman remediation hint depends on platform
    local podman_hint
    if [[ "$PLATFORM" == "wsl2" ]]; then
        podman_hint="Use podman-wsl-setup: https://github.com/jcentner/podman-wsl-setup"
    else
        podman_hint="Install via: sudo apt install podman podman-docker"
    fi

    check_prereq "podman on PATH" \
        "command -v podman" \
        "Podman is not installed or not on PATH." \
        "$podman_hint" \
        || ((failures++))

    check_prereq "podman rootless mode" \
        "podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null | grep -q 'true'" \
        "Podman is not running in rootless mode." \
        "$podman_hint" \
        || ((failures++))

    check_prereq "docker shim on PATH (podman-docker)" \
        "command -v docker" \
        "The docker CLI shim (podman-docker) is not installed." \
        "$podman_hint" \
        || ((failures++))

    check_prereq "docker shim functional" \
        "docker info" \
        "The docker shim is not working (podman.socket may not be running)." \
        "Enable the socket: systemctl --user enable --now podman.socket" \
        || ((failures++))

    # Node.js — check exists and version >= 22
    check_prereq "node on PATH" \
        "command -v node" \
        "Node.js is not installed or not on PATH." \
        "Install Node.js 22+: https://nodejs.org/en/download/ (nvm, nodesource, or distro package)" \
        || ((failures++))

    if command -v node &>/dev/null; then
        local node_major
        node_major=$(node --version | sed 's/^v//' | cut -d. -f1)
        check_prereq "node version ≥ 22 (found v$(node --version | sed 's/^v//'))" \
            "[[ $node_major -ge 22 ]]" \
            "Node.js version $node_major is too old. Nanoclaw requires v22+." \
            "Upgrade Node.js: https://nodejs.org/en/download/" \
            || ((failures++))
    fi

    check_prereq "npm on PATH" \
        "command -v npm" \
        "npm is not installed or not on PATH." \
        "npm is typically bundled with Node.js. Reinstall Node.js if missing." \
        || ((failures++))

    check_prereq "git on PATH" \
        "command -v git" \
        "git is not installed or not on PATH." \
        "Install via: sudo apt install git" \
        || ((failures++))

    if [[ "$failures" -gt 0 ]]; then
        die "$failures prerequisite(s) failed. Fix the issues above and re-run this script."
    fi

    info "All prerequisites satisfied."
}

# ---------------------------------------------------------------------------
# Nanoclaw clone / update
# ---------------------------------------------------------------------------

clone_or_update_nanoclaw() {
    step "Step 3/6: Setting up nanoclaw source"

    if [[ -d "$NANOCLAW_DIR" ]]; then
        # Directory exists — check if it's a git repo
        if [[ -d "$NANOCLAW_DIR/.git" ]]; then
            info "Existing nanoclaw checkout found at ${NANOCLAW_DIR}"
            info "Fetching latest from origin..."
            git -C "$NANOCLAW_DIR" fetch origin
        else
            die "Directory exists but is not a git repository: ${NANOCLAW_DIR}" \
                "Remove it or choose a different path with --nanoclaw-dir."
        fi
    else
        info "Cloning nanoclaw into ${NANOCLAW_DIR}..."
        git clone "$NANOCLAW_REPO" "$NANOCLAW_DIR"
    fi

    # Checkout the pinned commit
    info "Checking out: ${NANOCLAW_COMMIT}"
    git -C "$NANOCLAW_DIR" checkout "$NANOCLAW_COMMIT"

    # Print commit info
    local short_hash commit_date
    short_hash=$(git -C "$NANOCLAW_DIR" rev-parse --short HEAD)
    commit_date=$(git -C "$NANOCLAW_DIR" log -1 --format='%ci' HEAD | cut -d' ' -f1)
    info "Nanoclaw pinned to commit: ${short_hash} (${commit_date})"
}

# ---------------------------------------------------------------------------
# Dependency installation
# ---------------------------------------------------------------------------

install_dependencies() {
    step "Step 4/6: Installing Node.js dependencies"

    # Host process dependencies (root package.json)
    if [[ -f "$NANOCLAW_DIR/package.json" ]]; then
        info "Installing host process dependencies (npm ci)..."
        if ! (cd "$NANOCLAW_DIR" && npm ci); then
            die "npm ci failed for the host process." \
                "Check the output above. Verify node --version is v22+ and try again."
        fi
    else
        die "package.json not found in ${NANOCLAW_DIR}" \
            "Is this a valid nanoclaw checkout?"
    fi

    # Agent-runner dependencies (container/agent-runner/package.json)
    if [[ -f "$NANOCLAW_DIR/container/agent-runner/package.json" ]]; then
        info "Installing agent-runner dependencies (npm ci)..."
        if ! (cd "$NANOCLAW_DIR/container/agent-runner" && npm ci); then
            die "npm ci failed for the agent-runner." \
                "Check the output above. Verify node --version is v22+ and try again."
        fi
    else
        warn "container/agent-runner/package.json not found — skipping agent-runner deps."
        warn "The agent image may still work if deps are installed at build time."
    fi

    # Compile TypeScript for the host process
    info "Building host process (npm run build)..."
    if ! (cd "$NANOCLAW_DIR" && npm run build); then
        die "TypeScript compilation failed (npm run build)." \
            "Check the output above. Ensure devDependencies were installed."
    fi

    info "Dependencies installed and host process compiled."
}

# ---------------------------------------------------------------------------
# .env configuration
# ---------------------------------------------------------------------------

configure_env() {
    step "Step 5/6: Configuring .env"

    local env_file="$NANOCLAW_DIR/.env"

    if [[ -f "$env_file" ]]; then
        info "Using existing .env (${env_file})"
        return 0
    fi

    # Copy template from this repo
    local template="${SCRIPT_DIR}/../examples/env.example"
    if [[ ! -f "$template" ]]; then
        die "env.example template not found at ${template}" \
            "Ensure the podman-nanoclaw-runtime repo is intact."
    fi

    cp "$template" "$env_file"
    info "Created .env from template"

    if [[ "$NON_INTERACTIVE" == true ]]; then
        # Non-interactive: check for credentials in environment
        if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
            sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}|" "$env_file"
            info "Set ANTHROPIC_API_KEY from environment"
        elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
            # Uncomment the OAuth line and set it
            sed -i "s|^# CLAUDE_CODE_OAUTH_TOKEN=.*|CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN}|" "$env_file"
            info "Set CLAUDE_CODE_OAUTH_TOKEN from environment"
        else
            warn "No API credentials found in environment."
            warn "Edit ${env_file} and set ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN before running nanoclaw."
        fi

        if [[ -n "${ASSISTANT_NAME:-}" ]]; then
            sed -i "s|^ASSISTANT_NAME=.*|ASSISTANT_NAME=${ASSISTANT_NAME}|" "$env_file"
        fi

        if [[ -n "${CLAUDE_MODEL:-}" ]]; then
            sed -i "s|^CLAUDE_MODEL=.*|CLAUDE_MODEL=${CLAUDE_MODEL}|" "$env_file"
        fi
        return 0
    fi

    # Interactive mode: prompt for credentials
    echo ""
    echo "Nanoclaw needs an API credential to run Claude agents."
    echo "You need either an ANTHROPIC_API_KEY or a CLAUDE_CODE_OAUTH_TOKEN."
    echo ""

    local credential_set=false

    read -r -p "Enter ANTHROPIC_API_KEY (or press Enter to skip): " api_key
    if [[ -n "$api_key" ]]; then
        sed -i "s|^ANTHROPIC_API_KEY=.*|ANTHROPIC_API_KEY=${api_key}|" "$env_file"
        credential_set=true
        info "ANTHROPIC_API_KEY set"
    fi

    if [[ "$credential_set" == false ]]; then
        read -r -p "Enter CLAUDE_CODE_OAUTH_TOKEN (or press Enter to skip): " oauth_token
        if [[ -n "$oauth_token" ]]; then
            sed -i "s|^# CLAUDE_CODE_OAUTH_TOKEN=.*|CLAUDE_CODE_OAUTH_TOKEN=${oauth_token}|" "$env_file"
            credential_set=true
            info "CLAUDE_CODE_OAUTH_TOKEN set"
        fi
    fi

    if [[ "$credential_set" == false ]]; then
        warn "No credentials provided. Edit ${env_file} before running nanoclaw."
    fi

    # Prompt for assistant name
    read -r -p "Assistant name [Andy]: " assistant_name
    if [[ -n "$assistant_name" ]]; then
        sed -i "s|^ASSISTANT_NAME=.*|ASSISTANT_NAME=${assistant_name}|" "$env_file"
        info "Assistant name set to: ${assistant_name}"
    else
        info "Using default assistant name: Andy"
    fi

    # Prompt for model
    echo ""
    echo "Which Claude model should the agent use?"
    echo "  1) haiku   (fast, cheapest — recommended)"
    echo "  2) sonnet  (balanced)"
    echo "  3) opus    (most capable, expensive)"
    echo ""
    read -r -p "Model [1]: " model_choice
    local model
    case "${model_choice:-1}" in
        1) model="haiku" ;;
        2) model="sonnet" ;;
        3) model="opus" ;;
        *) model="$model_choice" ;;
    esac
    sed -i "s|^CLAUDE_MODEL=.*|CLAUDE_MODEL=${model}|" "$env_file"
    info "Model set to: ${model}"
}

# ---------------------------------------------------------------------------
# Agent image build
# ---------------------------------------------------------------------------

build_agent_image() {
    step "Step 6/6: Building agent container image"

    local build_script="${SCRIPT_DIR}/build-agent-image.sh"

    if [[ ! -x "$build_script" ]]; then
        die "build-agent-image.sh not found or not executable at ${build_script}" \
            "Ensure the podman-nanoclaw-runtime repo is intact."
    fi

    if ! "$build_script" --nanoclaw-dir "$NANOCLAW_DIR"; then
        die "Agent image build failed." \
            "Check the Podman output above. Try: podman system df (disk), podman system reset (corruption)."
    fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
    local short_hash
    short_hash=$(git -C "$NANOCLAW_DIR" rev-parse --short HEAD)

    local platform_label
    if [[ "$PLATFORM" == "wsl2" ]]; then
        platform_label="WSL2"
    else
        platform_label="bare-metal"
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║  Setup complete!                                           ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""
    echo "  Platform:          ${UBUNTU_PRETTY} (${platform_label})"
    echo "  Nanoclaw commit:   ${short_hash}"
    echo "  Nanoclaw dir:      ${NANOCLAW_DIR}"
    echo "  Agent image:       nanoclaw-agent:latest"
    echo ""
    echo "Next steps:"
    echo "  1. Ensure .env has valid credentials:  nano ${NANOCLAW_DIR}/.env"
    echo "  2. Start nanoclaw:  examples/run-nanoclaw.sh --nanoclaw-dir ${NANOCLAW_DIR}"
    echo ""
    echo "On first run, nanoclaw will display a WhatsApp QR code to scan."
    echo ""
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
    NANOCLAW_DIR="$DEFAULT_NANOCLAW_DIR"
    NANOCLAW_COMMIT="${NANOCLAW_COMMIT:-$DEFAULT_NANOCLAW_COMMIT}"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --nanoclaw-dir)
                [[ $# -ge 2 ]] || die "--nanoclaw-dir requires a path argument."
                NANOCLAW_DIR="$2"
                shift 2
                ;;
            --commit)
                [[ $# -ge 2 ]] || die "--commit requires a commit hash argument."
                NANOCLAW_COMMIT="$2"
                shift 2
                ;;
            --non-interactive)
                NON_INTERACTIVE=true
                shift
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

    echo "podman-nanoclaw-runtime — Host Setup"
    echo "====================================="

    detect_platform
    validate_prerequisites
    clone_or_update_nanoclaw
    install_dependencies
    configure_env
    build_agent_image
    print_summary
}

main "$@"
