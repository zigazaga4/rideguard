/**
 * Every string the offer card puts on screen, in one place.
 *
 * `OfferCard` renders exactly these and nothing else, and the control panel
 * previews exactly these — so what you read in the preview is literally what
 * the accessibility tree will contain.
 */

import { formatLeg, formatMoney, formatMultiplier, formatRating, styleFor } from './format';
import type { Offer, Platform } from './offer';

interface Copy {
  header: string;
  fareCaption: string;
  pickupLabel: string;
  dropoffLabel: string;
  surgeLabel: string;
  accept: string;
  decline: string;
}

/**
 * Romanian for Bolt, English for Uber — matching the markets each app is
 * being tested against. Several of these words double as the offer keywords
 * `HeuristicOfferParser.canParse` gates on ("comandă", "refuză", "trip",
 * "pickup", "accept"), so do not "tidy" them away.
 */
export const COPY: Record<Platform, Copy> = {
  bolt: {
    header: 'Comandă nouă',
    fareCaption: 'Preț estimat',
    pickupLabel: 'Preluare',
    dropoffLabel: 'Destinație',
    surgeLabel: 'Tarif dinamic',
    accept: 'Acceptă',
    decline: 'Refuză',
  },
  uber: {
    header: 'Trip request',
    fareCaption: 'Your earnings',
    pickupLabel: 'Pickup',
    dropoffLabel: 'Dropoff',
    surgeLabel: 'Surge',
    accept: 'Accept',
    decline: 'Decline',
  },
};

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
  header: string;
  product: string;
  fare: string;
  fareCaption: string;
  rating: string | null;
  ratingGlyph: string | null;
  surge: string | null;
  surgeLabel: string;
  pickupLabel: string;
  pickupLeg: string | null;
  pickupAddress: string;
  dropoffLabel: string;
  tripLeg: string | null;
  destinationAddress: string;
  accept: string;
  decline: string;
}

export function buildOfferText(platform: Platform, offer: Offer): OfferText {
  const style = styleFor(platform);
  const copy = COPY[platform];
  const showSurge = offer.surge !== null && offer.surge > 1;

  return {
    marker: markerText(platform),
    header: copy.header,
    product: offer.product,
    fare: formatMoney(offer.fare, style),
    fareCaption: copy.fareCaption,
    rating: offer.passengerRating === null ? null : formatRating(offer.passengerRating, style),
    // Uber keeps the rating text itself short ("4.85") because the Kotlin
    // BARE_RATING rule only trusts a starless rating in a block of <= 6 chars,
    // so the star lives in its own sibling node.
    ratingGlyph: platform === 'uber' && offer.passengerRating !== null ? '★' : null,
    surge: showSurge ? formatMultiplier(offer.surge as number, style) : null,
    surgeLabel: copy.surgeLabel,
    pickupLabel: copy.pickupLabel,
    pickupLeg: formatLeg(platform, 'pickup', offer.pickupKm, offer.pickupMin),
    pickupAddress: offer.pickupAddress,
    dropoffLabel: copy.dropoffLabel,
    tripLeg: formatLeg(platform, 'trip', offer.tripKm, offer.tripMin),
    destinationAddress: offer.destinationAddress,
    accept: copy.accept,
    decline: copy.decline,
  };
}

/**
 * Every `<Text>` the card will render, in render order, with the same
 * conditionals `OfferCard` applies — so the control panel preview is a true
 * picture of the accessibility snapshot. The countdown is omitted because it
 * changes every second.
 */
export function previewLines(platform: Platform, offer: Offer): string[] {
  const t = buildOfferText(platform, offer);
  const lines: (string | null)[] = [
    t.marker,
    t.header,
    t.product,
    t.surge,
    t.surge === null ? null : t.surgeLabel,
    t.fare,
    t.fareCaption,
    t.ratingGlyph,
    t.rating,
    t.pickupLeg === null ? null : t.pickupLabel,
    t.pickupLeg,
    t.pickupLeg === null ? null : t.pickupAddress,
    t.tripLeg === null ? null : t.dropoffLabel,
    t.tripLeg,
    t.tripLeg === null ? null : t.destinationAddress,
    t.decline,
    t.accept,
  ];
  return lines.filter((line): line is string => Boolean(line));
}
