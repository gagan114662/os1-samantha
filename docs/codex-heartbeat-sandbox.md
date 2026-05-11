# Codex Heartbeat Sandbox Runtime

This is the source of truth for how OS1 launches Samantha/Codex company heartbeats.

## Runtime Mode

Production company heartbeats are sandboxed at the OS1 wrapper layer.

When a company uses `sandbox` mode, OS1:

1. Generates a per-company macOS sandbox profile.
2. Launches the heartbeat through `/usr/bin/sandbox-exec -f <profile>`.
3. Allows writes only to that company's worktree, heartbeat prompt/log files, and approved shared lessons file.
4. Records the launch command, sandbox runtime, and sandbox profile path in the company event timeline.

Inside that macOS sandbox, OS1 invokes:

```sh
codex exec --dangerously-bypass-approvals-and-sandbox -
```

That Codex flag disables Codex's own per-command approval/sandbox prompts so the heartbeat can run unattended.
It does not mean the OS1 wrapper is unsandboxed when `sandbox` mode is active.

## OFF Mode

`localDevelopment` mode is allowed only for operator debugging. It launches through `/usr/bin/env` instead of
`/usr/bin/sandbox-exec`.

When `localDevelopment` is used, OS1:

- Emits a `Codex heartbeat sandbox: OFF` warning event before launch.
- Shows a red warning banner in the company detail sheet.
- Treats the company as unsafe for revenue operations.

## How To Verify

Use the Doctor tab. The row named `Codex heartbeat sandbox: ON|OFF` reads the actual heartbeat launch plan and
checks whether `/usr/bin/sandbox-exec` is executable.

The Swift test suite also asserts that sandbox-mode heartbeat argv contains `/usr/bin/sandbox-exec`, and that
local-development launches emit an OFF warning.
