/**
 * Locale-correct number formatting, one place only.
 *
 * Every rule below was transcribed off a screenshot of the live Romanian
 * driver apps. The two apps are inconsistent in ways that look like typos and
 * are not — they come from different rendering paths inside each app:
 *
 *   Bolt: `11,62 lei`   `2.8 km`   `3 km`     `6 min`    `5.0 ★`   `1.1x`
 *   Uber: `78,16 RON`   `5.4 km`   `29.0 km`  `12 min.`  `★ 5,00`
 *
 * Money takes a COMMA on both. Distance takes a DOT on both. Bolt drops a
 * trailing `.0` and Uber keeps it. Uber abbreviates with a full stop after
 * `min` and Bolt does not. Bolt's rating is one dot-decimal with the star
 * after it; Uber's is two comma-decimals with the star before it.
 *
 * Do not "harmonise" any of that. The Kotlin `TokenScanner` is tested against
 * exactly these strings, and a tidy-up here is a blind HUD on a real phone.
 *
 * If a number ever renders wrong, fix it HERE — never in a screen.
 */

import type { Platform } from './offer';

export interface PlatformFormat {
  /** Printed after the amount. Romania is RON either way; only the word differs. */
  currency: string;
  /** Bolt writes `3 km`, Uber writes `29.0 km` for the same distance. */
  keepDistanceTrailingZero: boolean;
  /** Uber's full stop is part of the string, not punctuation we may drop. */
  minuteUnit: string;
  ratingDecimals: number;
  ratingDecimalSeparator: '.' | ',';
  /** Uber leads with the glyph (`★ 5,00`), Bolt trails it (`5.0 ★`). */
  ratingStarFirst: boolean;
}

export const BOLT_FORMAT: PlatformFormat = {
  currency: 'lei',
  keepDistanceTrailingZero: false,
  minuteUnit: 'min',
  ratingDecimals: 1,
  ratingDecimalSeparator: '.',
  ratingStarFirst: false,
};

export const UBER_FORMAT: PlatformFormat = {
  currency: 'RON',
  keepDistanceTrailingZero: true,
  minuteUnit: 'min.',
  ratingDecimals: 2,
  ratingDecimalSeparator: ',',
  ratingStarFirst: true,
};

export function styleFor(platform: Platform): PlatformFormat {
  return platform === 'bolt' ? BOLT_FORMAT : UBER_FORMAT;
}

function fixed(value: number, digits: number, separator: '.' | ','): string {
  const text = value.toFixed(digits);
  return separator === ',' ? text.replace('.', ',') : text;
}

/** `11.62 -> "11,62 lei"` / `78.16 -> "78,16 RON"`. Always two decimals. */
export function formatMoney(value: number, style: PlatformFormat): string {
  return `${fixed(value, 2, ',')} ${style.currency}`;
}

/**
 * `2.8 -> "2.8 km"`, and `3 -> "3 km"` on Bolt but `"3.0 km"` on Uber.
 *
 * Sub-kilometre legs render as metres (`"800 m"`), which is what both apps do
 * and what `TokenScanner.METRES` is written to survive next to `min`.
 */
export function formatKm(km: number, style: PlatformFormat): string {
  if (km > 0 && km < 1) return `${Math.round(km * 1000)} m`;
  const text = fixed(km, 1, '.');
  const trimmed = style.keepDistanceTrailingZero ? text : text.replace(/\.0$/, '');
  return `${trimmed} km`;
}

/** `6 -> "6 min"` (Bolt) or `12 -> "12 min."` (Uber). Never fractional. */
export function formatMin(min: number, style: PlatformFormat): string {
  return `${Math.round(min)} ${style.minuteUnit}`;
}

/** `5 -> "5.0 ★"` (Bolt) or `"★ 5,00"` (Uber). */
export function formatRating(rating: number, style: PlatformFormat): string {
  const value = fixed(rating, style.ratingDecimals, style.ratingDecimalSeparator);
  return style.ratingStarFirst ? `★ ${value}` : `${value} ★`;
}

/**
 * `1.1 -> "1.1x"`.
 *
 * A plain ASCII `x`, not `×` (U+00D7) — the real Bolt surge chip reads
 * `Cerere mare 1.1x`. The Kotlin Multiplier rule accepts both, and this is the
 * only place that decides which one the harness actually emits.
 */
export function formatMultiplier(factor: number): string {
  const value = Number.isInteger(factor) ? String(factor) : fixed(factor, 1, '.');
  return `${value}x`;
}

/**
 * One leg of the journey, composed the way each app composes it.
 *
 *   Bolt: `6 min • 2.8 km`                  — minutes FIRST, bullet separator
 *   Uber: `La 12 min. (5.4 km) distanță`    — pickup
 *         `Cursă: 57 min. (29.0 km)`        — paid leg, behind a label + colon
 *
 * Bolt putting minutes before kilometres is the reverse of what this harness
 * used to fake, and it is why the Kotlin side assigns distances and durations
 * independently instead of pairing them up inside a block.
 *
 * Returns null when neither half is known, so the caller renders no `<Text>`
 * at all rather than an empty one — that is how the "single distance"
 * low-confidence case is reproduced.
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
    return [duration, distance].filter(Boolean).join(' • ');
  }

  if (kind === 'pickup') {
    if (duration === null) return `La ${distance} distanță`;
    if (distance === null) return `La ${duration} distanță`;
    return `La ${duration} (${distance}) distanță`;
  }

  if (duration === null) return `Cursă: ${distance}`;
  if (distance === null) return `Cursă: ${duration}`;
  return `Cursă: ${duration} (${distance})`;
}
