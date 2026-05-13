# Contributing

Hermes Desktop - OS1 Edition is a Swift Package macOS app. Keep changes
small, tested, and aligned with the existing SwiftUI/service boundaries.

## Setup

Requirements:

- macOS 14 or newer
- Xcode or Command Line Tools with Swift 6.1 support
- Node.js if you want Realtime voice to launch the Orgo MCP bridge

Build and test:

```sh
swift test
./scripts/build-macos-app.sh
```

The app bundle is written to `dist/OS1.app`.

For parallel SwiftPM work, install the local guard hooks once per checkout:

```sh
./scripts/install-hooks.sh
```

Use a per-process scratch path when focusing a test so concurrent agents do not
share `.build` state:

```sh
make test-focus FILTER=CompanySandboxProfileTests
```

## Development Rules

- Do not commit secrets, local machine paths, `.env` files, signing
  certificates, release zips, or build output. SwiftPM `.build/` and
  `.build-*/` directories must never be staged.
- Prefer Keychain-backed credential flows over environment-only setup.
- Keep public defaults conservative. Anything that gives the voice model
  shell/admin power must be explicit opt-in.
- Add or update tests when behavior changes.
- Run `swift test` before opening a pull request.

## Pull Requests

Include:

- what changed
- how you tested it
- any user-visible behavior change
- any security or permission implications
