# What iOS forbids, what it permits anyway, and what that costs

Short version: **no API grants either capability, and the HUD exists regardless.**

Reading another app's screen and drawing over another app are both blocked by
the application sandbox. There is no entitlement for either, no private API
worth shipping, and none of that has changed. What exists instead is a pair of
features built for entirely different purposes which, combined, land in the
same place: **ReplayKit** sees the whole screen, **Picture-in-Picture** floats
above other apps, and neither one can do the other's job.

This document exists so nobody spends a week rediscovering either half — the
wall, or the one way around it.

---

## What the Android app does, and the iOS equivalent

| Capability | Android | iOS |
|---|---|---|
| Read another app's on-screen content | `AccessibilityService` / `MediaProjection` | No API — but a **ReplayKit broadcast extension** is handed system-wide frames |
| Draw a window over other apps | `TYPE_APPLICATION_OVERLAY` | No API — but a **custom Picture-in-Picture window** floats above them |
| Stay resident in the background | Foreground / accessibility service | No API — but `UIBackgroundModes: audio` plus a live PiP window holds the process up |
| Do all three in one process | yes | **no** — and this is the part with no workaround at all |

That last row is the real constraint. Each capability is reachable; they are
simply not reachable *together*, because the process that may see the screen is
forbidden to draw, and the process that may draw is forbidden to see.

---

## APIs considered, and what each one turned out to be worth

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
positioned, and cannot show arbitrary interactive UI. On an iPhone 11 the Live
Activity is Lock Screen only, which is invisible while Bolt is in the
foreground — that is, invisible at the only moment that matters.

The one exception to all of this is the Picture-in-Picture window, which *is* a
`UIWindow`-class surface that survives app switching. See below.

### `ReplayKit` → half the answer

`RPScreenRecorder` records or broadcasts **your own app** and is indeed useless
here. But `RPBroadcastSampleHandler`, inside a **Broadcast Upload Extension**,
receives system-wide screen samples for the duration of an active broadcast.
That is the only place on iOS where another app's pixels are legitimately
available, and it is what `RideGuardBroadcast` is.

It comes with four costs, all real, none fatal:

- **The driver must start it.** One tap per shift, from the in-app picker or a
  long-press on Control Centre's screen-record button. It cannot be automatic.
- **The recording indicator stays lit** for as long as it runs. There is no way
  to suppress it, and no attempt should be made to.
- **~50 MB memory ceiling.** Exceed it and iOS kills the extension mid-shift,
  silently, with no useful diagnostic. Everything in `SampleHandler.swift` —
  the 3 fps throttle, the per-frame `autoreleasepool`, the crop-and-downscale
  before Vision ever runs — is written around that number.
- **It cannot draw.** The extension is a headless uploader. This is the half it
  does not have.

### Custom Picture-in-Picture → the other half

A PiP window is the one window class iOS keeps floating above another app, and
**it is not required to contain video**.
`AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`
will float an `AVSampleBufferDisplayLayer` fed with frames the app rendered
itself. So the HUD is, as far as iOS is concerned, a video the driver happens
to be watching while using Bolt.

Requirements, each of which fails silently if missed:

- `UIBackgroundModes: audio` plus an active `AVAudioSession`, or the process is
  suspended the instant the driver switches to Bolt — which is always.
- That session **must** be `.playback` with `.mixWithOthers`, or the driver's
  music and navigation stop dead when the HUD appears.
- The playback delegate must report an *infinite* time range and never-paused,
  or AVKit decides the content is not playable and quietly declines to start.

Be honest about what this is: it is outside what PiP is for, Apple can close it
in any release, and App Store review would reject it on sight — background
audio with no audio is Guideline 2.5.4, and PiP with no media is its neighbour.
It is shipped because on an iPhone 11 there is no Dynamic Island, so no
glanceable Live Activity while Bolt is foreground, and this is the only thing
left that puts a number in front of the driver during the decision.

### Bridging the two → App Group + Darwin notification

The two halves are separate processes and iOS offers them no shared memory, no
XPC and no `NotificationCenter`. Exactly two things cross the boundary, and each
lacks what the other has: a **Darwin notification** carries no payload, and a
**file in the App Group container** emits no signal when it changes.

Used together they work — write the payload, then post the name. The order is
load-bearing, and reversing it costs updates with nothing logged: a reader woken
before the bytes land reads the previous verdict. See
`ios/RideGuard/Core/Live/LiveVerdict.swift`.

Note also that the Darwin callback is a C function pointer and **cannot capture
context**, which is why the channel parks its handler in a static and supports
exactly one observer.

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
   currency. Deliberately no wear-per-km and no commission slider: both
   Romanian cards already print the driver's net take, and a commission field
   invites a driver to set one and be wrong by that percentage on every offer.
3. **Live HUD.** ReplayKit reads the screen, Vision recognises the card, the
   shared domain computes the verdict, and a custom PiP window floats it over
   Bolt. This is the Android feature, at the cost of one tap per shift and a
   lit recording indicator.
4. **Share Extension + Vision OCR.** Screenshot an offer, share it to RideGuard,
   get the same verdict from the same parser. Needs no broadcast and no PiP, so
   it is the fallback when the live path is not armed — and the fastest way to
   test a parser change.
5. **Manual quick-entry.** Type the fare and the two legs. Nothing to mis-read,
   so it is also the reference when a parsed number looks wrong.
6. **Settings and history.** Thresholds, gross-vs-net per platform, and a log of
   evaluated offers with what the driver actually did about each.

---

## Practical consequence

Both platforms now answer "should I take this?" **while the offer is on
screen**. What differs is what it costs to get there.

| | Android | iOS |
|---|---|---|
| Arming it | once, in Settings | one tap per shift |
| While it runs | nothing visible | recording indicator lit |
| Battery | negligible | noticeable — full-screen capture plus OCR |
| Can the platform take it away? | unlikely | **yes, in any release** |
| Store-distributable | sideload only | TestFlight / EU marketplace only |

So iOS parity is real but conditional, and the condition worth watching is the
last two rows. The PiP overlay is the piece resting on an unintended use of an
Apple API; if it ever stops working, the share-extension path degrades
gracefully and keeps the app useful, which is why that path is maintained
rather than deleted.

---

## Build status

Two halves, in different states:

- **`RideGuardCore` is compiled and tested.** Parsers, token scanner, profit
  calculator, platform routing and update rules: **85 tests, all passing**, run
  on Linux with the Swift 6.1 toolchain. Foundation-only is what makes that
  possible, which is why the rule is worth defending.
- **Everything importing SwiftUI, AVKit, Vision, ReplayKit or ActivityKit has
  never been compiled** — those SDKs exist only on a Mac. The sources parse
  cleanly and have been audited, but the first Xcode build is a debugging
  session.

`ios/verify.sh` runs the whole checkable surface in one command, with signing
off, so a compile error cannot hide behind a certificate problem.
