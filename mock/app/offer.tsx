import { router, useLocalSearchParams } from 'expo-router';
import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { BackHandler, StyleSheet, useWindowDimensions, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { OfferCard } from '../src/components/OfferCard';
import { decodeOffer, DEFAULT_DRAFT, draftToOffer, type Platform } from '../src/offer';
import { MAP_FRACTION, PLATFORM_THEME } from '../src/theme';

const DEFAULT_SECONDS = 15;

/**
 * The offer screen.
 *
 * Geometry is the point of this screen as much as the text is: a flat map
 * placeholder across the top ~38%, the card across the bottom ~62%, and the
 * Accept button pinned to the very bottom edge. RideGuard clamps its HUD out
 * of the bottom 34% of the display so it can never sit over that button —
 * this is the screen that proves it.
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

  // One interval for the whole screen. Only the countdown <Text> changes each
  // tick; every other node keeps identical props, so React Native issues no
  // native update for them and their bounds never move. That is exactly the
  // stability the overlay's dedupe logic is supposed to rely on.
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

  const mapHeight = Math.round(height * MAP_FRACTION);

  return (
    <View style={[styles.root, { backgroundColor: theme.map }]}>
      {/* Map placeholder — deliberately textless so it adds no noise to the
          accessibility snapshot the parser has to work through. */}
      <View style={[styles.map, { height: mapHeight }]} pointerEvents="none">
        <View style={[styles.road, styles.roadA, { backgroundColor: theme.mapLine }]} />
        <View style={[styles.road, styles.roadB, { backgroundColor: theme.mapLine }]} />
        <View style={[styles.road, styles.roadC, { backgroundColor: theme.mapLine }]} />
        <View style={[styles.pin, { borderColor: theme.accentText }]} />
      </View>

      <View style={styles.cardSlot}>
        <OfferCard
          platform={platform}
          offer={offer}
          secondsLeft={secondsLeft}
          totalSeconds={total}
          bottomInset={insets.bottom}
          onAccept={dismiss}
          onDecline={dismiss}
        />
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1 },
  map: { width: '100%', overflow: 'hidden' },
  cardSlot: { flex: 1 },
  road: { position: 'absolute', borderRadius: 3 },
  roadA: { left: -40, top: '30%', width: '140%', height: 14, transform: [{ rotate: '-8deg' }] },
  roadB: { left: '22%', top: -30, width: 12, height: '160%', transform: [{ rotate: '12deg' }] },
  roadC: { left: -20, top: '68%', width: '130%', height: 8, transform: [{ rotate: '4deg' }] },
  pin: {
    position: 'absolute',
    left: '46%',
    top: '44%',
    width: 18,
    height: 18,
    borderRadius: 9,
    borderWidth: 5,
  },
});
