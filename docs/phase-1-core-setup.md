# Phase 1: Core Setup Scripts (MVP)

**Goal:** Get a single nanoclaw instance running on Podman — from zero to working agent in one session.

**Entry criteria:** User has a working rootless Podman installation with `podman-docker` shim (via podman-wsl-setup on WSL2, or manual setup on bare-metal).

**Exit criteria:** User can run `setup-host.sh`, then `build-agent-image.sh`, then `run-nanoclaw.sh`, and interact with a nanoclaw agent through WhatsApp (or headless mode). Smoke test passes.

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
- [ ] Detect WSL2 via `/proc/version` containing `microsoft` (case-insensitive)
- [ ] Detect bare-metal Linux via absence of WSL markers
- [ ] Print platform summary: `Running on: Ubuntu 24.04 (WSL2)` or `Running on: Ubuntu 24.04 (bare-metal)`
- [ ] Detect Ubuntu version from `/etc/os-release`, warn if < 23.04

#### Prerequisite validation
- [ ] Check `podman` exists on PATH
- [ ] Check `podman info` succeeds and reports `rootless=true`
- [ ] Check `docker` exists on PATH (podman-docker shim)
- [ ] Check `docker info` succeeds (verifies shim + socket are working)
- [ ] Check `node --version` reports v22+
- [ ] Check `npm` exists on PATH
- [ ] Check `git` exists on PATH
- [ ] If any check fails: print clear error with remediation steps, exit non-zero
- [ ] On WSL2: suggest podman-wsl-setup if Podman checks fail
- [ ] On bare-metal: suggest `apt install podman podman-docker` if checks fail

#### Nanoclaw clone
- [ ] Default clone location: `~/nanoclaw` (configurable via `--nanoclaw-dir`)
- [ ] If directory exists and is a git repo: fetch + checkout pinned commit
- [ ] If directory exists and is NOT a git repo: error with guidance
- [ ] If directory does not exist: `git clone https://github.com/qwibitai/nanoclaw.git`
- [ ] Checkout pinned commit: `git checkout $NANOCLAW_COMMIT`
- [ ] Default commit hash: hardcoded in script (document how to determine a good commit)
- [ ] Override via `--commit <hash>` or `NANOCLAW_COMMIT` env var
- [ ] Print: `Nanoclaw pinned to commit: <short-hash> (<date>)`

#### Dependency installation
- [ ] `cd` into nanoclaw directory
- [ ] Run `npm ci` for the host process (root `package.json`)
- [ ] Run `npm ci` for the agent-runner (`container/agent-runner/package.json`)
- [ ] Run `npm run build` to compile TypeScript (host process)
- [ ] Handle failure: print npm error output, suggest `node --version` check

#### `.env` configuration
- [ ] Check if `.env` already exists in nanoclaw dir
- [ ] If exists: skip creation, print "Using existing .env"
- [ ] If not: copy `env.example` from this repo into nanoclaw dir
- [ ] In interactive mode: prompt for `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`
- [ ] Validate that at least one credential is set (non-empty)
- [ ] Prompt for `ASSISTANT_NAME` (default: `Andy`)
- [ ] In non-interactive mode: expect env vars to be pre-set or `.env` to exist already
- [ ] Never echo secrets to stdout

#### Agent image build
- [ ] Call `build-agent-image.sh` (from this repo's `scripts/`)
- [ ] Pass through the nanoclaw directory path
- [ ] If build fails: print error, suggest checking Podman storage/network

#### Summary output
- [ ] Print: platform, nanoclaw commit, nanoclaw directory, image tag
- [ ] Print: "Next: run `examples/run-nanoclaw.sh` to start"

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

- [ ] Accept `--nanoclaw-dir` (default: `~/nanoclaw`) and `--tag` (default: `latest`)
- [ ] Verify nanoclaw directory exists and contains `container/Dockerfile`
- [ ] Set `CONTAINER_RUNTIME=podman` (nanoclaw's `build.sh` respects this)
- [ ] Run: `podman build -t nanoclaw-agent:${TAG} ./container/` from the nanoclaw dir
- [ ] Print image size after build: `podman image inspect nanoclaw-agent:${TAG} --format '{{.Size}}'`
- [ ] Print: `Image built: nanoclaw-agent:${TAG}`
- [ ] Handle build failure: print Podman error, suggest checking `container/Dockerfile`
- [ ] Idempotent: rebuilds replace existing image

### Design notes
- This is a thin wrapper. Nanoclaw's `container/Dockerfile` does the real work.
- We don't create our own Dockerfile — nanoclaw's is the source of truth.
- The `CONTAINER_RUNTIME=podman` env var makes nanoclaw's own `build.sh` use Podman, but we call `podman build` directly for clarity and control.

---

## 1.3 — `examples/env.example`

Annotated `.env` template for nanoclaw configuration.

### Checklist

- [ ] Document every env var nanoclaw reads (from `src/config.ts` and `src/env.ts`)
- [ ] Group by category: credentials, assistant config, container config, advanced
- [ ] Include inline comments explaining each var
- [ ] Credential section:
  - [ ] `ANTHROPIC_API_KEY=` — with comment: required if not using OAuth
  - [ ] `CLAUDE_CODE_OAUTH_TOKEN=` — with comment: alternative to API key
- [ ] Assistant config:
  - [ ] `ASSISTANT_NAME=Andy` — trigger word for the assistant
  - [ ] `ASSISTANT_HAS_OWN_NUMBER=false` — whether assistant has dedicated phone number
- [ ] Container config:
  - [ ] `CONTAINER_IMAGE=nanoclaw-agent:latest` — agent container image
  - [ ] `CONTAINER_TIMEOUT=1800000` — 30 min default, in ms
  - [ ] `IDLE_TIMEOUT=1800000` — 30 min idle before container teardown
  - [ ] `CONTAINER_MAX_OUTPUT_SIZE=10485760` — 10MB output cap
- [ ] Mark required vs optional vars clearly
- [ ] Include a header comment: "Copy to nanoclaw/.env and fill in required values"

---

## 1.4 — `examples/run-nanoclaw.sh`

Start the nanoclaw host process.

### Behavior

```
run-nanoclaw.sh [--nanoclaw-dir <path>]
```

### Checklist

#### Pre-flight checks
- [ ] Verify nanoclaw directory exists
- [ ] Verify `dist/index.js` exists (TypeScript has been compiled)
- [ ] Verify `.env` exists and is non-empty
- [ ] Verify `nanoclaw-agent:latest` image exists (`podman image exists nanoclaw-agent:latest`)
- [ ] Verify `podman` and `docker` (shim) are functional
- [ ] If any check fails: print specific error and remediation

#### Start process
- [ ] `cd` to nanoclaw directory
- [ ] Run `node dist/index.js` (foreground)
- [ ] Alternatively: document `npm start` as equivalent
- [ ] Print: "Starting nanoclaw host process..."
- [ ] Print: "Press Ctrl+C to stop"
- [ ] On first run, nanoclaw will launch WhatsApp QR auth — document this

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
- [ ] Call `build-agent-image.sh`
- [ ] Assert exit code 0
- [ ] Assert `podman image exists nanoclaw-agent:latest` succeeds

#### Container run test
- [ ] Construct minimal test input JSON:
  ```json
  {
    "prompt": "Reply with exactly: SMOKE_TEST_OK",
    "groupFolder": "smoke-test",
    "chatJid": "smoke@test",
    "isMain": false,
    "assistantName": "SmokeTest"
  }
  ```
- [ ] Note: this test requires a valid `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN` — document this
- [ ] Create temp directory for group workspace mount
- [ ] Run the agent container with correct mounts:
  ```bash
  echo '<input_json>' | podman run -i --rm \
    --name nanoclaw-smoke-test \
    -v "$TEMP_DIR:/workspace/group" \
    nanoclaw-agent:latest
  ```
- [ ] Capture stdout and stderr
- [ ] Assert exit code 0
- [ ] Assert stdout contains `---NANOCLAW_OUTPUT_START---`
- [ ] Assert stdout contains `---NANOCLAW_OUTPUT_END---`
- [ ] Extract JSON between sentinels, assert `status` is `success`

#### Cleanup
- [ ] Remove temp directory
- [ ] Remove any leftover containers (shouldn't exist with `--rm`, but defensive)
- [ ] Print pass/fail summary

#### Credential-free mode
- [ ] If no API key is available, run a simpler test:
  - [ ] Just verify the container starts and the entrypoint script runs
  - [ ] Assert the TypeScript compilation step succeeds (exit before agent SDK call)
  - [ ] Print: "PARTIAL PASS — container starts but no API key for full test"

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

- [ ] **Which nanoclaw commit to pin?** Need to test current `main` (as of Feb 2026) and confirm it works with Podman through the shim. Pick the latest known-good commit.
- [ ] **Smoke test API key requirement:** Full smoke test needs a real API key. Should we require this, or is the credential-free partial test sufficient for CI?
- [ ] **WhatsApp auth on first run:** Nanoclaw's first startup requires scanning a QR code. Document this prominently in `run-nanoclaw.sh` output. For headless use, nanoclaw supports headless mode — document as an alternative.
- [ ] **Node.js installation:** Should `setup-host.sh` install Node.js if missing, or just error? Recommendation: error with instructions. Installing Node.js has too many variants (nvm, nodesource, distro package) to pick one safely.
