# RideGuard for iOS

**Nothing here has ever been compiled.** It was written on a Linux machine with
no Swift toolchain and no Xcode. Treat the first build as a debugging session,
not a formality — see [What to check first](#what-to-check-first).

---

## What you need before this runs

| | Needed? | Why |
|---|---|---|
| **A Mac** | **Yes, mandatory** | Xcode only runs on macOS. There is no cross-compiler, no cloud shortcut worth the trouble, and no way to produce a signed `.ipa` without it. |
| **An iPhone** | **Yes, for real testing** | The Simulator can run the app and the unit tests, but it cannot test the share extension against a real screenshot taken in the Bolt app, cannot test a Live Activity properly, and cannot test OTA install at all. |
| **Apple Developer Program — €99/yr** | Yes, for anything lasting | A *free* Apple ID can sideload to your own phone, but the build **expires after 7 days** and must be reinstalled from Xcode, and it cannot do over-the-air updates at all. |

So: **a Mac is non-negotiable, an iPhone is needed for anything real.** The Mac
is the hard blocker — with a Mac and no iPhone you can still build and run the
whole app in the Simulator; with an iPhone and no Mac you can do nothing.

### The cheap way to try it

A free Apple ID gets you onto your own phone in about ten minutes, with two
catches: it dies after 7 days, and the in-app updater will not work. That is
fine for finding out whether the app is worth paying for.

### The real way

Apple Developer Program, then an **ad-hoc** distribution profile with each
target phone's UDID registered (yours and your friend's — the limit is 100
devices per year). That is what makes `itms-services://` OTA updates work, which
is the iOS half of "upload to GitHub and it updates itself".

---

## Building

```bash
brew install xcodegen
cd ios
xcodegen generate          # writes RideGuard.xcodeproj — do not commit it
open RideGuard.xcodeproj
```

There is deliberately no `.xcodeproj` in the repository. A `project.pbxproj` is
a generated file nobody can review and every branch conflicts on;
[`project.yml`](project.yml) is the same information in a form a diff can
explain.

Then, once, in Xcode:

1. Set **Signing & Capabilities → Team** on all four signable targets
   (`RideGuard`, `RideGuardShareExtension`, `RideGuardWidgets`, and
   `RideGuardCore`). Or set `DEVELOPMENT_TEAM` once in `project.yml` and
   regenerate.
2. Create the **App Group** `group.com.rideguard.shared` and enable it on the
   app *and* the share extension. This one matters more than it looks: without
   it the extension reads a default vehicle profile out of its own container
   and produces confidently wrong numbers, which is the worst failure this app
   can have.
3. Bundle IDs are `com.rideguard.app`, `.app.share`, `.app.widgets`. Change the
   prefix if that namespace is not yours.

Domain tests need none of the above and run without Xcode:

```bash
swift test          # RideGuardCore only — Foundation, no UIKit
```

---

## What the iOS app actually is

It is **not** the Android app. iOS cannot read another app's screen and cannot
draw over another app — both are sandbox limits with no entitlement and no
workaround. [`docs/ios-platform-limits.md`](../docs/ios-platform-limits.md)
covers every API that was considered and why each one fails.

What survives that constraint:

| | Android | iOS |
|---|---|---|
| Verdict appears by itself over the offer card | yes | **no — impossible** |
| Screenshot → share → verdict | — | yes, a few seconds |
| Type the numbers → verdict | yes | yes, and it is the primary flow |
| Same parser and same economics | yes | yes |
| Updates itself from GitHub | yes, installs the APK | yes, via `itms-services://` (needs the paid account) |

Realistically the iOS app is a **calculator you reach for**, not a HUD that
warns you. On a 12-second offer timer, the screenshot round trip is often too
slow. That is worth knowing before anyone pays €99.

---

## What to check first

Nothing here has been near a compiler, so the first build will produce errors.
Highest-risk areas, in order:

1. **`RideGuard/Capture/`** — Vision API surface (`VNRecognizeTextRequest`,
   revision constants, `recognitionLanguages`) is the easiest thing to get
   subtly wrong from memory.
2. **`RideGuardLiveActivity/` + `RideGuardWidgets/`** — ActivityKit is strict
   about attribute types and `Info.plist` keys, and the app target needs
   `NSSupportsLiveActivities`.
3. **App Group plumbing in `Persistence.swift`** — verify the app and the
   extension genuinely see the same container, by writing in one and reading in
   the other. Do not assume.
4. **`Core/Parse/`** — mirrors the Kotlin parser. If a number comes out wrong,
   diff it against
   `android/domain/src/main/kotlin/com/rideguard/domain/parse/` rather than
   guessing; the Kotlin side has 72 passing tests and is the reference.

Run `swift test` before opening Xcode. It exercises the parser, the economics
and the update-manifest rules with no signing and no device, so it separates
"the logic is wrong" from "the project is misconfigured".
