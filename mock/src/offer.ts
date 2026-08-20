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
  /** Headline fare. Romania is RON on both apps; only the word differs. */
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
  /** Product tier, e.g. "Bolt" / "UberX". Must be one of the names the
   *  Kotlin `BoltOfferParser` / `UberOfferParser` product lists know about. */
  product: string;
  /** Bolt prints the passenger's first name next to the rating; Uber does not. */
  passengerName: string | null;
  pickupAddress: string;
  destinationAddress: string;
}

/**
 * Product tiers each platform's parser recognises (see PlatformParsers.kt).
 *
 * `Bolt` is first because that is Bolt's base tier and what the real card
 * shows — the chip literally reads `🚗 Bolt`, the same way Uber's reads
 * `👤 UberX`.
 */
export const PRODUCTS: Record<Platform, string[]> = {
  bolt: ['Bolt', 'Comfort', 'XL', 'Green', 'Pet', 'Economy'],
  uber: ['UberX', 'Comfort', 'Green', 'Black', 'XL'],
};

/**
 * Addresses lifted verbatim off the real screenshots, postcodes included.
 *
 * They are kept EXACTLY as captured because they are the harness's main
 * guardrail: `Bulevardul Mamaia Nord 2, Năvodari 905750` carries a street
 * number and a six-digit postcode, and if either ever leaked into the fare or
 * a leg the driver would be shown a confident, plausible, wrong number.
 * `MockHarnessContractTest` asserts these blocks yield no tokens at all.
 */
export const DEFAULT_ADDRESSES: Record<Platform, { pickup: string; destination: string }> = {
  bolt: {
    pickup: 'Bulevardul Mamaia Nord 2, Năvodari 905750',
    destination: 'Azimuth Beach & Lounge, Strada Promenada, Mamaia-Sat 905700',
  },
  uber: {
    pickup: 'Str. Lirei 35, Constanța',
    destination: 'Strada Emil Costinescu 1, Costinești',
  },
};

/** Bolt shows a first name beside the rating. Uber's chip is the star alone. */
export const PASSENGER_NAMES: Record<Platform, string | null> = {
  bolt: 'Lichi',
  uber: null,
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
  // One decimal place, because Bolt renders ratings with one: 4.85 would come
  // out as "4.8" on the card and read as a formatting bug to anyone comparing
  // the preset with the screen.
  passengerRating: '4.9',
  surge: '',
  product: '',
  ...extra,
});

export const PRESETS: Preset[] = [
  {
    id: 'real-bolt',
    label: 'Real Bolt',
    note: 'The actual Bolt screenshot: 11,62 lei net, 2.8 km pickup for a 3 km ride.',
    draft: draft('11.62', '2.8', '6', '3', '6', { passengerRating: '5.0', surge: '1.1' }),
  },
  {
    id: 'real-uber',
    label: 'Real Uber',
    note: 'The actual Uber screenshot: 78,16 RON net, 5.4 km pickup, 29 km ride.',
    draft: draft('78.16', '5.4', '12', '29.0', '57', { passengerRating: '5.0' }),
  },
  {
    id: 'good',
    label: 'Good',
    note: 'Short deadhead, decent paid leg. Should read as a keeper.',
    draft: draft('40', '2.0', '5', '8.0', '15'),
  },
  {
    id: 'trap',
    label: 'Classic trap',
    note: 'Long deadhead, tiny paid leg. Misses every target — BAD.',
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
    note: 'Big numbers, and the only preset that trips Uber’s >45 min chip.',
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
    passengerName: PASSENGER_NAMES[platform],
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
