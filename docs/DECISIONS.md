# Decisions & Discoveries

Machine-readable reference for future sessions. See PLAN.md for architecture context.

## ADRs

### ADR-001: `--userns=keep-id` for container runs
- Rootless Podman maps host UID→container root by default; bind mounts appear as `root:root` to container's `node` user (UID 1000)
- Fix: `--userns=keep-id` maps host UID→same UID inside container
- Nanoclaw's own `container-runner.ts` needs this too — set via `~/.config/containers/containers.conf` or enterprise fork

### ADR-002: Foreground podman + background watchdog for timeouts
- `timeout podman run` orphans containers (kills CLI, conmon keeps container alive)
- `podman run &` breaks stdin piping
- Solution: podman foreground, watchdog subshell sleeps then runs `podman stop -t 5`

### ADR-003: `grep -qF --` for sentinel matching
- Sentinels start with `---` → grep parses as options
- Fix: `-F` (fixed string) + `--` (end of options)

### ADR-004: `CLAUDE_MODEL` env var
- Nanoclaw doesn't configure model; Claude Agent SDK reads `CLAUDE_MODEL` from environment
- Default: `haiku` (latest-version pointer)
- Passed into container via `-e CLAUDE_MODEL=...`

### ADR-005: `examples/chat.sh` headless wrapper
- Nanoclaw host is WhatsApp-only — no built-in CLI/headless mode
- `chat.sh` pipes entrypoint-contract JSON directly to agent container
- Supports REPL and single-shot modes, preserves session IDs across turns
- IPC dirs mounted but not polled; no streaming; ~10-15s TypeScript compilation per turn

## Discoveries

| ID | Finding |
|---|---|
| DISC-001 | Container entrypoint intercepts all commands — use `--entrypoint bash` for diagnostics |
| DISC-002 | `claude` CLI at `/usr/local/bin/claude` (global npm install), version 2.1.53 at time of testing |
| DISC-003 | ~30-60s per prompt (tsc compilation + Claude Code init + API roundtrip) |
| DISC-004 | Tested on Node 22.22.0, claude-agent-sdk 0.2.34, TypeScript 5.7.3 |
| DISC-005 | Agent-runner loops forever after first query, polling IPC for follow-up messages. Must write `_close` sentinel to `/workspace/ipc/input/_close` (host-side: mounted dir) for clean exit. Without it, container hangs until timeout. |
