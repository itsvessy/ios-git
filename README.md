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
- Git engine scaffold:
  - Clone/sync API with protocol abstraction
  - File-backed implementation enforcing dirty/diverged/background-deferred states
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
- `GitEngine` currently uses a file-backed scaffold behind `GitClient`; replace with real libgit2/SwiftGitX implementation without changing UI/domain interfaces.

## Next Implementation Steps

1. Replace `FileSystemGitClient` with libgit2-backed clone/fetch/fast-forward pipeline.
2. Wire real host key fingerprints from SSH transport callbacks.
3. Implement per-repo SSH key override selection in UI/settings.
4. Re-enable full `BackgroundSyncCoordinator` task registration/execution path.
5. Add integration tests around real clone/sync against test remotes.
