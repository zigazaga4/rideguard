import { router, useLocalSearchParams } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackHandler, StyleSheet, useWindowDimensions, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { OfferCard } from '../src/components/OfferCard';
import { decodeOffer, DEFAULT_DRAFT, draftToOffer, type Platform } from '../src/offer';
import { CARD_FRACTION, PLATFORM_THEME } from '../src/theme';

const DEFAULT_SECONDS = 15;

/**
 * The offer screen.
 *
 * Geometry is the point of this screen as much as the text is. The map is a
 * full-screen backdrop and the card floats on it, because that is how both
 * real apps do it — Uber's card visibly hovers above the bottom edge with map
 * showing underneath, and Bolt's decline pill sits on the map far from its
 * accept button. RideGuard clamps its HUD out of the bottom 34% of the display
 * so it can never sit over an accept button; this is the screen that proves it.
 */
export default function OfferScreen() {
  const params = useLocalSearchParams<{
    platform?: string;
    offer?: string;
    seconds?: string;
  }>();

  const platform: Platform = params.platform === 'uber' ? 'uber' : 'bolt';
  const theme = PLATFORM_THEME[platform];
  const insets = useSafeAreaInsets();
  const { height } = useWindowDimensions();

  const offer = useMemo(
    () => decodeOffer(params.offer) ?? draftToOffer(DEFAULT_DRAFT, platform),
    [params.offer, platform],
  );

  const total = useMemo(() => {
    const parsed = Number(params.seconds);
    return Number.isFinite(parsed) && parsed > 0 ? Math.round(parsed) : DEFAULT_SECONDS;
  }, [params.seconds]);

  const [secondsLeft, setSecondsLeft] = useState(total);
  const dismissed = useRef(false);

  const dismiss = useCallback(() => {
    if (dismissed.current) return;
    dismissed.current = true;
    if (router.canGoBack()) router.back();
    else router.replace('/');
  }, []);

  // One interval for the whole screen. Only the countdown's width changes each
  // tick and it carries no text at all, so the accessibility snapshot is
  // byte-identical second to second. That is exactly the stability the
  // overlay's fingerprint dedupe is supposed to rely on — a HUD that
  // re-rendered on every tick would strobe while the driver is deciding.
  useEffect(() => {
    const id = setInterval(() => {
      setSecondsLeft((s) => (s > 0 ? s - 1 : 0));
    }, 1000);
    return () => clearInterval(id);
  }, []);

  useEffect(() => {
    if (secondsLeft <= 0) dismiss();
  }, [secondsLeft, dismiss]);

  // Hardware back behaves like Decline rather than leaving a dead screen.
  useEffect(() => {
    const sub = BackHandler.addEventListener('hardwareBackPress', () => {
      dismiss();
      return true;
    });
    return () => sub.remove();
  }, [dismiss]);

  return (
    <View style={[styles.root, { backgroundColor: theme.map }]}>
      {/* Uber's map is light and Bolt's is dark, so the status bar has to flip
          with it or the clock disappears into the background. */}
      <StatusBar style={platform === 'uber' ? 'dark' : 'light'} />

      {/* Map placeholder — deliberately textless so it adds no noise to the
          accessibility snapshot the parser has to work through. */}
      <View style={StyleSheet.absoluteFill} pointerEvents="none">
        <View style={[styles.road, styles.roadA, { backgroundColor: theme.mapLine }]} />
        <View style={[styles.road, styles.roadB, { backgroundColor: theme.mapLine }]} />
        <View style={[styles.road, styles.roadC, { backgroundColor: theme.mapLine }]} />
        <View style={[styles.pin, { borderColor: theme.mapPin }]} />
      </View>

      <OfferCard
        platform={platform}
        offer={offer}
        secondsLeft={secondsLeft}
        totalSeconds={total}
        topInset={insets.top}
        bottomInset={insets.bottom}
        minBlockHeight={Math.round(height * CARD_FRACTION)}
        onAccept={dismiss}
        onDecline={dismiss}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, overflow: 'hidden' },
  road: { position: 'absolute', borderRadius: 3 },
  roadA: { left: -40, top: '12%', width: '140%', height: 14, transform: [{ rotate: '-8deg' }] },
  roadB: { left: '22%', top: -30, width: 12, height: '60%', transform: [{ rotate: '12deg' }] },
  roadC: { left: -20, top: '26%', width: '130%', height: 8, transform: [{ rotate: '4deg' }] },
  pin: {
    position: 'absolute',
    left: '46%',
    top: '17%',
    width: 18,
    height: 18,
    borderRadius: 9,
    borderWidth: 5,
  },
});
