# Contributing to Atlas

Thanks for helping improve Atlas. Keep changes focused, behavior-preserving
unless the issue calls for a product change, and grounded in Apple platform
conventions.

## Setup

Requirements and commands live in [Docs/DEVELOPMENT.md](Docs/DEVELOPMENT.md).
Generate the Xcode project before building:

```sh
xcodegen generate
```

`project.yml` is the source of truth. Do not hand-edit generated Xcode project
files. The repository does not pin an Apple development team; select your own
team and bundle identifiers locally for device builds, and never commit signing
material. The canonical `sh.cmf.atlas` identifiers are maintainer-owned.

## Before opening a pull request

- Keep feature code in `Atlas/Features`, shared UI in `Atlas/Components`, local
  models and stores in `Atlas/Models`, and non-UI helpers in `Atlas/Support`.
- Add or update focused tests for stores, recommendations, playback/download
  decisions, backup behavior, or Piped decoding.
- Run `swift test --package-path PipedKit` when PipedKit changes.
- Regenerate the project and run the narrowest relevant Atlas tests, then a
  simulator build for app-wide changes.
- Update public documentation when behavior, data handling, network
  destinations, settings, or build steps change.

Pull requests run the same project-generation, formatting, package-test,
simulator-build, and app-test gates in GitHub Actions.

## Swift formatting

Atlas uses the `swift-format` tool bundled with Xcode and the checked-in
`.swift-format` configuration. The configuration preserves the repository's
four-space indentation and 120-column target.

Format changed Swift files before opening a pull request:

```sh
xcrun swift-format format --in-place --configuration .swift-format <files>
```

Lint the full Swift tree:

```sh
xcrun swift-format lint --recursive --parallel --strict \
  --configuration .swift-format \
  Atlas AtlasTests PipedKit/Sources PipedKit/Tests PipedKit/Package.swift
```

Please avoid committing credentials, `.env` files, signing identities,
provisioning profiles, personal development-team IDs, or user-specific Xcode
state.
