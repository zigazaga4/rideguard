/**
 * Colours, taken off screenshots of the live Romanian driver apps.
 *
 * The single biggest correction here: **Uber's offer card is LIGHT** — a white
 * card with a thin black border on a pale map. This harness used to fake it as
 * white-on-black, which meant the overlay was never once tested against a
 * bright background, and the HUD's own contrast was being judged against a
 * screen the driver never actually sees.
 */

import type { Platform } from './offer';

export const ui = {
  bg: '#0B0C0E',
  panel: '#141619',
  field: '#1B1E22',
  border: '#2A2F36',
  text: '#F2F4F7',
  dim: '#98A2B3',
  faint: '#5B6470',
  accent: '#4C8DFF',
} as const;

export interface PlatformTheme {
  label: string;
  /** Flat colour standing in for the map the card floats on. */
  map: string;
  mapLine: string;
  mapPin: string;

  card: string;
  /** Bolt's amber outline is the loudest thing on its card. Uber's is black. */
  cardBorder: string;
  cardBorderWidth: number;
  cardRadius: number;
  /** How far the card is inset from the screen edges. */
  cardInset: number;

  text: string;
  dim: string;
  divider: string;

  /** Neutral chip: Bolt's tier chip, and every chip on Uber. */
  chip: string;
  chipText: string;
  /** Cash and surge. Green on Bolt; Uber gives them no special colour. */
  chipGood: string;
  chipGoodText: string;
  /** Bolt's amber-tinted state chips. Uber has no equivalent. */
  chipWarn: string;
  chipWarnText: string;

  /** Uber's tier pill is inverted (black on white); Bolt's is dark grey. */
  productChip: string;
  productChipText: string;

  accept: string;
  acceptText: string;
  /** What the countdown drains over. Bolt: the divider. Uber: the button. */
  countdown: string;
  countdownTrack: string;

  decline: string;
  declineText: string;

  /** Ring dots beside the two legs. Bolt colours them; Uber outlines in black. */
  legStart: string;
  legEnd: string;
  /** Uber marks the destination with a square, Bolt with a second ring. */
  tripDotIsSquare: boolean;
}

export const PLATFORM_THEME: Record<Platform, PlatformTheme> = {
  bolt: {
    label: 'Bolt',
    map: '#212B36',
    mapLine: '#2C3845',
    mapPin: '#25B673',

    card: '#1C2430',
    cardBorder: '#F5A623',
    cardBorderWidth: 2,
    cardRadius: 16,
    cardInset: 10,

    text: '#FFFFFF',
    dim: '#98A2B3',
    divider: '#2C3644',

    chip: '#2A3340',
    chipText: '#FFFFFF',
    chipGood: '#1FA971',
    chipGoodText: '#FFFFFF',
    chipWarn: '#33301F',
    chipWarnText: '#F5A623',

    productChip: '#2A3340',
    productChipText: '#FFFFFF',

    accept: '#25B673',
    acceptText: '#FFFFFF',
    countdown: '#25B673',
    countdownTrack: '#2C3644',

    decline: '#FFFFFF',
    declineText: '#12181F',

    legStart: '#25B673',
    legEnd: '#FF5A5F',
    tripDotIsSquare: false,
  },
  uber: {
    label: 'Uber',
    map: '#E9E6E0',
    mapLine: '#FDFCFA',
    mapPin: '#000000',

    card: '#FFFFFF',
    cardBorder: '#000000',
    cardBorderWidth: 2,
    cardRadius: 20,
    cardInset: 12,

    text: '#000000',
    dim: '#6E6E6E',
    divider: '#E6E6E6',

    chip: '#F2F2F2',
    chipText: '#000000',
    chipGood: '#F2F2F2',
    chipGoodText: '#000000',
    chipWarn: '#F2F2F2',
    chipWarnText: '#000000',

    productChip: '#000000',
    productChipText: '#FFFFFF',

    // The button IS the countdown track: black drains across dark grey.
    accept: '#3A3A3A',
    acceptText: '#FFFFFF',
    countdown: '#000000',
    countdownTrack: '#3A3A3A',

    decline: '#F2F2F2',
    declineText: '#000000',

    legStart: '#000000',
    legEnd: '#000000',
    tripDotIsSquare: true,
  },
};

/**
 * Minimum share of the screen the card block claims, so the geometry holds on
 * any handset regardless of how much content a preset produces.
 *
 * RideGuard's overlay refuses to enter the bottom 34% of the display
 * (`OverlayBounds.FORBIDDEN_BOTTOM_FRACTION`) precisely so it can never cover
 * the accept button, and this screen is what verifies it.
 */
export const CARD_FRACTION = 0.62;
