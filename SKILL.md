---
name: steamvr-headless
description: Start, inspect, and stop bounded SteamVR null-HMD sessions without a physical headset. Use for headless SteamVR startup, null-driver diagnostics, or interrupted-run cleanup.
---

# SteamVR Headless

Use this skill directory as the working directory.

## Workflow

Before a run, make sure that these conditions are true:

- Steam runs in the same interactive Windows session.
- SteamVR is stopped.
- No SteamVR update is in progress.
- Room Setup and other SteamVR tools are closed.

Run lifecycle commands sequentially. Operate one run at a time.

### 1. Check the system

`check` is optional. `start` does the same authoritative preflight.

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 check
```

Continue when `ok=true` and `canStart=true`.

If registration is unavailable or ambiguous, add `-SteamVrRoot "<SteamVR-root>"` to `check` and `start`.

### 2. Start SteamVR

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 start `
  -MaxDurationMinutes 30
```

The duration includes startup. The permitted range is 1 through 120 minutes.

Continue when `ok=true` and `run.phase=ready`. Save `runId` and `run.environment`.

If `start` returns a run ID without readiness, run `status`. Then run `stop` with that run ID.

If `start` returns no run ID, correct the preflight error before you try again.

### 3. Start a child application

Pass all properties from `run.environment` to each child OpenVR application.

The caller owns each child process. Stop child processes before you run `stop`.

Readiness does not prove that a scene application can connect or render. Do a separate application test when you need that evidence.

### 4. Check run status

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 status `
  -RunId "<run-id>"
```

A usable active run has `active=true`, `supervisorAlive=true`, and `run.phase=ready`.

### 5. Stop the run

Always run `stop` in a `finally` path after child work.

```powershell
pwsh -NoProfile -File scripts/steamvr-headless.ps1 stop `
  -RunId "<run-id>"
```

Cleanup is complete when `ok=true`. Keep the run ID until cleanup is complete.

If `run.phase=cleanup-required`, correct the reported process problem. Then run `stop` again with the same run ID.

## Installation boundary

The helper supports one Windows account, one selected SteamVR installation, and `%LOCALAPPDATA%\SteamVrHeadless` as its state root.

The Steam client and SteamVR can be on different drives or in different Steam libraries.

Automatic discovery uses the Steam App 250820 registration. It accepts exactly one complete registered installation.

An explicit root must contain the startup, server, compositor, and monitor executables. It must also contain the bundled `null` driver.

## Runtime boundary

Each run has unique configuration and log directories. `run.environment` contains `VR_OVERRIDE`, `VR_CONFIG_PATH`, and `VR_LOG_PATH`.

The private settings force `null` and disable multiple-driver activation. They also disable dashboard applications and Direct Display Mode.

The helper does not read or change the normal SteamVR settings or chaperone files. Steam can update Steam-owned logs and application metadata.

The private chaperone file supplies zero seated and standing origins for universe `2`. These origins only suppress Room Setup.

CAUTION: Do not use the temporary origins as physical room, floor, or boundary calibration. They contain no physical calibration data.

Startup requires these results:

- The `null` server driver loads.
- The active HMD belongs to `null`.
- No other server driver loads or starts device activation.
- Direct Display Mode does not start.
- Room Setup does not start.
- One `vrserver` and one `vrcompositor` remain unchanged for five seconds.

After readiness, the supervisor checks only the recorded server and compositor identities. It does not continuously parse the startup log.

Keep physical and virtual tracking drivers inactive during the lease. Keep Room Setup and other SteamVR tools closed.

## Ownership and cleanup

The active lock reserves the selected runtime. During cleanup, the helper owns each process whose executable is under that runtime root.

Do not start SteamVR manually during an owned lease. Cleanup can stop a manually started runtime-root process.

Cleanup requests `vrmonitor://quit`, stops exact remaining processes, and checks the complete runtime root. It removes the lock last.

If process inspection or shutdown fails, cleanup retains the lock and private evidence.

An unreadable path for a known SteamVR process stops inspection. Inaccessible unrelated Windows processes remain outside the ownership decision.

The detached supervisor enforces the deadline while it operates. If the supervisor stops, use `stop` to clean the stale run.

Malformed active state or an orphan lock requires manual inspection.

## Retained runs

`check` reports retained run state in `inactiveRuns`. These runs do not own the runtime.

A new lock owner removes retained run state before startup.

Use `status -RunId` to inspect a retained run. Use `stop -RunId` to remove it before the next start.

## Output

Each public command writes one JSON object to standard output. An error returns a nonzero exit code.
