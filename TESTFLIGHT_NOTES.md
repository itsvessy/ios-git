# CommitSync Internal Alpha TestFlight Notes

CommitSync is an internal alpha Git SSH client for iPhone.

## What to Test

- Import or generate an SSH key.
- Add a test repository using an SSH remote URL.
- Clone, inspect local changes, stage files, commit, sync, push, and reset test repositories.
- Use non-sensitive repositories only.

## Known Alpha Limits

- SSH host trust currently uses a synthetic host/port fingerprint while real SSH host-key wiring is still pending.
- Auto Sync controls are visible, but production background scheduling and result persistence are not fully wired.
- Per-repository SSH key overrides are not complete; host default keys are the supported path.
- This build has no analytics, telemetry, tracking, or developer-operated data collection.

## App Store Connect Metadata

- App Store name: `CommitSync: Git SSH Client`
- Bundle ID: `com.vessy.CommitSync`
- SKU: `com.vessy.CommitSync`
- Category: Developer Tools
- Version/build: `0.1 (1)`
