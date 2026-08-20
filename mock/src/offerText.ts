/**
 * Every string the offer card puts on screen, in one place.
 *
 * `OfferCard` renders exactly these and nothing else, and the control panel
 * previews exactly these — so what you read in the preview is literally what
 * the accessibility tree will contain.
 *
 * The wording is transcribed from screenshots of the live Romanian apps, so
 * both platforms are in Romanian now and both accept buttons say `Potrivire`.
 * Several of these double as the offer keywords `HeuristicOfferParser.canParse`
 * gates on — "refuz", "cursă", "potrivire", "uber", "bolt" — so do not tidy
 * them away. Neither real card says "Acceptă" or "Accept" anywhere.
 */

import { formatLeg, formatMoney, formatMultiplier, formatRating, styleFor } from './format';
import type { Offer, Platform } from './offer';

interface Copy {
  /** Bolt spells the decline out on a white pill; Uber shows a bare ✕. */
  decline: string;
  accept: string;
  /** Icon prefix on the tier chip. Emoji, because it must survive as text. */
  productPrefix: string;
  payment: string;
  /** Reads `Cerere mare 1.1x` once the multiplier is appended. */
  surgePrefix: string;
  /**
   * Bolt prints the net disclaimer inside the fare's own text node; Uber gives
   * it a chip of its own. Whichever one is empty is simply not rendered.
   */
  fareSuffix: string;
  netChip: string;
  /** Bolt's grey two-line reassurance under the fare. */
  disclaimer: string;
  /**
   * Bolt's amber state chips. The mock has no model for driver radius,
   * scheduled pickup or time-of-day preferences, and inventing one would not
   * make the harness any better — but the chips are noise the parser has to
   * read past, so they are rendered exactly as captured.
   */
  stateChips: string[];
  /** Uber only, and only past [UBER_LONG_TRIP_MINUTES]. */
  longTrip: string;
}

export const COPY: Record<Platform, Copy> = {
  bolt: {
    decline: '✕  Refuză',
    accept: 'Potrivire',
    productPrefix: '🚗 ',
    payment: '💲 Numerar',
    surgePrefix: 'Cerere mare ',
    fareSuffix: ' (NET, taxe incluse)',
    netChip: '',
    disclaimer: 'Respingerea cursei nu va afecta rata de acceptare',
    stateChips: ['În afara razei', '📍 Locație', '⏱ Oră'],
    longTrip: '',
  },
  uber: {
    decline: '✕',
    accept: 'Potrivire',
    productPrefix: '👤 ',
    payment: 'Plata în numerar',
    // No Uber surge screenshot exists yet, so this borrows Bolt's Romanian
    // wording. The only part the parser needs is the trailing `1.8x`.
    surgePrefix: 'Cerere mare ',
    fareSuffix: '',
    netChip: 'Câștig net (fără comisionul Uber)',
    disclaimer: '',
    stateChips: [],
    longTrip: '🔀 Cursă lungă (peste 45 min.)',
  },
};

/** Uber only shows its long-trip chip past this. The chip text says so too. */
export const UBER_LONG_TRIP_MINUTES = 45;

/**
 * The marker the accessibility service uses to decide which parser to run,
 * since this app's package is `com.rideguard.mock` and not the real driver
 * app's. Must be rendered as a genuine, non-zero-bounds `<Text>`.
 */
export function markerText(platform: Platform): string {
  return `__rg_platform=${platform}`;
}

export interface OfferText {
  marker: string;
  /** `🚗 Bolt` / `👤 UberX`. */
  product: string;
  decline: string;
  accept: string;
  /** `11,62 lei` / `78,16 RON`. */
  fare: string;
  /** Bolt: ` (NET, taxe incluse)`, rendered INSIDE the fare node. Else null. */
  fareSuffix: string | null;
  /** Uber: `Câștig net (fără comisionul Uber)` as its own chip. Else null. */
  netChip: string | null;
  payment: string;
  surge: string | null;
  stateChips: string[];
  disclaimer: string | null;
  /** `Lichi • 5.0 ★` (Bolt) / `★ 5,00` (Uber). */
  passenger: string | null;
  pickupLeg: string | null;
  pickupAddress: string;
  tripLeg: string | null;
  destinationAddress: string;
  longTrip: string | null;
}

export function buildOfferText(platform: Platform, offer: Offer): OfferText {
  const style = styleFor(platform);
  const copy = COPY[platform];

  const rating =
    offer.passengerRating === null ? null : formatRating(offer.passengerRating, style);
  const showSurge = offer.surge !== null && offer.surge > 1;
  const showLongTrip =
    copy.longTrip !== '' && offer.tripMin !== null && offer.tripMin > UBER_LONG_TRIP_MINUTES;

  return {
    marker: markerText(platform),
    product: `${copy.productPrefix}${offer.product}`,
    decline: copy.decline,
    accept: copy.accept,
    fare: formatMoney(offer.fare, style),
    fareSuffix: copy.fareSuffix === '' ? null : copy.fareSuffix,
    netChip: copy.netChip === '' ? null : copy.netChip,
    payment: copy.payment,
    surge: showSurge ? `${copy.surgePrefix}${formatMultiplier(offer.surge as number)}` : null,
    stateChips: copy.stateChips,
    disclaimer: copy.disclaimer === '' ? null : copy.disclaimer,
    passenger:
      rating === null
        ? null
        : offer.passengerName === null
          ? rating
          : `${offer.passengerName} • ${rating}`,
    pickupLeg: formatLeg(platform, 'pickup', offer.pickupKm, offer.pickupMin),
    pickupAddress: offer.pickupAddress,
    tripLeg: formatLeg(platform, 'trip', offer.tripKm, offer.tripMin),
    destinationAddress: offer.destinationAddress,
    longTrip: showLongTrip ? copy.longTrip : null,
  };
}

/**
 * The fare and its net disclaimer share ONE text node on Bolt — they are one
 * line of mixed weight, and React Native flattens a nested `<Text>` into a
 * single Android TextView. The parser therefore sees
 * `11,62 lei (NET, taxe incluse)` and has to pull 11.62 out of it.
 */
export function fareLine(text: OfferText): string {
  return `${text.fare}${text.fareSuffix ?? ''}`;
}

/**
 * Every `<Text>` the card will render, in render order (which is also
 * top-to-bottom screen order, which is the order the accessibility tree comes
 * back in), with the same conditionals `OfferCard` applies.
 *
 * This is the contract `MockHarnessContractTest` is generated from. If you
 * move a node in `OfferCard`, move it here in the same commit or the Kotlin
 * tests are asserting a screen that no longer exists.
 *
 * The countdown contributes nothing: neither real app puts a number on it.
 */
export function previewLines(platform: Platform, offer: Offer): string[] {
  const t = buildOfferText(platform, offer);
  const legs: (string | null)[] = [
    t.pickupLeg,
    t.pickupLeg === null ? null : t.pickupAddress,
    t.tripLeg,
    t.tripLeg === null ? null : t.destinationAddress,
  ];

  // Bolt: the decline pill floats on the map ABOVE the card, so it reads first.
  const lines: (string | null)[] =
    platform === 'bolt'
      ? [
          t.decline,
          t.marker,
          t.product,
          t.payment,
          t.surge,
          ...t.stateChips,
          fareLine(t),
          t.disclaimer,
          t.passenger,
          ...legs,
          t.accept,
        ]
      : [
          t.marker,
          t.product,
          t.decline,
          t.fare,
          t.payment,
          t.passenger,
          t.surge,
          t.netChip,
          ...legs,
          t.longTrip,
          t.accept,
        ];

  return lines.filter((line): line is string => Boolean(line));
}
