## What

<!-- One or two sentences: what changes for the user. -->

## Why

<!-- The problem or request this solves. Link issues with "Closes #123". -->

## How it was tested

- [ ] `scripts/test.sh` passes (motion, gestures, input safety, performance)
- [ ] Tried on a real trackpad (which gestures?)
- [ ] Light and dark appearance checked (UI changes)

## Input safety

- [ ] This change does not touch `EventGate.swift`, **or** `Rim --gate-test` passes and every new path fails open
      (input must never be blocked if Rim stalls, crashes or loses Accessibility).
