# RideGuard

Reads the ride offer on screen in **Bolt Driver** and **Uber Driver**, works out
what the ride *actually* pays after commission, fuel and wear, and shows it in a
small floating window while the driver still has time to decide.

Everything happens on the phone. Nothing is sent anywhere.

---

## Why it exists

Both platforms show a fare. Neither shows:

- the fuel burned driving to the passenger (the **deadhead** leg),
- tyres, servicing and depreciation on those kilometres,
- what the ride works out to **per hour**.

A driver gets roughly **10–15 seconds** to accept. Nobody does that arithmetic
in ten seconds, so the bad offers that *look* fine get accepted all shift.

The number that catches them is the **deadhead ratio** — pickup km ÷ trip km.
A 6 lei ride with a 5 km pickup and a 2 km trip is a straight loss, and it does
not look like one under time pressure.

---

## Repository layout

```
co/
├── android/     Kotlin. The real app. Reads the screen, draws the HUD.
├── mock/        Expo. Fake Bolt/Uber offer screens for testing without real rides.
├── ios/         Swift. Domain parity + manual entry + Vision OCR share extension.
└── docs/
```

---

## Status

| Piece | State |
|---|---|
| `:domain` — parsing, economics, verdicts | **42 JVM tests passing** |
| `:capture` — accessibility + OCR readers | compiles |
| `:overlay` — floating HUD | compiles |
| `:data` — settings | compiles |
| `:app` — onboarding, settings, services | **both flavour APKs build** |
| `mock` — Expo harness | typechecks clean, contract-tested against the parser |
| `ios` | code complete, **unbuilt and untested** — see caveat below |

```bash
cd android
./gradlew :domain:test              # 42 tests, ~10s, no device needed
./gradlew :app:assembleSideloadDebug
```

---

## Architecture

```mermaid
flowchart TD
  BOLT["Bolt Driver<br/>ee.mtakso.driver"] --> AS
  UBER["Uber Driver<br/>com.ubercab.driver"] --> AS
  MOCK["Mock harness<br/>com.rideguard.mock"] --> AS

  AS["AccessibilityService<br/>packageNames filter"] --> SNAP{{"ScreenSnapshot"}}
  OCR["ProjectionOcrSource<br/>play flavour"] -.-> SNAP
  REP["ReplaySource<br/>recorded fixtures"] -.-> SNAP

  SNAP --> GATE["debounce 120ms<br/>+ fingerprint dedupe"]
  GATE --> SEL{"which platform?"}
  SEL -->|bolt| BP["BoltOfferParser"]
  SEL -->|uber| UP["UberOfferParser"]
  BP --> RO["RideOffer"]
  UP --> RO
  RO --> CALC["ProfitCalculator<br/>commission · fuel · wear"]
  CALC --> V["Verdict<br/>green / amber / red / unknown"]
  V --> HUD["Draggable HUD<br/>TYPE_ACCESSIBILITY_OVERLAY"]
```

Three readers, one `ScreenSource` interface, and nothing downstream can tell
them apart. `:domain` has **zero Android dependencies**, which is what makes
the 42 tests run on the JVM in seconds with no emulator.

---

## The five decisions that matter

**1. Native Kotlin, not Flutter or React Native.** Every capability here —
`AccessibilityService`, `MediaProjection`, `WindowManager` overlays — is a
native Android API with no cross-platform equivalent. A bridge would add a
serialization boundary and a second runtime to a problem with zero
cross-platform surface, and community overlay plugins spin up an entire second
engine for a HUD that must stay featherweight.

**2. `packageNames` in the accessibility config.** Restricting the service to
three packages means it is completely dormant — no wakeups, no tree walks, no
battery cost — outside Bolt and Uber. This one XML attribute is worth more than
any optimisation in the code.

**3. `TYPE_ACCESSIBILITY_OVERLAY`, not `TYPE_APPLICATION_OVERLAY`.** Adding the
window from inside the accessibility service means no "draw over other apps"
permission at all, **and** immunity to `Window.setHideOverlayWindows(true)` —
an API available since Android 12 that force-hides ordinary overlays. If either
driver app ever switches that on, an ordinary overlay just vanishes.

**4. The HUD is clamped out of the bottom 34% of the screen.** Android silently
discards touches arriving at a view with `filterTouchesWhenObscured="true"`
while another window overlaps it. Cover the Accept button and the driver taps,
nothing happens, the offer expires. The clamp is not a nicety.

**5. Cost is charged on the *full* distance.** Pickup plus trip, not just the
paid leg. That gap is where the money quietly disappears, and closing it is the
entire point.

---

## Two build flavours, one codebase

| | `sideload` | `play` |
|---|---|---|
| Reader | AccessibilityService | MediaProjection + ML Kit OCR |
| Speed | single-digit ms | 200–500 ms per pass |
| Battery | negligible when idle | real cost |
| Overlay permission | not needed | required |
| Suppressible by host app | no | yes |
| Play Store | would be rejected | fine |

Google Play requires accessibility services to genuinely serve users with
disabilities, enforced via a Permissions Declaration Form. A ride-profit
analyser does not qualify — every app in this category that ships on Play uses
OCR. The `ScreenSource` interface makes this a build-config swap, not a fork.

Use `sideload` for yourself and your friend.

---

## Getting it running

```bash
# 1. The app
cd android
./gradlew :app:installSideloadDebug

# 2. The test harness
cd ../mock
npm install
npx expo run:android
```

Then:

1. Open RideGuard → onboarding asks for **car, fuel type, consumption per
   100 km, fuel price**, then wear per km, then your targets.
2. Enable **Settings → Accessibility → RideGuard offer reader**.
3. Grant the battery exemption (and the OEM autostart step it prompts for on
   Xiaomi / Huawei / Oppo / Vivo / Samsung — those kill background services
   regardless of what stock Android allows).
4. Open the mock, tap a preset, hit **Fire offer**.

Verify: HUD appears fast, numbers match, `Classic trap` reads red and negative,
`Single distance` reads dimmed/UNKNOWN, the HUD cannot be dragged over Accept,
and it does not flicker as the countdown ticks.

---

## Build this next: record mode

Settings → Developer → **Record offers to disk**.

Run one real shift with it on. You come back with dozens of genuine Bolt and
Uber cards — surge, normal, short, long, and the malformed ones nobody would
think to invent — as JSON fixtures. From then on the parser is tuned on a
laptop against real data with instant feedback, instead of in a parked car at
2am waiting for a ride request.

That is why `ReplaySource` is a first-class `ScreenSource` and not a testing
afterthought.

---

## Honest caveats

**The parsers are heuristic and untuned.** No real screenshots existed when
this was built, so `BoltOfferParser` and `UberOfferParser` assemble offers from
reading order — headline fare in the largest type, deadhead leg above the paid
leg. That is how both cards are actually laid out, and it passes every mock
contract test, but it is the first thing to tighten once record mode has run.

**Verify gross-vs-net against a real payout statement.** Whether the card shows
the fare before or after commission varies by market. Getting it wrong skews
every number by the commission rate. It is a per-platform setting for exactly
this reason.

**iOS is code-complete but unbuilt.** No Xcode on this machine, so nothing in
`ios/` has been compiled or run. It also cannot do the overlay or screen
reading — those are hard sandbox limits with no entitlement and no workaround.
What it can do is the identical domain maths, onboarding, manual entry, history,
and a Share Extension that OCRs a screenshot with Vision. Treat it as a draft.

**Third-party tools are against both platforms' driver terms.** A read-only
advisory HUD is the low-risk end of that spectrum; auto-tapping Accept via
`performAction()` is the high-risk end, and is also what provokes the
anti-overlay countermeasures in the first place. This app deliberately only
reads.
