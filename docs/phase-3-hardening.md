# Phase 3: Hardening & Validation

**Goal:** Prove the Docker→Podman compatibility actually works, add security hardening flags, and catalog every issue encountered into a troubleshooting guide.

**Entry criteria:** Phase 1 scripts work. Phase 2 docs drafted (security and parallel docs inform this phase's testing).

**Exit criteria:** Automated compatibility test passes. Security-hardened run config validated. Troubleshooting doc covers every issue found during testing.

---

## 3.1 — `scripts/verify-podman-compat.sh`

Automated test of every Docker CLI pattern nanoclaw uses, run through the `podman-docker` shim.

### Behavior

```
verify-podman-compat.sh [--verbose]
```

Runs a series of Docker CLI commands that nanoclaw's source code uses, verifies each one works through the Podman shim, and reports pass/fail.

### Checklist

#### Test setup
- [ ] Verify `docker` (shim) is on PATH
- [ ] Verify `podman` is functional
- [ ] Build a minimal test image if needed (or use `docker.io/library/alpine:latest`)
- [ ] Create temp directory for test mounts
- [ ] Trap EXIT to clean up containers, images, temp dirs

#### Test cases (one per Docker CLI pattern nanoclaw uses)

Every test case must:
- [ ] Print what's being tested
- [ ] Run the command
- [ ] Assert expected behavior
- [ ] Print `[PASS]` or `[FAIL]` with details

**Core container lifecycle:**
- [ ] `docker build -t test-image:latest .` — image build from Dockerfile
- [ ] `docker run -i --rm --name test-container <image>` — interactive ephemeral run
- [ ] `docker run -i --rm --name test-container <image> < input.txt` — stdin piping
- [ ] `docker stop test-container` — graceful stop by name
- [ ] `docker ps --filter name=nanoclaw --format '{{.Names}}'` — filter + format

**Bind mounts:**
- [ ] `docker run -v /host/path:/container/path <image>` — basic rw bind mount
- [ ] `docker run -v /host/path:/container/path:ro <image>` — read-only bind mount
- [ ] Verify host file is visible inside container
- [ ] Verify read-only mount rejects writes

**Environment and user:**
- [ ] `docker run -e KEY=VALUE <image>` — environment variable passing
- [ ] `docker run -e TZ=America/New_York <image>` — timezone (nanoclaw does this)
- [ ] `docker run --user 1000:1000 <image>` — non-root user execution
- [ ] Verify uid/gid inside container matches

**Resource limits:**
- [ ] `docker run --cpus=2 <image>` — CPU limit accepted
- [ ] `docker run --memory=4g <image>` — memory limit accepted
- [ ] `docker run --pids-limit=256 <image>` — PID limit accepted

**Image management:**
- [ ] `docker image inspect <image> --format '{{.Size}}'` — image inspection
- [ ] `docker info` — runtime info (used by nanoclaw startup check)
- [ ] `docker ps --filter` with `label=` filter — orphan cleanup pattern

**Nanoclaw-specific pattern:**
- [ ] Full integration test: build nanoclaw's actual `container/Dockerfile`, run with the same flags `container-runner.ts` uses, pipe JSON to stdin, verify sentinel markers in stdout
- [ ] This is the most important test — it validates the real invocation path

#### Output format
```
Docker→Podman Compatibility Tests
==================================

Image operations:
  [PASS] docker build
  [PASS] docker image inspect

Container lifecycle:
  [PASS] docker run -i --rm
  [PASS] docker run with stdin piping
  [PASS] docker stop
  [PASS] docker ps --filter

Bind mounts:
  [PASS] Read-write bind mount
  [PASS] Read-only bind mount

Environment and user:
  [PASS] Environment variable passing
  [PASS] Timezone environment variable
  [PASS] --user flag

Resource limits:
  [PASS] --cpus
  [PASS] --memory
  [PASS] --pids-limit

Nanoclaw integration:
  [PASS] Full agent container invocation

Results: 14/14 passed
```

#### Edge cases to watch for
- [ ] Mount path with spaces
- [ ] Container name with timestamp (nanoclaw pattern: `nanoclaw-<group>-<ts>`)
- [ ] Multiple simultaneous containers (parallel run test)
- [ ] Container output larger than 10MB (`CONTAINER_MAX_OUTPUT_SIZE`)
- [ ] Container timeout behavior (force kill after timeout)

---

## 3.2 — Security hardening flags

Add security flags to the agent container run configuration and validate they don't break nanoclaw.

### Checklist

#### Flags to add

Each flag must be tested individually (enable, run smoke test, verify pass) then all together:

- [ ] `--read-only` — make root filesystem read-only
  - Nanoclaw's entrypoint writes to `/tmp/dist/` (TypeScript compilation output)
  - Nanoclaw's entrypoint writes `/tmp/input.json` (stdin JSON)
  - Needs `--tmpfs /tmp` to work
  - Test: agent can still compile and run

- [ ] `--tmpfs /tmp:rw,size=512m,mode=1777` — writable tmpfs at /tmp
  - Required companion to `--read-only`
  - Size 512MB should be sufficient for TypeScript compilation + temp files
  - Test: compilation succeeds, agent can write temp files

- [ ] `--cap-drop=ALL` — drop all Linux capabilities
  - Rootless Podman already has minimal caps, but this makes it explicit
  - Test: agent runs normally (Claude Agent SDK doesn't need capabilities)
  - Watch for: Chromium might need some caps for sandboxing
  - If Chromium breaks: try `--cap-add=SYS_CHROOT` (Chromium sandbox)

- [ ] `--security-opt=no-new-privileges` — prevent setuid/setgid escalation
  - Prevents any binary from gaining privileges via setuid bit
  - Should be safe — agent runs as `node` user, no setuid binaries expected
  - Test: agent runs normally

- [ ] `--security-opt=seccomp=unconfined` — NOT recommended, just document
  - Only if Podman's default seccomp profile causes issues
  - Default profile is good — document that we trust it

#### Testing protocol

For each flag:
1. [ ] Add flag to the `podman run` / `docker run` command
2. [ ] Run smoke test (`tests/smoke.sh`)
3. [ ] If smoke test fails: identify which operation broke, document finding
4. [ ] If broken: determine if flag is compatible with workaround, or must be dropped
5. [ ] Document result in `docs/SECURITY.md` flag table

After all flags tested individually:
6. [ ] Enable ALL compatible flags together
7. [ ] Run smoke test
8. [ ] Run `verify-podman-compat.sh` full integration test
9. [ ] Document the final recommended flag set

#### Chromium sandbox consideration
- [ ] Chromium uses its own sandboxing (seccomp, namespaces)
- [ ] Inside a rootless Podman container, Chromium's sandbox may not work
- [ ] Nanoclaw's Dockerfile sets `AGENT_BROWSER_EXECUTABLE_PATH` — check if it also sets `--no-sandbox`
- [ ] If Chromium sandbox fails: document the fix (either `--no-sandbox` flag in Chromium launch or `--cap-add=SYS_CHROOT`)
- [ ] This is a known issue in containerized Chromium — likely already handled by nanoclaw's image

#### Where flags live
- [ ] Document the recommended flag set in `docs/SECURITY.md`
- [ ] Apply the flags in `examples/run-nanoclaw.sh` (as comments showing how to enable)
- [ ] Note: nanoclaw's host process controls the `docker run` command in `container-runner.ts` — these flags would need to be added there in a fork, or we document "these are recommended but require modifying nanoclaw"
- [ ] **Key decision:** Can we inject these flags without modifying nanoclaw?
  - Option A: `DOCKER_DEFAULT_OPTS` or similar env-level injection — investigate if Podman/docker shim supports this
  - Option B: Podman's `containers.conf` can set default security options — investigate
  - Option C: Fork nanoclaw and modify `container-runner.ts` directly
  - Document whichever approach works

---

## 3.3 — `docs/TROUBLESHOOTING.md`

Catalog of every issue encountered during development and testing.

### Structure

```
# Troubleshooting

## Quick reference table
## Podman / container issues
## Nanoclaw issues
## WSL2-specific issues
## Bare-metal-specific issues
## Security hardening issues
```

### Checklist

#### Quick reference table
- [ ] Top-level table: symptom → fix (one-liner each), with link to detailed section
- [ ] Sorted by frequency / likelihood

#### Issues to document (known from research + anticipated)

**Podman / container issues:**
- [ ] `docker: command not found` → install `podman-docker` package
- [ ] `docker info` fails → enable `podman.socket` (step 6), check `DOCKER_HOST`
- [ ] `rootless=false` → don't run with sudo, check subuid/subgid
- [ ] Container fails to start: "permission denied" → check `/` mount propagation (`shared` vs `private`)
- [ ] Bind mount empty inside container → WSL2 mount propagation issue, need `mount --make-rshared /`
- [ ] Image build fails: network error → check Podman networking (passt vs slirp4netns)
- [ ] Image build fails: disk space → `podman system prune`, check WSL2 vhdx size
- [ ] `podman stats` shows 0% CPU → cgroup v1 vs v2 issue

**Nanoclaw issues:**
- [ ] WhatsApp QR code not appearing → check `store/auth/` permissions, rerun
- [ ] Agent container exits immediately → check API key in `.env`, run container manually with `docker run -it`
- [ ] `CONTAINER_RUNTIME_BIN` is `docker` → expected, `podman-docker` shim handles this
- [ ] `npm ci` fails → check Node.js version (need 22+), check `package-lock.json` integrity
- [ ] TypeScript compilation fails inside container → verify agent-runner deps installed
- [ ] Timeout: agent killed after 30 min → increase `CONTAINER_TIMEOUT` env var

**WSL2-specific:**
- [ ] WSL2 consuming too much memory → set `.wslconfig` memory limit, `wsl --shutdown` to reclaim
- [ ] Podman socket not starting → systemd not enabled in WSL, check `/etc/wsl.conf`
- [ ] Slow I/O on bind mounts from Windows → use native Linux paths (`~/`) not `/mnt/c/`
- [ ] `wsl -d <distro>` opens in `/mnt/c/Users/<user>` → `cd ~` first, clone repos in home dir

**Bare-metal-specific:**
- [ ] Podman not in default Ubuntu repos (older versions) → use kubic repo or upgrade Ubuntu
- [ ] `passt` not available → Ubuntu < 23.04, falls back to `slirp4netns` (slower networking)

**Security hardening:**
- [ ] `--read-only` breaks agent → add `--tmpfs /tmp`
- [ ] `--cap-drop=ALL` breaks Chromium → add `--cap-add=SYS_CHROOT` or use `--no-sandbox`
- [ ] `--security-opt=no-new-privileges` breaks nothing (document for confidence)

#### Format per issue
Each issue should follow this template:
```markdown
### <Symptom as the user would describe it>
**Error:** <exact error message or behavior>
**Cause:** <one-line root cause>
**Fix:**
<exact commands to resolve>
**Prevention:** <optional — how to avoid this>
```

---

## 3.4 — `examples/wslconfig.example`

Template `.wslconfig` for WSL2 users with resource guidance.

### Checklist

- [ ] File format: INI with comments
- [ ] Header comment explaining what this is and where to put it (`%UserProfile%/.wslconfig`)
- [ ] `[wsl2]` section with:
  - [ ] `memory=` — with formula in comment
  - [ ] `swap=` — recommended 2-4GB
  - [ ] `processors=` — with formula in comment
- [ ] Multiple commented examples:
  - [ ] 1 container config (minimal — 6GB RAM, 4 CPUs)
  - [ ] 2 container config (10GB RAM, 6 CPUs)
  - [ ] 4 container config (20GB RAM, 10 CPUs)
- [ ] Note: requires `wsl --shutdown` to take effect
- [ ] Note: WSL2 doesn't release memory back to Windows until shutdown
- [ ] Note: default WSL2 memory is 50% of host RAM — set explicitly if running agents

---

## Implementation order

```
3.1  verify-podman-compat.sh  (validates Phase 1 works, finds issues)
 ↓
3.2  Security hardening        (test flags, feeds into SECURITY.md and TROUBLESHOOTING.md)
 ↓
3.3  TROUBLESHOOTING.md       (captures everything found in 3.1 and 3.2)
 ↓
3.4  wslconfig.example        (standalone, no dependencies)
```

## Open questions for Phase 3

- [ ] **Security flag injection:** Can we apply hardening flags without modifying nanoclaw's `container-runner.ts`? Need to investigate Podman's `containers.conf` default security options, or whether the `podman-docker` shim respects `DOCKER_DEFAULT_OPTS` or similar. This determines whether hardening is "enable by editing a config file" or "requires a nanoclaw fork."
- [ ] **Chromium in rootless containers:** This is a known pain point. Need to test whether nanoclaw's Dockerfile already handles Chromium sandbox issues (likely sets `--no-sandbox` via `AGENT_BROWSER_EXECUTABLE_PATH` or Playwright config).
- [ ] **Parallel container test:** Should `verify-podman-compat.sh` include a test that runs 2+ containers simultaneously? This validates that rootless Podman handles concurrent containers correctly (namespace isolation, port conflicts, etc.).
