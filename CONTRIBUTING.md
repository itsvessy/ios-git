# Contributing to GitPhone

Thanks for your interest in contributing.

## Prerequisites

- macOS with Xcode 16 or newer
- Command-line tools installed (`xcodebuild`, `xcrun`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Local Setup

1. Clone the repository.
2. Generate the Xcode project:

```bash
xcodegen generate
```

3. Build the app:

```bash
xcodebuild -project GitPhone.xcodeproj -scheme GitPhone -destination 'generic/platform=iOS Simulator' -derivedDataPath .derived-local CODE_SIGNING_ALLOWED=NO build
```

## Running Tests

Run unit tests:

```bash
xcodebuild -project GitPhone.xcodeproj -scheme GitPhone -destination 'platform=iOS Simulator,name=iPhone 16' -derivedDataPath .derived-local -only-testing:GitPhoneTests CODE_SIGNING_ALLOWED=NO test
```

If your simulator names differ locally, pick any available iPhone simulator.

## Pull Request Guidelines

- Keep PRs focused and small when possible.
- Include tests for behavior changes.
- Update documentation when behavior or interfaces change.
- Ensure the project builds and tests pass before opening a PR.
- Use clear titles and descriptions that explain user impact.

## Code Style

- Follow existing Swift style and module boundaries.
- Prefer explicit, testable domain behavior over implicit UI-side logic.
- Avoid introducing unrelated refactors in feature/fix PRs.

## Reporting Issues

- Use the issue templates in `.github/ISSUE_TEMPLATE`.
- For security issues, do not file a public issue. Follow `SECURITY.md`.

## License

By submitting a contribution, you agree that your contributions are licensed under the MIT License used by this repository.
