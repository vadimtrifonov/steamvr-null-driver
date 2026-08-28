---
name: steamvr-headless
description: Start, inspect, stop, and recover SteamVR null-HMD sessions without a physical headset. Use for headless SteamVR startup, null-driver diagnostics, or interrupted-run cleanup.
compatibility: Windows, PowerShell 7, and SteamVR.
---

# SteamVR Headless

Use this skill directory as the working directory.

## Contract

This helper owns one SteamVR runtime within one state-root namespace. SteamVR must be stopped before the run starts.

Use one Windows account and one state root for all commands that target the same SteamVR installation. Use the default state root for normal work.

Headless means that SteamVR uses its bundled `null` HMD. A compositor, a GPU, and an interactive Windows session remain necessary.

A ready run has these properties:

- The `null` server driver is loaded.
- The active HMD belongs to `null`.
- No other server driver is loaded or starts device activation.
- `vrserver` and `vrcompositor` remain alive for five seconds.
- Room Setup does not start.

Readiness is a process-level gate. It does not probe a scene application through OpenVR.

The helper snapshots these files before it changes the SteamVR configuration:

- `steamvr.vrsettings`
- `chaperone_info.vrchap`
- `chaperone_info.vrchap.tmp`
- `vrappconfig\openvr.tool.steamvr_room_setup.vrappconfig`
- `steamvr.vrstats`

Restoration covers exact file bytes and prior file existence. File metadata, SteamVR logs, and other Steam files are outside this contract.

Do not change SteamVR settings or start another SteamVR tool during the lease. Restoration discards concurrent changes to protected files.

The temporary calibration supplies zero seated and standing origins for universe `2`. It is not physical room, floor, or boundary calibration.

The maximum duration includes startup. The detached supervisor stops the run when this deadline expires.

## Ownership and recovery

The supervisor owns each process that starts under the selected SteamVR runtime root during the lease.

Cleanup uses this order:

1. Stop the owned SteamVR runtime.
2. Make sure that no owned runtime process remains.
3. Restore protected file bytes and existence.
4. Remove the active lock.

If process inspection or shutdown fails, cleanup leaves the temporary files and journal in place. It returns `recovery-required`.

An unreadable path for a canonical SteamVR process is an inspection failure. Other inaccessible Windows processes remain outside the ownership decision.

`recover` operates only on a valid journal with an inactive supervisor. It refuses malformed or orphaned state instead of guessing.

A supervisor crash disables automatic lease cleanup. The active lock blocks a new run until `recover` succeeds.

## Safety rules

- Operate one headless run at a time.
- Run lifecycle commands sequentially. Competing start commands fail safely, but stop and recover commands require serialization.
- Keep the returned run ID until cleanup completes.
- Stop the run in a `finally` path after subsequent work.
- Leave an existing, unowned SteamVR runtime unchanged.
- Keep Direct Display Mode disabled.
- Keep all other tracking drivers and virtual controllers disabled.

## Read-only check

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 check `
  -SteamRoot "C:\Steam"
```

Continue only when `ok=true` and `canStart=true`.

## Start

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 start `
  -SteamRoot "C:\Steam" `
  -MaxDurationMinutes 30
```

Save `runId`. Continue only when `ok=true`, `run.phase=ready`, and `run.evidence.compositorRunning=true`.

If `start` returns a run ID without readiness, inspect `status`. Then use `stop` or `recover` to complete cleanup.

## Status

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 status `
  -RunId "<run-id>"
```

A usable run has `supervisorAlive=true`, `run.phase=ready`, and `run.evidence.ready=true`.

## Stop

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 stop `
  -RunId "<run-id>"
```

Cleanup is complete when `ok=true` and `run.restored=true`.

## Recover

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 recover
```

The result separates `recovered`, `active`, and `errors`. Continue only when `ok=true`, `errors` is empty, and `active` is empty.

## Output

Each public command writes one JSON object to standard output. An error returns a nonzero exit code.
