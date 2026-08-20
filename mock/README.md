# RideGuard Mock — fake Bolt & Uber offer screens

An Expo app that renders convincing Bolt Driver and Uber Driver ride-offer
cards on demand, so the RideGuard overlay can be tested **without waiting for
a real ride request**.

This is a test harness, not a product. It has no backend, no network, no
persistence.

---

## Run it

```bash
cd mock
npm install
npx expo run:android        # builds + installs a dev client on a connected device
```

Or, for a quick look without a native build:

```bash
npx expo start              # then press 'a', or scan with Expo Go
```

> Expo Go is fine for checking the layout, but **use `expo run:android` for
> real overlay testing** — you want a proper installed APK with the correct
> package name.

Build a shareable APK:

```bash
npx expo prebuild --platform android
cd android && ./gradlew assembleRelease
```

---

## Two contracts you must not break

### 1. The package name is `com.rideguard.mock`

Set in `app.json` under `android.package`. RideGuard's accessibility service
filters events by package name — that filter is the single most important
battery decision in the whole app — and this package is explicitly whitelisted
in `android/app/src/sideload/res/xml/accessibility_service_config.xml`.

Change the package here and the overlay simply never appears.

### 2. The platform marker must stay visible

Every offer screen renders exactly one of:

```
__rg_platform=bolt
__rg_platform=uber
```

The mock cannot claim Bolt's or Uber's real package name, so this marker is how
`OfferParserRegistry` decides which parser to run. It is styled at `fontSize: 1`
with `opacity: 0.02` — effectively invisible to a human, fully present in the
accessibility tree.

**Never** give it `display: 'none'`, `opacity: 0`, zero width/height, or
`accessibilityElementsHidden`. The tree reader skips any node where
`isVisibleToUser` is false or `bounds.area <= 0`, and the marker would vanish
along with the routing.

### And a third: everything is a `<Text>`

React Native maps `<Text>` onto a native Android `TextView`, which is what the
accessibility tree exposes. Render a fare into an SVG, a Canvas or an Image and
the reader goes blind — the harness would then appear to work while testing
nothing at all.

---

## Layout, and why it is shaped this way

```
┌─────────────────────────┐
│                         │  ~38%  map placeholder (textless on purpose)
│         MAP             │
├─────────────────────────┤
│  Comandă nouă   ⏱ 12    │
│  Comfort                │  ~62%  offer card
│  32,50 lei              │
│  Preluare 2,4 km · 5min │
│  Destinație 8,1km ·18min│
│  ┌───────────────────┐  │
│  │      Refuză       │  │
│  ├───────────────────┤  │
│  │     ACCEPTĂ       │  │  ← pinned to the bottom edge
│  └───────────────────┘  │
└─────────────────────────┘
```

RideGuard clamps its HUD out of the **bottom 34%** of the display
(`OverlayBounds.FORBIDDEN_BOTTOM_FRACTION`) precisely so it can never sit over
that Accept button. Android silently discards touches that arrive at a view
with `filterTouchesWhenObscured="true"` while another window overlaps it — so
an overlay covering Accept means the driver taps, nothing happens, the offer
expires, and he blames the app. Correctly.

**This screen is how that clamping gets verified.**

---

## Presets

| Preset            | What it proves |
|-------------------|----------------|
| `Good`            | Short deadhead, decent paid leg → should read GOOD |
| `Classic trap`    | 6 lei, 5 km pickup, 2 km trip → should read BAD, loss-making |
| `Long deadhead`   | Fare looks fine until you price the 9 km drive to reach it |
| `Surge`           | Multiplier chip on the card — exercises the Multiplier token |
| `Long trip`       | Big numbers; 120 lei over 49 km is only ~1.08/km net → MARGINAL |
| `Single distance` | No pickup leg at all → must surface as UNKNOWN, never a green light |

The **Auto-fire loop** toggle cycles random presets hands-free, which is how
you watch the HUD behave over a stretch without touching the phone.

The **countdown** ticks every second. Only that one `<Text>` changes; every
other node keeps identical props. That is deliberate — it verifies the
overlay's fingerprint dedupe, because a HUD that re-renders on every tick
would strobe under the driver's eyes at exactly the wrong moment.

---

## Testing the overlay end to end

1. Build and install **both** APKs:
   ```bash
   cd android && ./gradlew :app:installSideloadDebug
   cd ../mock && npx expo run:android
   ```
2. Open RideGuard, complete onboarding (car, consumption, fuel price).
3. Enable the accessibility service — Settings → Accessibility → **RideGuard
   offer reader**. Look under *Installed apps* or *Downloaded apps*.
4. Grant the battery exemption. On Xiaomi/Huawei/Oppo/Vivo/Samsung, also do the
   OEM autostart step the settings screen prompts for.
5. Open the mock, pick a platform, tap a preset, hit **Fire offer**.
6. Confirm:
   - the HUD appears within a fraction of a second,
   - the numbers match what the card says,
   - `Classic trap` shows **red** and a negative net,
   - `Single distance` shows **dimmed / UNKNOWN**, not a confident verdict,
   - the HUD **cannot be dragged over the Accept button**,
   - the HUD does **not** flicker as the countdown ticks.

---

## Keeping the two codebases honest

The strings this app renders are asserted, byte for byte, by
`android/domain/src/test/kotlin/com/rideguard/domain/MockHarnessContractTest.kt`.

If you change wording or number formatting here, regenerate and update that
test:

```bash
cd mock
npx tsc --ignoreConfig src/offer.ts src/format.ts src/offerText.ts \
    --outDir /tmp/mockjs --module commonjs --target es2022 --skipLibCheck

node -e "const{PRESETS,draftToOffer,PLATFORMS}=require('/tmp/mockjs/offer.js');
         const{previewLines}=require('/tmp/mockjs/offerText.js');
         for(const p of PLATFORMS) for(const s of PRESETS)
           console.log(p, s.id, JSON.stringify(previewLines(p,draftToOffer(s.draft,p))))"
```

Then run `./gradlew :domain:test` in `android/`. A formatting change that would
have silently blanked the HUD on a real phone instead fails on the JVM in
seconds.

---

## File map

```
mock/
├── app.json                    package name + Expo config
├── app/
│   ├── _layout.tsx             expo-router stack
│   ├── index.tsx               control panel: platform, fields, presets, auto-fire
│   └── offer.tsx               the offer screen — owns geometry and the countdown
└── src/
    ├── offer.ts                Offer model, presets, draft↔offer conversion
    ├── format.ts               ALL number formatting (ro comma vs en dot)
    ├── offerText.ts            every string the card renders, in render order
    ├── theme.ts                per-platform colours, CARD_FRACTION / MAP_FRACTION
    └── components/
        ├── OfferCard.tsx       one card for both platforms
        ├── Controls.tsx        control-panel inputs
        └── PlatformMarker.tsx  the `__rg_platform=` marker
```

If a number ever renders wrong, fix it in `format.ts` — never in a screen.
