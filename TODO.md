# Rim — TODO

Status as of 2026-11-11. Tick items off as they're done (`- [x]`).

## Launch blockers (owner)

- [ ] **Join the Apple Developer Program** and create a *Developer ID Application* certificate
  - [ ] Fill in `signing.env` (copy from `signing.env.example`)
  - [ ] Run `scripts/setup-signing.sh` once (stores notarization credentials)
  - [ ] `./release.sh` → signed, notarized, stapled DMG
- [ ] **Fix GitHub billing** (Settings → Billing and plans) so Actions can run
  - [ ] Watch the first CI run (GitHub runners use Xcode 16 / older Swift; Dependabot bumped checkout v7, cache v6, upload-artifact v7)
- [ ] **Buy `getrim.com`** (WHOIS showed it unregistered; `rimhq.com`, `rimformac.com` as fallbacks)
- [ ] **Choose a license and business model** (MIT / source-available / paid with trial). The public repo currently has no license, i.e. "all rights reserved"

## Real-trackpad verification (owner)

Built and covered by tests, but not yet confirmed by hand:

- [ ] Apple-style haptics fire while Rim is in the background (if not: Settings → Haptics → Custom patterns, then report)
- [ ] Pointer stays still during edge / corner gestures, and the stand-in cursor looks right
- [ ] Tip-swipe (rest a finger, slide the neighbour) for seek / volume / tabs
- [ ] Two-finger swipe left / right in an app without native swipe navigation
- [ ] Corner taps after the corner fix (#34)
- [ ] Magic Trackpad (external) — never tested
- [ ] Anything that fires when it shouldn't or misses: run `Rim --record 60 file.csv`, then replay with `Rim --replay file.csv`

## Engineering — next

- [ ] Fix whatever real-trackpad verification turns up (haptics, pointer freeze are core to the feel)
- [ ] **Sparkle automatic updates** (appcast on getrim.com, signed updates)
- [ ] **Update README and the welcome tour** for tip-swipe, two-finger swipe, gesture presets, centred feedback pills
- [ ] **Re-tune the learning system** from real data: learned tap limits became too tight (patched with floors of 2 mm / 0.25 s in #34)
- [ ] **First release**: tag `v1.0.0` → release workflow builds the universal DMG and drafts the GitHub release
- [ ] Licensing / trial flow (depends on the business-model decision)

## Engineering — later

- [ ] Profiles (Work, Video, Presentation) that switch automatically by app or display
- [ ] Pointer & Scroll page for the trackpad: precision mode, speed beyond the macOS maximum (mouse side is covered by Mac Mouse Fix)
- [ ] Brightness for external displays (only the built-in display today)
- [ ] Draw-a-shape shortcuts
- [ ] Settings import / export and sync

## Done recently

- [x] Edge + corner zones with tap, double-tap, hold, slide (levels, scroll, app switcher, actions), presets, per-app rules
- [x] Multi-finger taps, tip-tap (fitted to real measurements), tip-swipe, two-finger swipe, gesture presets
- [x] Accidental-touch rejection: typing pause, palm size, resting / drumming hand, border brushes, learned thresholds
- [x] Motion: 1€ filter, acceleration, momentum, repeat speed-up, rubber band, springs
- [x] Fail-safe input gate (never freezes input), pointer freeze, Apple-style haptics, centred pop-in feedback
- [x] Rename to Rim, monochrome icon, compact toolbar-tab Settings, hardened-runtime signing pipeline, GitHub repo + CI + release workflow
