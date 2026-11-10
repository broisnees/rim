# Contributing to Rim

## Setup

```sh
./make-cert.sh             # once: local signing identity, keeps Accessibility granted across rebuilds
./build.sh --install --run
scripts/test.sh            # motion math, gesture engine, input safety, performance
```

Requires macOS 14+, Xcode 16+ (Swift 5.9 language mode). Icons are rendered from `logos/export/*.svg`
with `scripts/make-icon.sh` (needs `brew install librsvg`); the rendered files are committed.

## Workflow

- Branch from `main` (`feat/…`, `fix/…`, `ci/…`), open a pull request, and wait for CI.
- Commit messages follow Conventional Commits: `feat(gestures): …`, `fix(gate): …`, `docs: …`.
- Keep pull requests focused on one feature or fix.

## Rules that keep Rim safe

Rim sits in the system input path. Any change to `Sources/Rim/EventGate.swift` must keep these true, and
`Rim --gate-test` must pass:

1. The event tap exists only while Accessibility is granted, and is removed the moment it's revoked.
2. Swallowing input requires a live heartbeat from the gesture engine and a bounded session length.
3. Any reset of the touch pipeline releases everything.
4. Nothing in the tap callback may trap or block; when in doubt, pass the event.

## Tuning gestures with real data

```sh
.build/release/Rim --record 60 swipes.csv   # record raw touches
.build/release/Rim --replay swipes.csv      # see what your settings would fire (never changes volume/brightness)
```
