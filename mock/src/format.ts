/**
 * Locale-correct number formatting, one place only.
 *
 * The whole point of this harness is that the strings on screen match what
 * RideGuard's `TokenScanner` regexes expect to find, byte for byte:
 *
 *   Bolt  (ro): `32,50 lei`   `2,4 km`   `18 min`   `4,85 ★`   `1,8×`
 *   Uber  (en): `€14.20`      `2.4 km`   `18 min`   `4.85`     `1.8×`
 *
 * If a number ever renders wrong, fix it HERE — never in a screen.
 */

import type { Platform } from './offer';

export interface LocaleStyle {
  /** Decimal separator. Romanian uses a comma, English a dot. */
  decimal: ',' | '.';
  currencySymbol: string;
  currencyPosition: 'prefix' | 'suffix';
  /** Bolt puts a star after the rating; Uber renders the glyph separately. */
  ratingSuffix: string;
}

export const BOLT_STYLE: LocaleStyle = {
  decimal: ',',
  currencySymbol: 'lei',
  currencyPosition: 'suffix',
  ratingSuffix: ' ★',
};

export const UBER_STYLE: LocaleStyle = {
  decimal: '.',
  currencySymbol: '€',
  currencyPosition: 'prefix',
  ratingSuffix: '',
};

export function styleFor(platform: Platform): LocaleStyle {
  return platform === 'bolt' ? BOLT_STYLE : UBER_STYLE;
}

/** `12.5 -> "12,5"` under a comma locale. Trailing zeros are kept. */
function decimals(value: number, digits: number, style: LocaleStyle): string {
  const fixed = value.toFixed(digits);
  return style.decimal === ',' ? fixed.replace('.', ',') : fixed;
}

/** `32.5 -> "32,50 lei"` / `14.2 -> "€14.20"`. Always two decimal places. */
export function formatMoney(value: number, style: LocaleStyle): string {
  const amount = decimals(value, 2, style);
  return style.currencyPosition === 'prefix'
    ? `${style.currencySymbol}${amount}`
    : `${amount} ${style.currencySymbol}`;
}

/**
 * `2.4 -> "2,4 km"`. Sub-kilometre legs render as metres (`"800 m"`), which is
 * what both apps do and what `TokenScanner.METRES` is written to survive.
 */
export function formatKm(km: number, style: LocaleStyle): string {
  if (km > 0 && km < 1) return `${Math.round(km * 1000)} m`;
  return `${decimals(km, 1, style)} km`;
}

/**
 * `18 -> "18 min"`. Identical in both locales — minutes are never fractional
 * on either card — but it takes the style so callers stay uniform.
 */
// eslint-disable-next-line @typescript-eslint/no-unused-vars
export function formatMin(min: number, style: LocaleStyle): string {
  return `${Math.round(min)} min`;
}

/** `4.85 -> "4,85 ★"` (Bolt) or `"4.85"` (Uber, kept short on purpose). */
export function formatRating(rating: number, style: LocaleStyle): string {
  return `${decimals(rating, 2, style)}${style.ratingSuffix}`;
}

/** `1.8 -> "1,8×"`. The `×` is U+00D7, which the Multiplier regex accepts. */
export function formatMultiplier(factor: number, style: LocaleStyle): string {
  const value = Number.isInteger(factor)
    ? String(factor)
    : decimals(factor, 1, style);
  return `${value}×`;
}

/**
 * One leg of the journey, composed the way the platform composes it.
 *
 *   Bolt: `2,4 km · 5 min`
 *   Uber: `5 min (2.4 km) away` / `18 min (8.1 km) trip`
 *
 * Returns null when neither half of the leg is known, so the caller renders
 * no `<Text>` at all rather than an empty one.
 */
export function formatLeg(
  platform: Platform,
  kind: 'pickup' | 'trip',
  km: number | null,
  min: number | null,
): string | null {
  const style = styleFor(platform);
  const distance = km === null ? null : formatKm(km, style);
  const duration = min === null ? null : formatMin(min, style);
  if (distance === null && duration === null) return null;

  if (platform === 'bolt') {
    return [distance, duration].filter(Boolean).join(' · ');
  }

  const tail = kind === 'pickup' ? 'away' : 'trip';
  if (duration === null) return `${distance} ${tail}`;
  if (distance === null) return `${duration} ${tail}`;
  return `${duration} (${distance}) ${tail}`;
}
