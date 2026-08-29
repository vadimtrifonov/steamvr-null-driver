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

Each run generates a minimal `steamvr.vrsettings` file in its run directory. It contains only the null-driver and dashboard overrides required by this helper.

SteamVR can add run-specific settings and application metadata under the private config path. These additions remain private to the run.

The run also has private chaperone data and private SteamVR logs. The helper starts SteamVR with these environment variables:

- `VR_CONFIG_PATH`
- `VR_LOG_PATH`

The helper does not read or change the normal SteamVR settings or chaperone files.

Existing Steam processes can still update their own global client logs and Steam metadata. These Steam-owned changes are outside this contract.

Startup validation requires these properties:

- The `null` server driver is loaded.
- The active HMD belongs to `null`.
- No other server driver is loaded or starts device activation.
- The same `vrserver` and `vrcompositor` processes remain alive for five seconds.
- Room Setup does not start.

After readiness, the supervisor monitors the recorded `vrserver` and `vrcompositor` identities until stop or lease expiry. Runtime-wide validation occurs again during cleanup.

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

`recover` performs runtime cleanup only for the active journal and only when its supervisor is inactive. It removes inactive private journals because they do not own shared configuration or runtime processes.

A malformed active journal or an active lock without its journal requires manual inspection. A supervisor crash disables automatic lease cleanup. The active lock blocks a new run until `recover` succeeds.

## Safety rules

- Operate one headless run at a time.
- Run lifecycle commands sequentially.
- Keep the returned run ID until cleanup completes.
- Stop the run in a `finally` path after subsequent work.
- Leave an existing, unowned SteamVR runtime unchanged.
- Keep Direct Display Mode disabled.
- Keep all other tracking drivers and virtual controllers disabled.
- Do not launch Room Setup or another SteamVR tool during a ready run.
- Launch a child OpenVR application with `run.environment` when it must use the private paths.

Competing start commands fail safely. Stop and recover commands require serialization.

## Installation discovery

The helper finds SteamVR from the Steam App 250820 registration. If that registration is unavailable, it finds the Steam client from the Valve registry entries and examines its default library.

Automatic discovery supports these layouts:

- Steam and SteamVR in the same Steam root.
- SteamVR in another Steam library with a valid Steam App 250820 registration.

### Discovery limits

- Automatic discovery supports one SteamVR installation.
- A split-library installation requires a valid Steam App 250820 registration.
- `-SteamRoot` affects only the colocated fallback.

Supply the runtime path if discovery is unavailable or ambiguous:

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 check `
  -SteamVrRoot "<SteamVR-root>"
```

## Read-only check

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 check
```

Continue only when `ok=true` and `canStart=true`.

## Start

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 start `
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
