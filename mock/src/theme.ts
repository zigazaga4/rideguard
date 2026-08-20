/** Dark palettes: one for the control panel, one per driver app. */

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
  /** Flat colour standing in for the map behind the card. */
  map: string;
  mapLine: string;
  card: string;
  cardEdge: string;
  text: string;
  dim: string;
  chip: string;
  accept: string;
  acceptText: string;
  decline: string;
  declineText: string;
  declineBorder: string;
  accentText: string;
}

export const PLATFORM_THEME: Record<Platform, PlatformTheme> = {
  bolt: {
    label: 'Bolt',
    map: '#20262B',
    mapLine: '#2E363D',
    card: '#15171A',
    cardEdge: '#23272C',
    text: '#FFFFFF',
    dim: '#9AA3AD',
    chip: '#23272C',
    accept: '#34D186',
    acceptText: '#06110B',
    decline: 'transparent',
    declineText: '#C9D1DA',
    declineBorder: '#39404A',
    accentText: '#34D186',
  },
  uber: {
    label: 'Uber',
    map: '#1A1A1A',
    mapLine: '#262626',
    card: '#000000',
    cardEdge: '#1F1F1F',
    text: '#FFFFFF',
    dim: '#9E9E9E',
    chip: '#1C1C1C',
    accept: '#FFFFFF',
    acceptText: '#000000',
    decline: 'transparent',
    declineText: '#D6D6D6',
    declineBorder: '#3A3A3A',
    accentText: '#FFFFFF',
  },
};

/**
 * Card height as a fraction of the screen. The real cards sit in the bottom
 * 55-65%; RideGuard's overlay refuses to enter the bottom 34%
 * (`OverlayBounds.FORBIDDEN_BOTTOM_FRACTION`), and this is what verifies it.
 */
export const CARD_FRACTION = 0.62;
export const MAP_FRACTION = 1 - CARD_FRACTION;
