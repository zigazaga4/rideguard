import { memo } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { Offer, Platform } from '../offer';
import { buildOfferText } from '../offerText';
import { PLATFORM_THEME } from '../theme';
import { Countdown } from './Countdown';
import { PlatformMarker } from './PlatformMarker';

interface Props {
  platform: Platform;
  offer: Offer;
  /** Ticks once a second. Its own `<Text>` node, and nothing else re-renders. */
  secondsLeft: number;
  /** Starting value, so the timer knows how full to draw itself. */
  totalSeconds: number;
  bottomInset: number;
  onAccept: () => void;
  onDecline: () => void;
}

/**
 * One card for both platforms.
 *
 * Bolt and Uber differ in copy, number formatting and colour — never in
 * structure — so this branches on `platform` for those three things and keeps
 * a single layout. Splitting it into two components would let the two drift.
 *
 * ## Why everything here is a `<Text>`
 *
 * React Native maps `<Text>` onto a native Android `TextView`, and a TextView
 * is what shows up in the accessibility tree that RideGuard reads. Draw a fare
 * into an SVG, a Canvas or an Image and the reader goes blind — the harness
 * would then "work" while testing nothing. Every field below is therefore a
 * discrete `<Text>`, one per logical value, so its on-screen bounds mean
 * something to the parser's largest-text-is-the-fare heuristic.
 */
function OfferCardImpl({
  platform,
  offer,
  secondsLeft,
  totalSeconds,
  bottomInset,
  onAccept,
  onDecline,
}: Props) {
  const t = PLATFORM_THEME[platform];
  const text = buildOfferText(platform, offer);

  return (
    <View style={[styles.card, { backgroundColor: t.card, borderTopColor: t.cardEdge }]}>
      <View style={[styles.grabber, { backgroundColor: t.cardEdge }]} />

      {/* Uber's timer spans the full card width just under the handle. */}
      {platform === 'uber' && (
        <View style={styles.uberTimerSlot}>
          <Countdown
            variant="bar"
            secondsLeft={secondsLeft}
            totalSeconds={totalSeconds}
            color={t.text}
            trackColor={t.cardEdge}
            textColor={t.text}
          />
        </View>
      )}

      {/* Must stay rendered and non-zero-sized. See PlatformMarker. */}
      <PlatformMarker platform={platform} />

      <View style={styles.topRow}>
        <View style={styles.topLeft}>
          <Text style={[styles.header, { color: t.dim }]} numberOfLines={1}>
            {text.header}
          </Text>
          <View style={styles.chipRow}>
            <View style={[styles.chip, { backgroundColor: t.chip }]}>
              <Text style={[styles.chipText, { color: t.text }]}>{text.product}</Text>
            </View>
            {text.surge !== null && (
              <View style={[styles.chip, { backgroundColor: t.chip }]}>
                <Text style={[styles.chipText, { color: t.accentText }]}>{text.surge}</Text>
                <Text style={[styles.chipLabel, { color: t.dim }]}>{text.surgeLabel}</Text>
              </View>
            )}
          </View>
        </View>

        {/* Countdown. Deliberately its own node with nothing else in it: the
            HUD must not flicker just because this number changes every second.

            Bolt rings the number; Uber runs a bar across the top of the card
            (rendered above, outside this row). */}
        {platform === 'bolt' && (
          <Countdown
            variant="ring"
            secondsLeft={secondsLeft}
            totalSeconds={totalSeconds}
            color={t.accentText}
            trackColor={t.cardEdge}
            textColor={t.text}
          />
        )}
      </View>

      <View style={styles.fareBlock}>
        {/* Largest type on the card, on purpose: HeuristicOfferParser.pickFare
            uses node height as a proxy for font size to find the headline fare. */}
        <Text style={[styles.fare, { color: t.text }]} numberOfLines={1}>
          {text.fare}
        </Text>
        <Text style={[styles.fareCaption, { color: t.dim }]}>{text.fareCaption}</Text>
      </View>

      {text.rating !== null && (
        <View style={styles.ratingRow}>
          {text.ratingGlyph !== null && (
            <Text style={[styles.ratingGlyph, { color: t.dim }]}>{text.ratingGlyph}</Text>
          )}
          <Text style={[styles.rating, { color: t.dim }]}>{text.rating}</Text>
        </View>
      )}

      <View style={styles.legs}>
        {text.pickupLeg !== null && (
          <View style={styles.legRow}>
            <View style={[styles.legDot, { borderColor: t.accentText }]} />
            <View style={styles.legBody}>
              <Text style={[styles.legLabel, { color: t.dim }]}>{text.pickupLabel}</Text>
              <Text style={[styles.legValue, { color: t.text }]}>{text.pickupLeg}</Text>
              <Text style={[styles.legAddress, { color: t.dim }]} numberOfLines={1}>
                {text.pickupAddress}
              </Text>
            </View>
          </View>
        )}

        {text.tripLeg !== null && (
          <View style={styles.legRow}>
            <View style={[styles.legSquare, { borderColor: t.dim }]} />
            <View style={styles.legBody}>
              <Text style={[styles.legLabel, { color: t.dim }]}>{text.dropoffLabel}</Text>
              <Text style={[styles.legValue, { color: t.text }]}>{text.tripLeg}</Text>
              <Text style={[styles.legAddress, { color: t.dim }]} numberOfLines={1}>
                {text.destinationAddress}
              </Text>
            </View>
          </View>
        )}
      </View>

      {/* Actions pinned to the very bottom, exactly where the real ones sit —
          this is the region the overlay is forbidden from covering. */}
      <View style={[styles.actions, { paddingBottom: bottomInset + 12 }]}>
        <Pressable
          onPress={onDecline}
          style={({ pressed }) => [
            styles.decline,
            { borderColor: t.declineBorder, opacity: pressed ? 0.6 : 1 },
          ]}
        >
          <Text style={[styles.declineText, { color: t.declineText }]}>{text.decline}</Text>
        </Pressable>

        <Pressable
          onPress={onAccept}
          style={({ pressed }) => [
            styles.accept,
            { backgroundColor: t.accept, opacity: pressed ? 0.8 : 1 },
          ]}
        >
          <Text style={[styles.acceptText, { color: t.acceptText }]}>{text.accept}</Text>
        </Pressable>
      </View>
    </View>
  );
}

export const OfferCard = memo(OfferCardImpl);

const styles = StyleSheet.create({
  card: {
    flex: 1,
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    borderTopWidth: StyleSheet.hairlineWidth,
    paddingHorizontal: 20,
    paddingTop: 8,
  },
  uberTimerSlot: { marginBottom: 12, paddingHorizontal: 2 },
  grabber: {
    alignSelf: 'center',
    width: 40,
    height: 4,
    borderRadius: 2,
    marginBottom: 10,
  },
  topRow: {
    flexDirection: 'row',
    alignItems: 'flex-start',
    justifyContent: 'space-between',
  },
  topLeft: { flex: 1, paddingRight: 12 },
  header: {
    fontSize: 14,
    fontWeight: '600',
    letterSpacing: 0.4,
    textTransform: 'uppercase',
  },
  chipRow: { flexDirection: 'row', marginTop: 8, gap: 8 },
  chip: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 8,
  },
  chipText: { fontSize: 14, fontWeight: '700' },
  chipLabel: { fontSize: 11, fontWeight: '500' },
  timer: {
    width: 54,
    height: 54,
    borderRadius: 27,
    borderWidth: 2,
    alignItems: 'center',
    justifyContent: 'center',
  },
  timerText: { fontSize: 22, lineHeight: 26, fontWeight: '700' },
  fareBlock: { marginTop: 14 },
  fare: { fontSize: 46, lineHeight: 56, fontWeight: '800' },
  fareCaption: { fontSize: 13, marginTop: 2 },
  ratingRow: { flexDirection: 'row', alignItems: 'center', gap: 6, marginTop: 10 },
  ratingGlyph: { fontSize: 14 },
  rating: { fontSize: 14, fontWeight: '600' },
  legs: { marginTop: 18, gap: 14 },
  legRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  legDot: { width: 12, height: 12, borderRadius: 6, borderWidth: 3, marginTop: 5 },
  legSquare: { width: 12, height: 12, borderRadius: 2, borderWidth: 3, marginTop: 5 },
  legBody: { flex: 1 },
  legLabel: { fontSize: 11, fontWeight: '600', letterSpacing: 0.5, textTransform: 'uppercase' },
  legValue: { fontSize: 17, lineHeight: 22, fontWeight: '700', marginTop: 2 },
  legAddress: { fontSize: 13, marginTop: 2 },
  actions: { marginTop: 'auto', paddingTop: 12, gap: 10 },
  decline: {
    height: 46,
    borderRadius: 10,
    borderWidth: 1,
    alignItems: 'center',
    justifyContent: 'center',
  },
  declineText: { fontSize: 15, fontWeight: '600' },
  accept: {
    height: 60,
    borderRadius: 12,
    alignItems: 'center',
    justifyContent: 'center',
  },
  acceptText: { fontSize: 19, fontWeight: '800' },
});
