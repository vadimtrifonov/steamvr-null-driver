---
name: steamvr-headless
description: Start, inspect, and stop bounded SteamVR null-HMD sessions without a physical headset. Use for headless SteamVR startup, null-driver diagnostics, or interrupted-run cleanup.
---

# SteamVR Headless

Use this skill directory as the working directory.

## Contract

This helper supports one Windows account, one SteamVR installation, and one fixed state root. The state root is `%LOCALAPPDATA%\SteamVrHeadless`.

Steam must already run under the same interactive account. SteamVR must be stopped before a run starts.

Headless means that SteamVR uses its bundled `null` HMD. A compositor, a GPU, and an interactive Windows session remain necessary.

Each run generates a small `steamvr.vrsettings` file in its private run directory. The file forces `null`, disables other-driver activation, disables dashboard applications, and disables Direct Display Mode.

SteamVR can add run-specific settings and application metadata under the private configuration path. These additions remain private to the run.

The run also has private chaperone data and SteamVR logs. The helper exports these variables:

- `VR_OVERRIDE`
- `VR_CONFIG_PATH`
- `VR_LOG_PATH`

Pass `run.environment` to each child OpenVR application.

The helper does not read or change the normal SteamVR settings or chaperone files. Existing Steam processes can update Steam-owned logs and metadata.

The temporary chaperone file supplies zero seated and standing origins for universe `2`. Without this file, the tested null runtime launched Room Setup.

The temporary origins are not physical room, floor, or boundary calibration.

## Readiness

Startup requires these properties:

- The `null` server driver is loaded.
- The active HMD belongs to `null`.
- No other server driver loads or starts device activation.
- Direct Display Mode does not start.
- Room Setup does not start.
- One `vrserver` and one `vrcompositor` remain unchanged for five seconds.

After readiness, the supervisor monitors the recorded server and compositor identities. Cleanup examines the complete selected runtime root again.

Readiness is a process-level gate. It does not probe a scene application through OpenVR.

## Ownership and cleanup

The active lock reserves the selected runtime. Each SteamVR process that starts under that runtime during the lease becomes owned.

Cleanup uses this order:

1. Request SteamVR shutdown through `vrmonitor://quit`.
2. Stop the exact remaining runtime processes.
3. Make sure that no runtime process remains.
4. Remove the active lock.

If process inspection or shutdown fails, cleanup retains the active lock and private evidence. The terminal phase is `cleanup-required`.

An unreadable path for a known SteamVR process stops inspection. Other inaccessible Windows processes remain outside the ownership decision.

Run `stop` again after you correct the process problem. A malformed active journal or an orphan lock requires manual inspection.

The detached supervisor enforces the deadline while it remains operational. If the supervisor stops unexpectedly, `stop` performs stale-run cleanup.

## Inactive journals

`check` reports completed inactive journals in `inactiveRuns`. These journals do not own the runtime.

A new start removes all inactive journals after it wins the active lock. The `start.prunedRuns` array reports their run IDs.

A retained status remains available only until the next start. Use `stop -RunId` to remove one inactive journal earlier.

## Safety rules

- Operate one run at a time.
- Run lifecycle commands sequentially.
- Keep the returned run ID until cleanup completes.
- Stop the run in a `finally` path after child work.
- Leave SteamVR processes that existed before reservation unchanged.
- Keep physical and virtual tracking drivers inactive.
- Keep Room Setup and other SteamVR tools closed during the lease.
- Update SteamVR only when no run is active.

Competing starts fail safely. A nondefault state namespace is not supported.

## Installation discovery

The helper finds SteamVR through the Steam App 250820 registration. Automatic discovery supports exactly one complete registered installation.

Supply the runtime root if registration is unavailable or ambiguous:

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 check `
  -SteamVrRoot "<SteamVR-root>"
```

The selected root must contain the server, compositor, monitor, startup executable, and bundled null driver.

## Check

`check` is optional and read-only:

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 check
```

`canStart=true` means that the runtime is stopped and no active lock exists. Examine `inactiveRuns` for retained private evidence.

## Start

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 start `
  -MaxDurationMinutes 30
```

The maximum supported duration is 120 minutes. The duration includes startup.

Continue only when `ok=true`, `run.phase=ready`, and `run.evidence.ready=true`. Save `runId` and `run.environment`.

If start does not report readiness, inspect `status`. Then run `stop` with the returned run ID.

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

`stop` handles a live supervisor, a dead supervisor, and an inactive private journal. Cleanup is complete when `ok=true`.

## Output

Each public command writes one JSON object to standard output. An error returns a nonzero exit code.
