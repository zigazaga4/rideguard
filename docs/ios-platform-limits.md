# Why the iOS app cannot read the screen or draw an overlay

Short version: **it cannot, and no amount of engineering changes that.** Both
capabilities are blocked by the iOS application sandbox, not by a missing
entitlement or an unexplored API.

This document exists so nobody spends a week rediscovering it.

---

## What the Android app does, and the iOS equivalent

| Capability | Android | iOS |
|---|---|---|
| Read another app's on-screen content | `AccessibilityService` / `MediaProjection` | **None** |
| Draw a window over other apps | `TYPE_APPLICATION_OVERLAY` | **None** |
| Stay resident in the background indefinitely | Foreground / accessibility service | **None** — suspended in seconds |

---

## APIs considered, and why each fails

### `AccessibilityService` → no equivalent

iOS accessibility APIs (`UIAccessibility`, `AXUIElement`) are for *publishing*
your own app's accessibility information to assistive technology, and for
consuming it **within your own process**. There is no API for an app to read
another app's element tree. The macOS `AXUIElement` cross-process API does not
exist on iOS.

### `SYSTEM_ALERT_WINDOW` → no equivalent

An iOS app's `UIWindow` is confined to its own app. When the app is
backgrounded, its windows are removed from the screen entirely. There is no
window level, entitlement, or private API that survives app switching in a
shippable build.

The closest sanctioned things — **Live Activities**, the **Dynamic Island**,
and **widgets** — render *your own* data in system-controlled surfaces with
system-controlled layouts. They cannot float over another app, cannot be
positioned, and cannot show arbitrary interactive UI.

### `ReplayKit` → wrong tool

`RPScreenRecorder` records or broadcasts **your own app**. `RPBroadcastSampleHandler`
in a Broadcast Upload Extension does receive system-wide screen samples during
an active broadcast — but:

- The user must start the broadcast manually from Control Centre every session.
- The extension runs in a heavily memory-limited process (~50 MB) whose job is
  to *upload* samples, not analyse them locally and drive UI.
- It still cannot draw anything over the foreground app.

So even the one path that technically sees other apps' pixels cannot show a
driver anything.

### `ScreenCaptureKit` → macOS only

Not available on iOS. Worth stating explicitly because it comes up in searches
and looks like the answer.

### Shortcuts / App Intents → close, but not live

A Shortcut can pass data into your app, and Personal Automations can fire on
triggers. But there is no automation trigger for "an offer card appeared in
another app", and no way to render a result over that app. Useful for manual
flows, useless for a live HUD.

---

## What the iOS app therefore does

1. **Full domain parity.** The same models, number parsing, token scanning,
   parsers and profit calculator as the Kotlin `:domain` module. Same input,
   same numbers, same verdict. This is most of the value and it ports cleanly.
2. **Onboarding.** Car, fuel type, consumption per 100 km, energy price,
   currency, wear per km.
3. **Manual quick-entry.** Type the fare and the two legs, get the full verdict
   card. This is the primary interaction on iOS.
4. **Settings and history.** Thresholds, per-platform commission, gross-vs-net,
   plus a log of evaluated offers.
5. **Share Extension + Vision OCR.** The driver screenshots an offer and shares
   it to RideGuard; `VNRecognizeTextRequest` runs on-device, and the recognized
   text goes through the *same* `TokenScanner` / `OfferParser` pipeline.

That last one is the closest legitimate analogue to the Android feature. It is
two taps instead of zero, and it happens after the fact rather than during the
decision window — but it is real, it is App Store legal, and it reuses the
entire parsing stack.

---

## Practical consequence

On Android, RideGuard answers "should I take this?" **while the offer is on
screen**. On iOS it answers "was that worth taking?" and "what would this be
worth?" — a coaching tool rather than a live HUD.

If live decision support on iOS is the requirement, the honest answer is that
the platform does not permit it, and the effort is better spent tuning the
Android parsers against real recorded fixtures.

---

## Build status

The Swift sources in `ios/` are **code-complete but have never been compiled or
run** — there is no Xcode on the development machine this was written on.
Treat them as a reviewed draft, not a working app. Expect the usual first-build
friction: an Xcode project or `Package.swift` target wiring pass, and the Share
Extension's `NSExtensionActivationRule` needing a real device to exercise.
