---
name: steamvr-headless
description: Start, inspect, stop, and recover SteamVR null-HMD sessions without a physical headset. Use for headless SteamVR startup, null-driver diagnostics, or interrupted-run cleanup.
compatibility: Windows, PowerShell 7, and SteamVR. Tested with SteamVR 2.16.7.
---

# SteamVR Headless

Use this skill directory as the working directory.

## Contract

This helper owns one SteamVR runtime in one state-root namespace. SteamVR must be stopped before the run starts.

Use one Windows account and one state root for commands that target the same SteamVR installation. Use the default state root for normal work.

Headless means that SteamVR uses its bundled `null` HMD. A compositor, a GPU, and an interactive Windows session remain necessary.

Each run copies the source `steamvr.vrsettings` file into its run directory. The helper changes only this private copy.

The run also has private chaperone data and private SteamVR logs. The helper starts SteamVR with these environment variables:

- `VR_CONFIG_PATH`
- `VR_LOG_PATH`

The normal SteamVR configuration remains available as the source. The helper does not change its settings or chaperone files.

Existing Steam processes can still update their own global client logs and Steam metadata. These Steam-owned changes are outside this contract.

A ready run has these properties:

- The `null` server driver is loaded.
- The active HMD belongs to `null`.
- No other server driver is loaded or starts device activation.
- `vrserver` and `vrcompositor` remain alive for five seconds.
- Room Setup does not start.

Readiness is a process-level gate. It does not probe a scene application through OpenVR.

The temporary calibration supplies zero seated and standing origins for universe `2`. It is not physical room, floor, or boundary calibration.

The maximum duration includes startup. The detached supervisor stops the run when this deadline expires.

## Ownership and recovery

The supervisor owns each process that starts under the selected SteamVR runtime root during the lease.

Cleanup uses this order:

1. Stop the owned SteamVR runtime.
2. Make sure that no owned runtime process remains.
3. Remove the active lock.

If process inspection or shutdown fails, cleanup retains the private state and journal. It returns `recovery-required`.

An unreadable path for a canonical SteamVR process is an inspection error. Other inaccessible Windows processes remain outside the ownership decision.

`recover` operates only on a valid journal with an inactive supervisor. It refuses malformed or orphaned state.

A supervisor crash disables automatic lease cleanup. The active lock blocks a new run until `recover` succeeds.

## Safety rules

- Operate one headless run at a time.
- Run lifecycle commands sequentially.
- Keep the returned run ID until cleanup completes.
- Stop the run in a `finally` path after subsequent work.
- Leave an existing, unowned SteamVR runtime unchanged.
- Keep Direct Display Mode disabled.
- Keep all other tracking drivers and virtual controllers disabled.
- Launch a child OpenVR application with `run.environment` when it must use the private paths.

Competing start commands fail safely. Stop and recover commands require serialization.

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

The `run.environment` object contains the private OpenVR paths for child processes.

If `start` does not report readiness, inspect `status`. Then use `stop` or `recover` to complete cleanup.

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

Cleanup is complete when `ok=true` and `run.cleanupComplete=true`.

## Recover

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 recover
```

The result separates `recovered`, `active`, and `errors`. Continue only when `ok=true`, `errors` is empty, and `active` is empty.

## Output

Each public command writes one JSON object to standard output. An error returns a nonzero exit code.
