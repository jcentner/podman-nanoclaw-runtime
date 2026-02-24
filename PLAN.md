# podman-nanoclaw-runtime — Vision & Implementation Plan

**Current status:** Phase 1 — not started. No scripts or code exist yet; only planning docs.

## Vision

A public utility repo that makes it easy to run [nanoclaw](https://github.com/qwibitai/nanoclaw) AI agents securely in rootless Podman containers on Ubuntu — whether bare-metal, cloud VM, or WSL2.

The user experience: start with a working rootless Podman installation, run a setup script, and start working with isolated AI agents — no Docker Desktop, no root, no host exposure.

This repo targets **bare-metal Ubuntu** as the primary platform. WSL2 is a fully supported variant with additional documentation for Windows-specific concerns (`.wslconfig` memory limits, prerequisite Podman setup via [podman-wsl-setup](https://github.com/jcentner/podman-wsl-setup)).

## Scope

### What this repo does

- Sets up the nanoclaw host process on WSL2 (clone, install deps, configure)
- Builds the nanoclaw agent container image using Podman
- Provides run configurations with proper isolation, resource limits, and security hardening
- Documents the architecture, parallel usage, and resource planning
- Provides a smoke test to validate the setup

### What this repo does NOT do

- Modify nanoclaw's source code (out of scope)
- Implement an orchestrator or multi-instance management (out of scope)
- Replace podman-wsl-setup (that's a separate prerequisite)

## Architecture

```
Ubuntu Host (bare-metal, cloud VM, or WSL2)
├── Podman (rootless)
├── podman-docker shim (/usr/bin/docker → podman)
│
├── Nanoclaw Host Process (Node.js, runs directly on host)
│   ├── src/index.ts — orchestrator, message loop, agent invocation
│   ├── store/ — WhatsApp session state
│   ├── data/ — SQLite DB, session data
│   └── groups/ — per-group workspaces + CLAUDE.md memory
│
└── Agent Containers (spawned by host, ephemeral)
    ├── nanoclaw-agent:latest (Podman image)
    ├── One container per agent invocation (--rm)
    ├── Bind mounts: group workspace, IPC, sessions
    ├── Resource limits: --cpus, --memory, --pids-limit
    └── Runs as non-root node user (uid 1000)
```

On WSL2, the entire Ubuntu host sits inside a WSL2 VM, adding an additional isolation layer between the agents and the Windows host.

### Key boundaries

| Boundary | Isolation mechanism | Platform |
|---|---|---|
| Windows ↔ Linux | WSL2 VM (separate kernel, filesystem) | WSL2 only |
| Host ↔ Agent containers | Podman rootless containers (user namespaces, cgroups) | All |
| Agent ↔ Agent | Separate containers, separate mounts, ephemeral (`--rm`) | All |
| Agent ↔ Nanoclaw code | Project root mounted read-only | All |
| Agent ↔ Host secrets | Secrets passed via stdin JSON, never on disk in container | All |

### Entrypoint contract (host → agent container)

This is the stable interface between the host process and agent containers. It's defined by nanoclaw and must not be broken.

**Input:** JSON on stdin
```json
{
  "prompt": "string",
  "sessionId": "string (optional)",
  "groupFolder": "string",
  "chatJid": "string",
  "isMain": true|false,
  "isScheduledTask": true|false,
  "assistantName": "string",
  "secrets": { "CLAUDE_CODE_OAUTH_TOKEN": "...", "ANTHROPIC_API_KEY": "..." }
}
```

**Output:** JSON on stdout between sentinel markers
```
---NANOCLAW_OUTPUT_START---
{"status": "success"|"error", "result": "...", "newSessionId": "..."}
---NANOCLAW_OUTPUT_END---
```

**Exit codes:** 0 = success, non-zero = error

**Expected mounts:**
| Container path | Mode | Content |
|---|---|---|
| `/workspace/group` | rw | Group's working directory |
| `/workspace/project` | ro | Nanoclaw project root |
| `/workspace/ipc/messages` | rw | IPC: outbound messages |
| `/workspace/ipc/tasks` | rw | IPC: task scheduling |
| `/workspace/ipc/input` | rw | IPC: follow-up messages |
| `/home/node/.claude` | rw | Claude session data |
| `/app/src` | rw | Agent-runner source (per-group copy) |

## Prerequisites

### All platforms

1. **Ubuntu 23.04+** (24.04 LTS recommended)
2. **Rootless Podman** installed and verified (`podman info` reports `rootless=true`)
3. **`podman-docker`** package installed (provides `/usr/bin/docker` → `podman` shim)
4. **Node.js 22+** (nanoclaw requirement)
5. **Claude Code CLI** installed and authenticated
6. **API key**: `ANTHROPIC_API_KEY` or `CLAUDE_CODE_OAUTH_TOKEN`

### Bare-metal / cloud VM

Standard Ubuntu setup. Podman is available via `apt install podman podman-docker`. Rootless config (subuid/subgid) may already be done by the distro, or follow [Podman's rootless setup docs](https://podman.io/docs/installation#linux).

### WSL2

Use [podman-wsl-setup](https://github.com/jcentner/podman-wsl-setup) to handle WSL-specific quirks:
- Enables systemd (required for `podman.socket`)
- Fixes mount propagation (`mount --make-rshared /`)
- Installs Podman + rootless deps + `podman-docker` shim
- Configures subuid/subgid + optional Docker-compatible socket

`setup-host.sh` will detect the platform and guide accordingly.

## Docker → Podman compatibility

Nanoclaw hardcodes `docker` as its container runtime binary. This repo bridges that gap without modifying nanoclaw's source:

1. **`podman-docker` package** — provides `/usr/bin/docker` → `podman` shim (installed by podman-wsl-setup step 7)
2. **`podman.socket` + `DOCKER_HOST`** — Podman's systemd socket handles Docker API calls (installed by podman-wsl-setup step 6)

Together, nanoclaw's `docker run`, `docker stop`, `docker build`, and `docker ps` calls all transparently execute through Podman.

**Known flag compatibility to verify:**
- `docker run -i --rm --name <x>` — core invocation
- `docker run -v host:container:ro` — readonly bind mounts
- `docker run -e KEY=VALUE` — environment variables
- `docker run --user uid:gid` — non-root execution
- `docker build -t name:tag .` — image building
- `docker stop <name>` — graceful container stop
- `docker ps --filter` — orphan cleanup

## Repo structure

```
podman-nanoclaw-runtime/
├── PLAN.md                        # this document
├── README.md                      # user-facing quickstart + reference
│
├── scripts/
│   ├── setup-host.sh              # clone nanoclaw, install deps, configure .env
│   ├── build-agent-image.sh       # podman build of nanoclaw's agent image
│   └── verify-podman-compat.sh    # test Docker→Podman flag compatibility
│
├── examples/
│   ├── run-nanoclaw.sh            # start nanoclaw host process
│   ├── env.example                # template .env with annotated vars
│   └── wslconfig.example          # template .wslconfig with resource guidance
│
├── docs/
│   ├── ARCHITECTURE.md            # detailed architecture + scope boundary
│   ├── SECURITY.md                # hardening flags, threat model, limitations
│   ├── PARALLEL.md                # resource math, multi-instance guidance
│   └── TROUBLESHOOTING.md         # common issues + fixes
│
├── tests/
│   └── smoke.sh                   # build image, run trivial agent, assert output
│
└── .github/
    └── workflows/
        └── ci.yml                 # build image + smoke test on ubuntu-latest
```

## Implementation plan

Detailed checklists for each phase live in separate docs:

- [Phase 1: Core Setup Scripts (MVP)](docs/phase-1-core-setup.md) — `setup-host.sh`, `build-agent-image.sh`, `env.example`, `run-nanoclaw.sh`, `smoke.sh`
- [Phase 2: Documentation](docs/phase-2-documentation.md) — `README.md`, `ARCHITECTURE.md`, `SECURITY.md`, `PARALLEL.md`
- [Phase 3: Hardening & Validation](docs/phase-3-hardening.md) — `verify-podman-compat.sh`, security flags, `TROUBLESHOOTING.md`, `wslconfig.example`
- [Phase 4: CI & Publishing](docs/phase-4-ci-publishing.md) — GitHub Actions, version pinning, release prep

### Phase 1: Core setup scripts (MVP)

Get a single nanoclaw instance running on Podman in WSL2.

| Step | Deliverable | Description |
|---|---|---|
| 1.1 | `scripts/setup-host.sh` | Detect platform (bare-metal, cloud, WSL2). Validate prerequisites (Podman rootless, podman-docker shim, Node.js). Clone nanoclaw at a pinned commit. Install Node.js deps (`npm ci`). Create `.env` from template with guided prompts for API key. |
| 1.2 | `scripts/build-agent-image.sh` | Wrapper around `podman build` using nanoclaw's `container/Dockerfile`. Tags as `nanoclaw-agent:latest`. Supports custom tag arg. |
| 1.3 | `examples/env.example` | Annotated `.env` template documenting all nanoclaw config vars. |
| 1.4 | `examples/run-nanoclaw.sh` | Start the nanoclaw host process with correct env. Validates image exists, Podman is running, `.env` is configured. |
| 1.5 | `tests/smoke.sh` | Build agent image, send test JSON to container via stdin, assert sentinel-wrapped JSON output, check exit code 0. |

### Phase 2: Documentation

Make it understandable and usable by others.

| Step | Deliverable | Description |
|---|---|---|
| 2.1 | `README.md` | Quickstart (prerequisites → setup → run → verify). Platform-specific prerequisite sections (bare-metal vs WSL2). Link to podman-wsl-setup for WSL2 users. Usage examples. |
| 2.2 | `docs/ARCHITECTURE.md` | Two-tier architecture (host process + agent containers). Entrypoint contract. Scope boundary: what this repo covers. |
| 2.3 | `docs/SECURITY.md` | Security hardening flags (`--read-only`, `--cap-drop=ALL`, `--security-opt=no-new-privileges`, tmpfs). Nanoclaw's security model summary. Credential exposure limitations. Network isolation options. |
| 2.4 | `docs/PARALLEL.md` | Resource math table (1–8 containers). Resource limiting by platform: `.wslconfig` for WSL2, systemd resource controls / cgroup limits for bare-metal. Nanoclaw's built-in concurrency (group queue). |

### Phase 3: Hardening & validation

Make it robust and trustworthy.

| Step | Deliverable | Description |
|---|---|---|
| 3.1 | `scripts/verify-podman-compat.sh` | Automated test of all Docker CLI patterns nanoclaw uses, run through the podman-docker shim. Reports pass/fail per pattern. |
| 3.2 | Security flags in run config | Add `--read-only --tmpfs /tmp --cap-drop=ALL --security-opt=no-new-privileges` to the agent container run. Validate nanoclaw still works with these restrictions. |
| 3.3 | `docs/TROUBLESHOOTING.md` | Catalog of known issues from testing: mount propagation, socket permissions, Chromium sandbox in rootless, subuid conflicts, etc. |
| 3.4 | `examples/wslconfig.example` | Template `.wslconfig` with memory/CPU formulas and commented examples for 1, 2, 4 container configs. |

### Phase 4: CI & publishing

Make it maintainable and discoverable.

| Step | Deliverable | Description |
|---|---|---|
| 4.1 | `.github/workflows/ci.yml` | Build agent image on `ubuntu-latest` + Podman. Run smoke test. Run on push + PR. |
| 4.2 | Version pinning doc | Document the nanoclaw commit pinning strategy. How to bump, how to verify after bump. |
| 4.3 | README polish | Badges (CI status), contributing guidelines, license. |

## Nanoclaw version pinning

Nanoclaw has no npm package, no release tags, and no stable versioning (version 1.1.2 in `package.json` as of Feb 2026, but no GitHub Releases). Installation is `git clone` + `npm ci`.

**Strategy:** Pin to a specific git commit hash in `setup-host.sh`. Default to a known-good commit. Allow override via env var or CLI arg.

```bash
NANOCLAW_COMMIT="${NANOCLAW_COMMIT:-abc1234}"  # known-good default
git clone https://github.com/qwibitai/nanoclaw.git
cd nanoclaw
git checkout "$NANOCLAW_COMMIT"
npm ci
```

**Bumping:** Change the default commit hash, rebuild image, run smoke test.

## Resource defaults

| Resource | Default | Rationale |
|---|---|---|
| `--cpus` | 2 | Sufficient for Claude Agent SDK + TypeScript compilation |
| `--memory` | 4g | Chromium (~500MB) + Node.js + agent overhead |
| `--pids-limit` | 256 | Prevents fork bombs; Chromium needs ~50-100 |
| Container timeout | 30 min | Nanoclaw default (`CONTAINER_TIMEOUT=1800000`) |
| Idle timeout | 30 min | Nanoclaw default (`IDLE_TIMEOUT=1800000`) |

### Resource formulas

Per-container overhead plus host baseline:

```
total_memory = (max_concurrent_containers × 4GB) + 2GB host overhead
total_cpus   = (max_concurrent_containers × 2) + 2 host overhead
```

**WSL2:** Apply these via `%UserProfile%/.wslconfig`:
```ini
[wsl2]
memory=10GB   # example for 2 containers
swap=4GB
```

**Bare-metal / cloud VM:** The host has full hardware access. Use Podman's `--cpus` and `--memory` flags per container (already in the run config) to prevent any single agent from starving others. For hard host-level caps, use systemd resource controls on the nanoclaw service.
