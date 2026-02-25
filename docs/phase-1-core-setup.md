# Phase 1: Core Setup Scripts (MVP)

**Status:** All scripts implemented. Pending: integration testing with a real nanoclaw checkout + pinning a known-good commit.

**Goal:** Get a single nanoclaw instance running on Podman — from zero to working agent in one session.

**Entry criteria:** User has a working rootless Podman installation with `podman-docker` shim (via podman-wsl-setup on WSL2, or manual setup on bare-metal).

**Exit criteria:** User can run `setup-host.sh`, then `build-agent-image.sh`, then `run-nanoclaw.sh`, and interact with a nanoclaw agent through WhatsApp (or headless mode). Smoke test passes.

**Integration test notes (post-implementation):**
- Added `CLAUDE_MODEL` env var support (default: `haiku`) to `env.example`, `setup-host.sh` (interactive model prompt), and `smoke.sh`
- Fixed smoke test: added `/home/node/.claude` mount (required by agent entrypoint), stderr capture on failure, increased timeout to 180s
- Partial smoke test (credential-free) passes. Full test requires `ANTHROPIC_API_KEY`.

**Remaining TODOs:**
- Pin `DEFAULT_NANOCLAW_COMMIT` in `setup-host.sh` to a tested known-good hash (currently defaults to `main`)
- Consider adding credential validation that blocks in interactive mode (currently warns but proceeds)

---

## 1.1 — `scripts/setup-host.sh`

Clone nanoclaw, install dependencies, and configure the environment.

### Behavior

```
setup-host.sh [--nanoclaw-dir <path>] [--commit <hash>] [--non-interactive]
```

1. Detect platform and print summary
2. Validate prerequisites
3. Clone nanoclaw (or update existing)
4. Install Node.js dependencies
5. Create `.env` from template
6. Build the agent container image (calls `build-agent-image.sh`)
7. Print next steps

### Checklist

#### Platform detection
- [x] Detect WSL2 via `/proc/version` containing `microsoft` (case-insensitive)
- [x] Detect bare-metal Linux via absence of WSL markers
- [x] Print platform summary: `Running on: Ubuntu 24.04 (WSL2)` or `Running on: Ubuntu 24.04 (bare-metal)`
- [x] Detect Ubuntu version from `/etc/os-release`, warn if < 23.04

#### Prerequisite validation
- [x] Check `podman` exists on PATH
- [x] Check `podman info` succeeds and reports `rootless=true`
- [x] Check `docker` exists on PATH (podman-docker shim)
- [x] Check `docker info` succeeds (verifies shim + socket are working)
- [x] Check `node --version` reports v22+
- [x] Check `npm` exists on PATH
- [x] Check `git` exists on PATH
- [x] If any check fails: print clear error with remediation steps, exit non-zero
- [x] On WSL2: suggest podman-wsl-setup if Podman checks fail
- [x] On bare-metal: suggest `apt install podman podman-docker` if checks fail

#### Nanoclaw clone
- [x] Default clone location: `~/nanoclaw` (configurable via `--nanoclaw-dir`)
- [x] If directory exists and is a git repo: fetch + checkout pinned commit
- [x] If directory exists and is NOT a git repo: error with guidance
- [x] If directory does not exist: `git clone https://github.com/qwibitai/nanoclaw.git`
- [x] Checkout pinned commit: `git checkout $NANOCLAW_COMMIT`
- [ ] Default commit hash: hardcoded in script (document how to determine a good commit) — **TODO:** currently defaults to `main`; needs a tested known-good commit hash
- [x] Override via `--commit <hash>` or `NANOCLAW_COMMIT` env var
- [x] Print: `Nanoclaw pinned to commit: <short-hash> (<date>)`

#### Dependency installation
- [x] `cd` into nanoclaw directory
- [x] Run `npm ci` for the host process (root `package.json`)
- [x] Run `npm ci` for the agent-runner (`container/agent-runner/package.json`)
- [x] Run `npm run build` to compile TypeScript (host process)
- [x] Handle failure: print npm error output, suggest `node --version` check

#### `.env` configuration
- [x] Check if `.env` already exists in nanoclaw dir
- [x] If exists: skip creation, print "Using existing .env"
- [x] If not: copy `env.example` from this repo into nanoclaw dir
- [x] In interactive mode: prompt for `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`
- [ ] Validate that at least one credential is set (non-empty) — **TODO:** interactive mode warns but does not block; consider adding validation
- [x] Prompt for `ASSISTANT_NAME` (default: `Andy`)
- [x] Prompt for `CLAUDE_MODEL` (default: `haiku`, options: haiku/sonnet/opus)
- [x] In non-interactive mode: expect env vars to be pre-set or `.env` to exist already
- [x] Never echo secrets to stdout

#### Agent image build
- [x] Call `build-agent-image.sh` (from this repo's `scripts/`)
- [x] Pass through the nanoclaw directory path
- [x] If build fails: print error, suggest checking Podman storage/network

#### Summary output
- [x] Print: platform, nanoclaw commit, nanoclaw directory, image tag
- [x] Print: "Next: run `examples/run-nanoclaw.sh` to start"

### Flags

| Flag | Default | Description |
|---|---|---|
| `--nanoclaw-dir <path>` | `~/nanoclaw` | Where to clone/find nanoclaw |
| `--commit <hash>` | Hardcoded default | Nanoclaw commit to pin to |
| `--non-interactive` | Off | Skip prompts, require env vars or existing `.env` |
| `-h` / `--help` | — | Print usage |

### Error handling
- All prerequisite failures must be clear and actionable
- Script must be idempotent: running twice should succeed without side effects
- Use `set -euo pipefail` for strict error handling
- Log to stdout (not a file) — keep it simple for MVP

---

## 1.2 — `scripts/build-agent-image.sh`

Build the nanoclaw agent container image using Podman.

### Behavior

```
build-agent-image.sh [--nanoclaw-dir <path>] [--tag <tag>]
```

### Checklist

- [x] Accept `--nanoclaw-dir` (default: `~/nanoclaw`) and `--tag` (default: `latest`)
- [x] Verify nanoclaw directory exists and contains `container/Dockerfile`
- [ ] Set `CONTAINER_RUNTIME=podman` (nanoclaw's `build.sh` respects this) — N/A: we call `podman build` directly, not nanoclaw's `build.sh`
- [x] Run: `podman build -t nanoclaw-agent:${TAG} ./container/` from the nanoclaw dir
- [x] Print image size after build: `podman image inspect nanoclaw-agent:${TAG} --format '{{.Size}}'`
- [x] Print: `Image built: nanoclaw-agent:${TAG}`
- [x] Handle build failure: print Podman error, suggest checking `container/Dockerfile`
- [x] Idempotent: rebuilds replace existing image

### Design notes
- This is a thin wrapper. Nanoclaw's `container/Dockerfile` does the real work.
- We don't create our own Dockerfile — nanoclaw's is the source of truth.
- The `CONTAINER_RUNTIME=podman` env var makes nanoclaw's own `build.sh` use Podman, but we call `podman build` directly for clarity and control.

---

## 1.3 — `examples/env.example`

Annotated `.env` template for nanoclaw configuration.

### Checklist

- [x] Document every env var nanoclaw reads (from `src/config.ts` and `src/env.ts`)
- [x] Group by category: credentials, assistant config, container config, advanced
- [x] Include inline comments explaining each var
- [x] Credential section:
  - [x] `ANTHROPIC_API_KEY=` — with comment: required if not using OAuth
  - [x] `CLAUDE_CODE_OAUTH_TOKEN=` — with comment: alternative to API key
- [x] Assistant config:
  - [x] `ASSISTANT_NAME=Andy` — trigger word for the assistant
  - [x] `ASSISTANT_HAS_OWN_NUMBER=false` — whether assistant has dedicated phone number
- [x] Container config:
  - [x] `CONTAINER_IMAGE=nanoclaw-agent:latest` — agent container image
  - [x] `CONTAINER_TIMEOUT=1800000` — 30 min default, in ms
  - [x] `IDLE_TIMEOUT=1800000` — 30 min idle before container teardown
  - [x] `CONTAINER_MAX_OUTPUT_SIZE=10485760` — 10MB output cap
- [x] Mark required vs optional vars clearly
- [x] Include a header comment: "Copy to nanoclaw/.env and fill in required values"

---

## 1.4 — `examples/run-nanoclaw.sh`

Start the nanoclaw host process.

### Behavior

```
run-nanoclaw.sh [--nanoclaw-dir <path>]
```

### Checklist

#### Pre-flight checks
- [x] Verify nanoclaw directory exists
- [x] Verify `dist/index.js` exists (TypeScript has been compiled)
- [x] Verify `.env` exists and is non-empty
- [x] Verify `nanoclaw-agent:latest` image exists (`podman image exists nanoclaw-agent:latest`)
- [x] Verify `podman` and `docker` (shim) are functional
- [x] If any check fails: print specific error and remediation

#### Start process
- [x] `cd` to nanoclaw directory
- [x] Run `node dist/index.js` (foreground) — uses `exec` for clean signal handling
- [ ] Alternatively: document `npm start` as equivalent — deferred to Phase 2 docs
- [x] Print: "Starting nanoclaw host process..."
- [x] Print: "Press Ctrl+C to stop"
- [x] On first run, nanoclaw will launch WhatsApp QR auth — documented in output

#### Design notes
- This is intentionally simple — just start the process
- No daemonization, no systemd service — out of scope for this repo
- The user runs it in a terminal and watches the output
- Multiple instances: user opens multiple terminals with different `--nanoclaw-dir` paths

---

## 1.5 — `tests/smoke.sh`

End-to-end validation that the setup works.

### Behavior

```
smoke.sh [--nanoclaw-dir <path>]
```

### Checklist

#### Image build test
- [x] Call `build-agent-image.sh`
- [x] Assert exit code 0
- [x] Assert `podman image exists nanoclaw-agent:latest` succeeds

#### Container run test
- [x] Construct minimal test input JSON (prompt, groupFolder, chatJid, isMain, assistantName, secrets)
- [x] Note: this test requires a valid `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` — documented in help and runtime output
- [x] Create temp directory for group workspace mount
- [x] Run the agent container with correct mounts
- [x] Capture stdout and stderr
- [x] Assert stdout contains `---NANOCLAW_OUTPUT_START---`
- [x] Assert stdout contains `---NANOCLAW_OUTPUT_END---`
- [x] Extract JSON between sentinels, assert `status` is `success`

#### Cleanup
- [x] Remove temp directory (via `trap cleanup EXIT`)
- [x] Remove any leftover containers (defensive `podman rm -f` in cleanup)
- [x] Print pass/fail summary

#### Credential-free mode
- [x] If no API key is available, run a simpler test:
  - [x] Just verify the container starts and the entrypoint script runs
  - [x] Print: "PARTIAL PASS — container starts but no API key for full test"

### Test output format
```
[PASS] Agent image builds successfully
[PASS] Container starts and runs entrypoint
[PASS] Agent responds with valid sentinel-wrapped JSON
[PASS] Response status is 'success'

Smoke test: 4/4 passed
```

---

## Implementation order

Execute in this order, as each step builds on the previous:

```
1.3  env.example          (no dependencies, pure documentation)
 ↓
1.2  build-agent-image.sh (needs nanoclaw cloned, but is self-contained)
 ↓
1.1  setup-host.sh        (calls build-agent-image.sh, creates .env from env.example)
 ↓
1.4  run-nanoclaw.sh      (needs setup-host.sh to have run)
 ↓
1.5  smoke.sh             (needs everything above)
```

## Open questions for Phase 1

- [ ] **Which nanoclaw commit to pin?** Need to test current `main` (as of Feb 2026) and confirm it works with Podman through the shim. Pick the latest known-good commit. `setup-host.sh` currently defaults to `main` — update `DEFAULT_NANOCLAW_COMMIT` once a hash is validated.
- [ ] **Smoke test API key requirement:** Full smoke test needs a real API key. Should we require this, or is the credential-free partial test sufficient for CI? Current implementation: `smoke.sh` supports both modes — full test with API key, partial (container-starts) test without.
- [x] **WhatsApp auth on first run:** Nanoclaw's first startup requires scanning a QR code. Documented in `run-nanoclaw.sh` output and in `setup-host.sh` summary.
- [x] **Node.js installation:** Decided: `setup-host.sh` errors with instructions pointing to nodejs.org. Does not attempt to install Node.js (too many variants: nvm, nodesource, distro package).
