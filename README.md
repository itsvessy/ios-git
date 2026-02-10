# GitPhone

iPhone-first Git-over-SSH clone/sync app scaffold (iOS 18+, SwiftUI, modular architecture).

## Current Status

Implemented in this repo:

- Modular Xcode project via XcodeGen (`Core`, `Storage`, `SecurityEngine`, `GitEngine`, `BackgroundSync`, app target, tests).
- Core domain contracts for repos/sync/auth/trust.
- SSH URL parsing and sync-state modeling.
- Security primitives:
  - Keychain secret store
  - App lock coordinator (biometric/device auth)
  - SSH key import + on-device key generation (Ed25519 preferred, RSA fallback)
  - Host fingerprint pinning policy (TOFU + rotation prompt support)
- Git engine implementation (`SwiftGitX`-backed):
  - Clone/sync API with protocol abstraction
  - Clone/fetch/fast-forward sync flow with dirty/diverged/background-deferred state handling
- SwiftUI app shell:
  - Unlock gate
  - Repo list with sync actions
  - Add-repo flow
  - Trust prompt UI
  - Recovery actions (clear dirty/diverged block markers)
- Unit tests for SSH URL parsing and Git engine block behavior.

## Generate Project

```bash
xcodegen generate
```

## Build (local machine)

```bash
xcodebuild -project GitPhone.xcodeproj -scheme GitPhone -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

## Notes

- In restricted sandbox environments, SwiftData macro expansion can fail (`swift-plugin-server` malformed response). Build in normal Xcode/local host environment.
- `GitEngine` clone/fetch/fast-forward behavior is in place via `SwiftGitX`.
- Remaining git-engine gaps are listed below (notably real SSH host-key fingerprint wiring and integration coverage against real remotes).

## Next Implementation Steps

1. Wire real SSH host-key fingerprints from transport callbacks (replace the current synthetic `host:port` hash flow).
2. Complete per-repo SSH key override support end-to-end (repo-level UI/settings plus credential resolution honoring `sshKeyOverrideID` before host default keys).
3. Re-enable full `BackgroundSyncCoordinator` production path (task registration, scheduling, execution, and sync result persistence).
4. Add integration tests for real clone/sync against controlled test remotes.

## License

This project is licensed under the MIT License. See `LICENSE` for details.

## Community and Security

- Contributing guide: `CONTRIBUTING.md`
- Code of Conduct: `CODE_OF_CONDUCT.md`
- Security policy: `SECURITY.md`
- Third-party notices: `THIRD_PARTY_NOTICES.md`
