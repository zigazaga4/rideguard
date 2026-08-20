/**
 * The offer model this harness renders, plus the one-tap presets.
 *
 * Deliberately tiny and platform-agnostic: exactly the fields RideGuard's
 * `RideOffer` carries, so a preset here maps one-to-one onto what the parser
 * is expected to reconstruct from the screen.
 */

export type Platform = 'bolt' | 'uber';

export const PLATFORMS: Platform[] = ['bolt', 'uber'];

/** `null` means "not rendered on the card at all" — not "zero". */
export interface Offer {
  /** Headline fare, in the platform's currency (lei for Bolt, € for Uber). */
  fare: number;
  /** Deadhead leg — the unpaid drive to the passenger. */
  pickupKm: number | null;
  pickupMin: number | null;
  /** Paid leg. */
  tripKm: number | null;
  tripMin: number | null;
  passengerRating: number | null;
  /** Surge / dynamic-fare multiplier. Only rendered when > 1. */
  surge: number | null;
  /** Product tier, e.g. "Comfort" / "UberX". Must be one of the names the
   *  Kotlin `BoltOfferParser` / `UberOfferParser` product lists know about. */
  product: string;
  pickupAddress: string;
  destinationAddress: string;
}

/** Product tiers each platform's parser recognises (see PlatformParsers.kt). */
export const PRODUCTS: Record<Platform, string[]> = {
  bolt: ['Comfort', 'XL', 'Green', 'Pet', 'Economy'],
  uber: ['UberX', 'Comfort', 'Green', 'Black', 'XL'],
};

/**
 * Addresses carry no tokens by design — no digit ever sits next to `km`, `m`,
 * `mi` or a currency word — so they add realism without adding noise the
 * parser has to survive. The Bolt pickup is lifted straight from the
 * `boltCard()` fixture in OfferParserTest.kt.
 */
export const DEFAULT_ADDRESSES: Record<Platform, { pickup: string; destination: string }> = {
  bolt: { pickup: 'Strada Victoriei 12', destination: 'Bulevardul Unirii 45' },
  uber: { pickup: 'Bulevardul Magheru 8', destination: 'Strada Lipscani 22' },
};

/**
 * The form behind the control panel. Everything is a string so a field can be
 * blank, which is how "Single distance" renders no pickup leg at all.
 */
export interface Draft {
  fare: string;
  pickupKm: string;
  pickupMin: string;
  tripKm: string;
  tripMin: string;
  passengerRating: string;
  surge: string;
  product: string;
}

export interface Preset {
  id: string;
  label: string;
  /** One-line reminder of what this preset is meant to prove. */
  note: string;
  draft: Draft;
}

const draft = (
  fare: string,
  pickupKm: string,
  pickupMin: string,
  tripKm: string,
  tripMin: string,
  extra: Partial<Draft> = {},
): Draft => ({
  fare,
  pickupKm,
  pickupMin,
  tripKm,
  tripMin,
  passengerRating: '4.85',
  surge: '',
  product: '',
  ...extra,
});

export const PRESETS: Preset[] = [
  {
    id: 'good',
    label: 'Good',
    note: 'Short deadhead, decent paid leg. Should read as a keeper.',
    draft: draft('40', '2.0', '5', '8.0', '15'),
  },
  {
    id: 'trap',
    label: 'Classic trap',
    note: 'Long deadhead, tiny paid leg. Should come out BAD / loss-making.',
    draft: draft('6', '5.0', '12', '2.0', '6'),
  },
  {
    id: 'deadhead',
    label: 'Long deadhead',
    note: 'Fare looks fine until you price the 9 km drive to get there.',
    draft: draft('30', '9.0', '18', '6.0', '12'),
  },
  {
    id: 'surge',
    label: 'Surge',
    note: 'Multiplier chip on the card — exercises the Multiplier token.',
    draft: draft('85', '3.0', '7', '14.0', '26', { surge: '1.8' }),
  },
  {
    id: 'long',
    label: 'Long trip',
    note: 'Big numbers; checks nothing overflows or gets clamped away.',
    draft: draft('120', '4.0', '9', '45.0', '55'),
  },
  {
    id: 'single',
    label: 'Single distance',
    note: 'No pickup leg rendered at all — the low-confidence path.',
    draft: draft('20', '', '', '6.0', '14'),
  },
];

export const DEFAULT_DRAFT: Draft = PRESETS[0].draft;

/** Accepts both `2.4` and `2,4`, and treats blank as "field not rendered". */
export function parseNumber(raw: string): number | null {
  const cleaned = raw.trim().replace(',', '.');
  if (cleaned.length === 0) return null;
  const value = Number(cleaned);
  return Number.isFinite(value) ? value : null;
}

export function draftToOffer(d: Draft, platform: Platform): Offer {
  const addresses = DEFAULT_ADDRESSES[platform];
  return {
    fare: parseNumber(d.fare) ?? 0,
    pickupKm: parseNumber(d.pickupKm),
    pickupMin: parseNumber(d.pickupMin),
    tripKm: parseNumber(d.tripKm),
    tripMin: parseNumber(d.tripMin),
    passengerRating: parseNumber(d.passengerRating),
    surge: parseNumber(d.surge),
    product: d.product.trim() || PRODUCTS[platform][0],
    pickupAddress: addresses.pickup,
    destinationAddress: addresses.destination,
  };
}

export function randomPreset(): Preset {
  return PRESETS[Math.floor(Math.random() * PRESETS.length)];
}

/** Offer -> URL param blob. The two screens share nothing but this. */
export function encodeOffer(offer: Offer): string {
  return JSON.stringify(offer);
}

export function decodeOffer(raw: string | string[] | undefined): Offer | null {
  const text = Array.isArray(raw) ? raw[0] : raw;
  if (!text) return null;
  try {
    return JSON.parse(text) as Offer;
  } catch {
    return null;
  }
}
