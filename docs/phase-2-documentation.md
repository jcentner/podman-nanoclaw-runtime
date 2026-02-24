# Phase 2: Documentation

**Goal:** Make the repo understandable and usable by someone who hasn't been in our planning conversations. A developer should be able to go from "never heard of this" to "running nanoclaw on Podman" by reading the README.

**Entry criteria:** Phase 1 complete — all scripts work, smoke test passes.

**Exit criteria:** A fresh user can follow the README from start to finish. Architecture, security model, and parallel usage are documented well enough to answer questions without reading source code.

---

## 2.1 — `README.md`

The primary entry point for the repo. Must be self-contained enough to get started, with links to deeper docs.

### Structure

```
# podman-nanoclaw-runtime

One-line description

## What this does (2-3 sentences)
## Architecture (simplified diagram)
## Prerequisites
  ### All platforms
  ### WSL2
  ### Bare-metal Ubuntu
## Quickstart
  ### 1. Set up Podman
  ### 2. Run setup
  ### 3. Build agent image
  ### 4. Start nanoclaw
  ### 5. Verify
## Configuration
## Running multiple agents
## Security
## Troubleshooting (quick hits, link to full doc)
## Project structure
## Related repos
## License
```

### Checklist

#### Header & overview
- [ ] One-line description: "Run nanoclaw AI agents in rootless Podman containers on Ubuntu"
- [ ] 2-3 sentence explanation of what this repo provides
- [ ] Link to nanoclaw repo
- [ ] Note: "Targets bare-metal Ubuntu. WSL2 fully supported."

#### Architecture
- [ ] Simplified ASCII diagram (host process + agent containers)
- [ ] One-paragraph explanation of two-tier design
- [ ] Link to `docs/ARCHITECTURE.md` for details

#### Prerequisites section
- [ ] "All platforms" list (Podman, podman-docker, Node.js 22+, Claude Code, API key)
- [ ] WSL2 subsection: link to podman-wsl-setup, brief instructions
- [ ] Bare-metal subsection: `apt install podman podman-docker`, link to Podman docs
- [ ] Each prerequisite has a verification command the user can run

#### Quickstart
- [ ] Step 1: Set up Podman (platform-specific, with verification)
- [ ] Step 2: Clone this repo + run `setup-host.sh`
- [ ] Step 3: `build-agent-image.sh` (or note that setup-host.sh already does this)
- [ ] Step 4: `run-nanoclaw.sh` with note about WhatsApp QR auth on first run
- [ ] Step 5: Verify with `smoke.sh` or manual test
- [ ] Each step shows exact commands to copy-paste
- [ ] Expected output shown for key steps

#### Configuration
- [ ] Link to `examples/env.example` with summary of key vars
- [ ] `ASSISTANT_NAME`, `CONTAINER_TIMEOUT`, `IDLE_TIMEOUT`
- [ ] How to change nanoclaw version (commit pinning)

#### Running multiple agents
- [ ] Explanation of nanoclaw's built-in concurrency (multiple groups in parallel)
- [ ] Resource formula (one line)
- [ ] Link to `docs/PARALLEL.md` for details

#### Security
- [ ] One-paragraph summary of isolation model
- [ ] List of hardening flags applied
- [ ] Known limitations (credential exposure, unrestricted network)
- [ ] Link to `docs/SECURITY.md`

#### Troubleshooting
- [ ] Top 5 most common issues as a quick table
- [ ] Link to `docs/TROUBLESHOOTING.md` for complete list

#### Project structure
- [ ] File tree with one-line descriptions
- [ ] Same format as PLAN.md's repo structure section

#### Footer
- [ ] Related repos: podman-wsl-setup, nanoclaw upstream
- [ ] License: MIT
- [ ] No "contributing" section yet (Phase 4)

---

## 2.2 — `docs/ARCHITECTURE.md`

Deep dive into how everything fits together.

### Structure

```
# Architecture

## Overview
## Two-tier design
  ### Host process
  ### Agent containers
## Container lifecycle
## Entrypoint contract
  ### Input
  ### Output
  ### Mounts
  ### Exit codes
## IPC mechanism
## Docker→Podman compatibility layer
```

### Checklist

#### Overview
- [ ] Full ASCII diagram from PLAN.md (host + containers + boundaries)
- [ ] Explanation of why the host process is bare-metal and agents are containerized
- [ ] Data flow: message arrives → host process routes → spawns container → collects result → responds

#### Host process
- [ ] What it does: message I/O, SQLite, scheduling, IPC, container lifecycle
- [ ] Key files from nanoclaw: `src/index.ts`, `src/container-runner.ts`, `src/group-queue.ts`
- [ ] State it manages: `store/` (WhatsApp auth), `data/` (SQLite + sessions), `groups/` (workspaces)
- [ ] Why it can't be containerized easily (spawns containers, manages persistent state, filesystem IPC)

#### Agent containers
- [ ] What they do: run Claude Agent SDK for a single prompt/task
- [ ] Lifecycle: spawn → receive input on stdin → execute → write output to stdout → exit
- [ ] Ephemeral: `--rm` flag, fresh environment every time
- [ ] Base image: `node:22-slim` + Chromium + git + curl
- [ ] Non-root execution: `node` user (uid 1000)

#### Container lifecycle
- [ ] Detailed flow:
  1. Host process receives message
  2. `container-runner.ts` builds mount list and container args
  3. `docker run -i --rm --name nanoclaw-<group>-<ts>` spawned as child process
  4. Input JSON piped to container's stdin
  5. Container compiles agent-runner TypeScript, runs agent
  6. Agent executes Claude Code, writes IPC files, produces output
  7. Output JSON written to stdout between sentinel markers
  8. Container exits, host process parses output
  9. Host process routes response back to messaging channel
- [ ] Timeout handling: `CONTAINER_TIMEOUT` kills container after 30 min
- [ ] Idle timeout: `IDLE_TIMEOUT` kills if no streaming output for 30 min
- [ ] Orphan cleanup: host process runs `docker ps --filter` to find stale containers on startup

#### Entrypoint contract
- [ ] Full input JSON schema with field descriptions (from PLAN.md)
- [ ] Full output JSON schema with field descriptions
- [ ] Sentinel markers: `---NANOCLAW_OUTPUT_START---` and `---NANOCLAW_OUTPUT_END---`
- [ ] Streaming mode vs legacy mode explanation
- [ ] Exit code semantics
- [ ] Complete mount table (from PLAN.md)
- [ ] Note: this contract is the stable API for integrations built on top of this repo

#### IPC mechanism
- [ ] How the host and container communicate beyond stdin/stdout:
  - `/workspace/ipc/messages/` — agent writes JSON files to send messages
  - `/workspace/ipc/tasks/` — agent writes JSON to schedule tasks
  - `/workspace/ipc/input/` — host writes follow-up messages for the agent
- [ ] Host polls IPC directories via `src/ipc.ts`
- [ ] Per-group isolation: each group has its own IPC paths

#### Docker→Podman compatibility
- [ ] Why nanoclaw hardcodes `docker`: `container-runtime.ts` exports `CONTAINER_RUNTIME_BIN = 'docker'`
- [ ] How `podman-docker` shim bridges this
- [ ] How `podman.socket` + `DOCKER_HOST` bridges the API layer
- [ ] List of Docker CLI commands nanoclaw uses and their Podman compatibility status
- [ ] Known edge cases or differences (if any found during Phase 3 testing)

---

## 2.3 — `docs/SECURITY.md`

Security model, hardening measures, and known limitations.

### Structure

```
# Security

## Threat model
## Isolation layers
## Container hardening flags
## Nanoclaw's built-in security
## Credential handling
## Network security
## Known limitations
## Recommendations by use case
```

### Checklist

#### Threat model
- [ ] What are we protecting against?
  - Agent executing arbitrary code that escapes the container
  - Agent accessing host files outside its designated workspace
  - Agent exfiltrating data over the network
  - Agent consuming all host resources (DoS)
  - Cross-agent information disclosure
- [ ] What are we NOT protecting against?
  - A compromised host process (it has full host access)
  - Network-level attacks from the agent (unrestricted by default)
  - Side-channel attacks between containers
- [ ] Trust levels: host process = trusted, agent containers = untrusted

#### Isolation layers
- [ ] Layer 1: Podman rootless — user namespaces, no real root even inside container
- [ ] Layer 2: WSL2 VM (WSL2 only) — separate kernel from Windows
- [ ] Layer 3: Ephemeral containers — fresh state every invocation
- [ ] Layer 4: Mount restrictions — only designated paths visible
- [ ] Layer 5: Non-root user — `node` uid 1000 inside container
- [ ] Diagram: concentric circles of isolation

#### Container hardening flags
- [ ] Document each flag and its purpose:

| Flag | Purpose | Default |
|---|---|---|
| `--rm` | Remove container on exit, no persistent state | Enabled |
| `--read-only` | Root filesystem is read-only | Recommended |
| `--tmpfs /tmp` | Writable tmpfs for temp files | Required if `--read-only` |
| `--cap-drop=ALL` | Drop all Linux capabilities | Recommended |
| `--security-opt=no-new-privileges` | Prevent privilege escalation via setuid | Recommended |
| `--cpus=2` | CPU limit | Enabled |
| `--memory=4g` | Memory limit | Enabled |
| `--pids-limit=256` | Prevent fork bombs | Enabled |
| `--user <uid>:<gid>` | Run as non-root | Enabled |
| `-v host:container:ro` | Read-only bind mount for project root | Enabled |

- [ ] Note which flags nanoclaw already applies vs. which we add
- [ ] Note any flags that might break nanoclaw (test in Phase 3)

#### Nanoclaw's built-in security
- [ ] Summary of nanoclaw's SECURITY.md:
  - Mount allowlist at `~/.config/nanoclaw/mount-allowlist.json`
  - Blocked patterns (`.ssh`, `.gnupg`, `.aws`, etc.)
  - Symlink resolution before mount validation
  - Project root mounted read-only
  - Per-group session isolation
  - IPC authorization (main vs non-main groups)
- [ ] These are application-level checks on top of our container-level isolation

#### Credential handling
- [ ] How secrets reach the container: stdin JSON, not env vars or mounted files
- [ ] What's exposed: `CLAUDE_CODE_OAUTH_TOKEN`, `ANTHROPIC_API_KEY`
- [ ] Known limitation: the agent can discover these credentials via bash/file operations inside the container
- [ ] Nanoclaw upstream acknowledges this: "PRs welcome if you have ideas for credential isolation"
- [ ] Mitigation: container network could be restricted to only Anthropic API endpoints

#### Network security
- [ ] Default: unrestricted network access (agent can reach anything)
- [ ] This is by design — agents need to: call Anthropic API, install packages, fetch web content
- [ ] Hardening options:
  - `--network=none` for fully offline jobs (pre-installed deps required)
  - Custom Podman network with firewall rules (allow only Anthropic API + package registries)
  - DNS-level filtering
- [ ] Document how to create a restricted network (commands, not just concept)

#### Known limitations
- [ ] Credential exposure inside container (no current fix)
- [ ] Network unrestricted by default
- [ ] Agent can see its own stdout/stderr (can't prevent logging of secrets by the agent itself)
- [ ] Podman rootless != full VM isolation (shared kernel with host)
- [ ] No seccomp profile customization (using Podman's default, which is good but not nanoclaw-specific)
- [ ] Resource limits are per-container, not per-group (one group could spawn many containers)

#### Recommendations by use case
- [ ] **Personal dev/test:** Default settings are fine. Trust yourself.
- [ ] **Shared machine:** Enable all hardening flags. Consider restricted network.
- [ ] **Untrusted workloads:** Copy-in/out mode, `--network=none`, restricted credentials.
- [ ] **Production:** All of the above + credential rotation + external orchestrator controls.

---

## 2.4 — `docs/PARALLEL.md`

Resource planning and multi-instance guidance.

### Structure

```
# Running Parallel Agents

## Nanoclaw's built-in concurrency
## Resource math
## Platform-specific resource controls
  ### WSL2
  ### Bare-metal / cloud VM
## Monitoring
```

### Checklist

#### Nanoclaw's built-in concurrency
- [ ] How it works: `src/group-queue.ts` manages a per-group queue with a global concurrency limit
- [ ] Each WhatsApp group can have one active agent container at a time
- [ ] Multiple groups can run in parallel (up to the concurrency limit)
- [ ] Default concurrency limit: document nanoclaw's default (check source)
- [ ] How to change it: environment variable or code modification
- [ ] Resource implications: each concurrent container uses ~500MB–1.5GB (with Chromium) + 2 CPUs

#### Resource math
- [ ] Per-container defaults table:

| Resource | Per container | Notes |
|---|---|---|
| CPU | 2 cores | Claude Agent SDK + TypeScript compilation |
| Memory | 4 GB | Chromium (~500MB) + Node.js + agent workload |
| PIDs | 256 | Chromium ~50-100 processes |
| Disk I/O | Moderate | Agent reads/writes workspace files |

- [ ] Host process overhead:

| Resource | Per host process | Notes |
|---|---|---|
| CPU | ~0.5 cores | Mostly idle, spikes during message routing |
| Memory | ~200 MB | Node.js + SQLite + message queues |

- [ ] Planning table:

| Containers | CPU needed | RAM needed | Suitable for |
|---|---|---|---|
| 1 | 3 cores | 5 GB | Personal use |
| 2 | 5 cores | 10 GB | Small team |
| 4 | 9 cores | 18 GB | Medium workload |
| 8 | 17 cores | 34 GB | Production pilot |

- [ ] Formula for quick calculation:
  ```
  total_memory = (N × 4GB) + 2GB
  total_cpus   = (N × 2) + 2
  ```
- [ ] Note: without Chromium (if agent-browser not needed), drop to 2GB per container

#### Platform-specific resource controls

##### WSL2
- [ ] `.wslconfig` location: `%UserProfile%/.wslconfig`
- [ ] Example configurations for 1, 2, 4 containers
- [ ] Note: WSL2 defaults to 50% of host RAM — explicitly set `memory=` to override
- [ ] Note: WSL2 memory is not released back to Windows until `wsl --shutdown`
- [ ] Swap recommendation: set `swap=` to at least 2GB for buffer
- [ ] Link to `examples/wslconfig.example`

##### Bare-metal / cloud VM
- [ ] No `.wslconfig` — full hardware available
- [ ] Per-container limits via Podman flags: `--cpus`, `--memory`, `--pids-limit` (already in run config)
- [ ] Host-level limits: systemd resource controls if running nanoclaw as a service
  ```ini
  # /etc/systemd/system/nanoclaw.service.d/resources.conf
  [Service]
  MemoryMax=18G
  CPUQuota=900%
  ```
- [ ] Monitoring: `podman stats` for live container resource usage
- [ ] Cloud VM sizing guide: map container count to instance type (e.g., AWS t3.xlarge for 2 containers)

#### Monitoring
- [ ] `podman stats` — live resource usage per container
- [ ] `podman ps` — running containers
- [ ] `podman logs <name>` — container output (limited, since `--rm` removes on exit)
- [ ] Nanoclaw's own logs: `data/logs/` directory
- [ ] Host-level: `htop`, `free -h`, `df -h`

---

## Implementation order

```
2.2  ARCHITECTURE.md  (foundational — other docs reference it)
 ↓
2.3  SECURITY.md      (references architecture, standalone topic)
 ↓
2.4  PARALLEL.md      (references architecture, standalone topic)
 ↓
2.1  README.md        (synthesizes all docs into quickstart, written last)
```

## Open questions for Phase 2

- [ ] **README length:** Should the README be comprehensive or minimal-with-links? Recommendation: comprehensive quickstart section, link to docs for everything else.
- [ ] **Nanoclaw concurrency default:** Need to verify nanoclaw's default concurrency limit from source (`src/group-queue.ts`). This affects Level A documentation.
- [ ] **Headless mode documentation:** Nanoclaw supports headless operation (no WhatsApp). Should the README's quickstart use headless mode for simplicity, or WhatsApp for the "real" experience? Recommendation: show both, headless first for quick testing.
