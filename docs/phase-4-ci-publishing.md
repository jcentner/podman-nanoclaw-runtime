# Phase 4: CI & Publishing

**Goal:** Automate quality gates (image builds, smoke tests) so the repo stays healthy as nanoclaw evolves, and polish for public release.

**Entry criteria:** Phases 1–3 complete. Scripts work, docs are written, security hardening validated.

**Exit criteria:** CI pipeline passes on every push/PR. README has badges. Repo is ready for public visibility.

---

## 4.1 — `.github/workflows/ci.yml`

Continuous integration pipeline that builds the agent image and runs validation on every push and PR.

### Behavior

Triggers on:
- Push to `main`
- Pull requests targeting `main`

### Checklist

#### Workflow structure
```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps: ...
```

#### Job steps

**Environment setup:**
- [ ] Runner: `ubuntu-latest` (Ubuntu 22.04/24.04 on GitHub Actions)
- [ ] Install Podman (should be pre-installed on ubuntu-latest; verify version)
- [ ] Install `podman-docker` package
- [ ] Verify rootless Podman works: `podman info --format '{{.Host.Security.Rootless}}'`
- [ ] Install Node.js 22 via `actions/setup-node@v4`
- [ ] Cache: consider caching Podman image layers (investigate `actions/cache` with Podman storage path)

**Nanoclaw setup:**
- [ ] Clone nanoclaw at pinned commit (same commit as `setup-host.sh` default)
- [ ] `npm ci` for host + agent-runner
- [ ] Should NOT require API keys — CI runs without credentials

**Image build:**
- [ ] Run `scripts/build-agent-image.sh`
- [ ] Assert exit code 0
- [ ] Assert image exists: `podman image exists nanoclaw-agent:latest`
- [ ] Record image size in job output (for tracking bloat over time)

**Compatibility test:**
- [ ] Run `scripts/verify-podman-compat.sh`
- [ ] Assert exit code 0
- [ ] All Docker→Podman compatibility tests pass

**Smoke test (credential-free):**
- [ ] Run `tests/smoke.sh` in credential-free mode
- [ ] Assert: container builds, starts, entrypoint runs, TypeScript compiles
- [ ] Skip: the full agent invocation (needs API key)
- [ ] This validates the container and entrypoint, not the Claude Agent SDK

**Shellcheck:**
- [ ] Run `shellcheck` on all `.sh` files in the repo
- [ ] Use `.shellcheckrc` for project-wide settings
- [ ] Fail the build on any shellcheck error

#### Optional: full smoke test with secrets
- [ ] Create a separate workflow or manual trigger for full smoke test
- [ ] Uses GitHub Actions secrets for `ANTHROPIC_API_KEY`
- [ ] Runs the complete smoke test including agent invocation
- [ ] Triggered manually or on release tags (not every push — costs money per API call)

#### CI considerations
- [ ] GitHub Actions ubuntu-latest has Podman pre-installed but may be an older version
- [ ] Rootless Podman on GitHub Actions: may need `systemd` setup or work without socket
- [ ] `podman-docker` may not be pre-installed — add `sudo apt-get install -y podman-docker`
- [ ] Container builds can be slow on free-tier runners (~5-10 min for nanoclaw's Dockerfile)
- [ ] Consider adding a timeout to the workflow (e.g., 20 minutes)

### Example workflow skeleton

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    timeout-minutes: 20

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install podman-docker
        run: sudo apt-get update && sudo apt-get install -y podman-docker

      - name: Verify Podman
        run: |
          podman --version
          podman info --format '{{.Host.Security.Rootless}}'
          docker info  # via shim

      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: '22'

      - name: Clone nanoclaw
        run: |
          # Uses the same pinned commit as setup-host.sh
          source scripts/setup-host.sh --print-commit  # or extract commit var
          git clone https://github.com/qwibitai/nanoclaw.git /tmp/nanoclaw
          cd /tmp/nanoclaw
          git checkout "$NANOCLAW_COMMIT"

      - name: Install nanoclaw deps
        run: |
          cd /tmp/nanoclaw
          npm ci
          cd container/agent-runner && npm ci

      - name: Build agent image
        run: scripts/build-agent-image.sh --nanoclaw-dir /tmp/nanoclaw

      - name: Run compatibility tests
        run: scripts/verify-podman-compat.sh

      - name: Run smoke test (credential-free)
        run: tests/smoke.sh --nanoclaw-dir /tmp/nanoclaw --no-credentials

      - name: Shellcheck
        run: |
          sudo apt-get install -y shellcheck
          find . -name '*.sh' -not -path './podman-wsl-setup/*' | xargs shellcheck
```

---

## 4.2 — Version pinning documentation

Document the nanoclaw commit pinning strategy clearly for maintainers.

### Checklist

#### Add a dedicated section to README
- [ ] "Nanoclaw version" section explaining:
  - This repo pins to a specific nanoclaw commit hash
  - The current pinned commit: `<hash>` (date, description)
  - Why: nanoclaw has no release tags; pinning ensures reproducibility

#### Document the bump procedure
- [ ] Step-by-step process:
  1. Check nanoclaw's latest main: `git log --oneline -5 origin/main`
  2. Review changes since current pin: `git log --oneline <current>..<new>`
  3. Update the commit hash in `scripts/setup-host.sh`
  4. Run full test suite: `build-agent-image.sh` + `verify-podman-compat.sh` + `smoke.sh`
  5. If tests pass: commit the hash update with message "chore: bump nanoclaw to <short-hash>"
  6. If tests fail: investigate breaking changes, fix or stay on current pin

#### Track pinned version in a single location
- [ ] Define `NANOCLAW_COMMIT` in one place (sourced by all scripts)
- [ ] Options:
  - A small `nanoclaw-version.env` file at repo root
  - A variable at the top of `setup-host.sh` (simpler, fewer files)
  - Recommendation: `nanoclaw-version.env` — easy to find, easy to change, easy to source
- [ ] CI workflow must use the same commit

#### Version file format (`nanoclaw-version.env`)
```bash
# Pinned nanoclaw version
# Bump by updating the commit hash and running the full test suite
# Last verified: 2026-02-24
NANOCLAW_COMMIT=abc1234def5678
NANOCLAW_COMMIT_DATE=2026-02-24
NANOCLAW_COMMIT_DESC="chore: bump version to 1.1.2"
```

---

## 4.3 — README polish & release prep

Final touches to make the repo presentable as a public utility.

### Checklist

#### Badges
- [ ] CI status badge: `[![CI](https://github.com/jcentner/podman-nanoclaw-runtime/actions/workflows/ci.yml/badge.svg)](link)`
- [ ] License badge: `[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](link)`
- [ ] Place badges immediately below the title

#### License
- [ ] Create `LICENSE` file (MIT, matching nanoclaw's license)
- [ ] Add license section to README

#### .gitignore
- [ ] Standard entries: `node_modules/`, `.env`, `*.log`
- [ ] Nanoclaw-specific: don't track the nanoclaw clone directory itself
- [ ] Podman-wsl-setup subdir (if it stays as a clone for development): `podman-wsl-setup/`

#### .shellcheckrc
- [ ] Create project-level shellcheck config
- [ ] Match podman-wsl-setup's style: `disable=SC1091`
- [ ] Add any project-specific suppressions found during Phase 3

#### Contributing guidelines
- [ ] Keep it brief — this is a utility, not a framework
- [ ] "Issues welcome. PRs for bug fixes + security improvements accepted."
- [ ] "For feature requests: open an issue to discuss first."
- [ ] "All shell scripts must pass shellcheck."

#### Final README review
- [ ] Read through as a first-time user
- [ ] Every command in quickstart must be copy-pasteable
- [ ] Every prerequisite has a verification command
- [ ] No broken links
- [ ] No references to internal notes or planning docs
- [ ] No references to internal notes or private planning docs

#### Repo cleanup
- [ ] Verify `.local/` directory (private local files) is gitignored
- [ ] Review `PLAN.md` — keep as-is (useful for contributors) or move to `docs/`
- [ ] Verify repo structure matches PLAN.md's proposed layout

---

## Implementation order

```
4.1  CI workflow         (automates validation, catches regressions immediately)
 ↓
4.2  Version pinning     (needed for CI to know which commit to use)
 ↓
4.3  README polish       (final pass after everything works end-to-end)
```

Note: 4.1 and 4.2 are somewhat interdependent (CI needs the pinned commit, version doc needs CI to exist). Start with a basic CI that hardcodes the commit, then extract to `nanoclaw-version.env` as part of 4.2.

## Open questions for Phase 4

- [ ] **Podman on GitHub Actions runners:** Need to verify the exact Podman version on `ubuntu-latest` and whether rootless works out of the box. GitHub's runner images have Podman pre-installed, but rootless mode may need `podman system migrate` or other setup. Test this early.
- [ ] **Image caching in CI:** Building nanoclaw's agent image takes 5-10 minutes (Chromium install is heavy). Can we cache Podman image layers between CI runs? Investigate `actions/cache` with `~/.local/share/containers/storage/`.

