import { memo } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';

import type { Offer, Platform } from '../offer';
import { buildOfferText } from '../offerText';
import { PLATFORM_THEME, type PlatformTheme } from '../theme';
import { Countdown } from './Countdown';
import { PlatformMarker } from './PlatformMarker';

interface Props {
  platform: Platform;
  offer: Offer;
  /** Ticks once a second. Only the countdown's geometry reacts to it. */
  secondsLeft: number;
  /** Starting value, so the timer knows how full to draw itself. */
  totalSeconds: number;
  topInset: number;
  bottomInset: number;
  /** Floor for the card block, so the bottom-of-screen geometry always holds. */
  minBlockHeight: number;
  onAccept: () => void;
  onDecline: () => void;
}

/**
 * One card for both platforms.
 *
 * Bolt and Uber differ in copy, colour, chrome and where the two buttons live
 * — but they carry the same handful of facts in the same top-to-bottom order,
 * so this branches on `platform` and keeps one component. Splitting it in two
 * would let the two drift, and the whole point of the harness is that it does
 * not drift from what the parser expects.
 *
 * The two shapes, from the real screenshots:
 *
 *   Bolt   dark navy card with a 2px amber outline; decline is a white pill
 *          floating on the MAP, top-right; accept is a green bar OUTSIDE and
 *          below the card; the countdown is a short green bar on a divider.
 *   Uber   white card, thin black border, floating above the bottom edge;
 *          decline is a small ✕ inside the card; accept is inside the card and
 *          IS the countdown — black draining over dark grey.
 *
 * ## Why everything here is a `<Text>`
 *
 * React Native maps `<Text>` onto a native Android `TextView`, and a TextView
 * is what shows up in the accessibility tree that RideGuard reads. Draw a fare
 * into an SVG, a Canvas or an Image and the reader goes blind — the harness
 * would then "work" while testing nothing. Every field below is therefore a
 * discrete `<Text>`, one per logical value.
 *
 * The one deliberate exception is Bolt's fare: `11,62 lei` and its lighter
 * ` (NET, taxe incluse)` are one visual line, so they are a nested `<Text>`,
 * which React Native flattens into a SINGLE TextView. The parser has to pull
 * 11.62 out of the whole string, exactly as it must on the real card.
 *
 * Node order here must stay in step with `previewLines()` in offerText.ts —
 * that function is what `MockHarnessContractTest` is generated from.
 */
function OfferCardImpl({
  platform,
  offer,
  secondsLeft,
  totalSeconds,
  topInset,
  bottomInset,
  minBlockHeight,
  onAccept,
  onDecline,
}: Props) {
  const t = PLATFORM_THEME[platform];
  const text = buildOfferText(platform, offer);
  const bolt = platform === 'bolt';

  const legs = (
    <View style={styles.legs}>
      {text.pickupLeg !== null && text.tripLeg !== null && (
        <View style={[styles.connector, { backgroundColor: t.divider }]} />
      )}

      {text.pickupLeg !== null && (
        <View style={styles.legRow}>
          <View style={[styles.legDot, { borderColor: t.legStart }]} />
          <View style={styles.legBody}>
            <Text style={[styles.legValue, { color: t.text, fontSize: bolt ? 22 : 17 }]}>
              {text.pickupLeg}
            </Text>
            <Text style={[styles.legAddress, { color: t.dim }]} numberOfLines={2}>
              {text.pickupAddress}
            </Text>
          </View>
        </View>
      )}

      {text.tripLeg !== null && (
        <View style={styles.legRow}>
          <View
            style={[
              styles.legDot,
              t.tripDotIsSquare && styles.legDotSquare,
              { borderColor: t.legEnd },
            ]}
          />
          <View style={styles.legBody}>
            <Text style={[styles.legValue, { color: t.text, fontSize: bolt ? 22 : 17 }]}>
              {text.tripLeg}
            </Text>
            <Text style={[styles.legAddress, { color: t.dim }]} numberOfLines={2}>
              {text.destinationAddress}
            </Text>
          </View>
        </View>
      )}
    </View>
  );

  const accept = (
    <Pressable
      onPress={onAccept}
      style={({ pressed }) => [
        styles.accept,
        {
          backgroundColor: t.accept,
          borderRadius: bolt ? 12 : 10,
          height: bolt ? 60 : 52,
          opacity: pressed ? 0.85 : 1,
        },
      ]}
    >
      {/* Uber has no separate timer anywhere on the card — the button is it. */}
      {!bolt && (
        <Countdown
          variant="button"
          secondsLeft={secondsLeft}
          totalSeconds={totalSeconds}
          color={t.countdown}
          trackColor={t.countdownTrack}
        />
      )}
      <Text style={[styles.acceptText, { color: t.acceptText }]}>{text.accept}</Text>
    </Pressable>
  );

  const card = (
    <View
      style={[
        styles.card,
        {
          backgroundColor: t.card,
          borderColor: t.cardBorder,
          borderWidth: t.cardBorderWidth,
          borderRadius: t.cardRadius,
          marginHorizontal: t.cardInset,
        },
      ]}
    >
      {/* Must stay rendered and non-zero-sized. See PlatformMarker. */}
      <PlatformMarker platform={platform} />

      {bolt ? (
        <>
          <View style={styles.chipWrap}>
            <Chip theme={t} tone="product" label={text.product} />
            <Chip theme={t} tone="good" label={text.payment} />
            {text.surge !== null && <Chip theme={t} tone="good" label={text.surge} />}
            {text.stateChips.map((chip) => (
              <Chip key={chip} theme={t} tone="warn" label={chip} />
            ))}
          </View>

          <Text style={[styles.boltFare, { color: t.text }]}>
            {text.fare}
            {text.fareSuffix !== null && (
              <Text style={[styles.boltFareSuffix, { color: t.dim }]}>{text.fareSuffix}</Text>
            )}
          </Text>

          {text.disclaimer !== null && (
            <Text style={[styles.disclaimer, { color: t.dim }]}>{text.disclaimer}</Text>
          )}

          <View style={styles.dividerSlot}>
            <Countdown
              variant="divider"
              secondsLeft={secondsLeft}
              totalSeconds={totalSeconds}
              color={t.countdown}
              trackColor={t.divider}
            />
          </View>

          {text.passenger !== null && (
            <View style={[styles.passengerChip, { backgroundColor: t.chip }]}>
              <Text style={[styles.passengerText, { color: t.text }]}>{text.passenger}</Text>
            </View>
          )}

          {legs}
        </>
      ) : (
        <>
          <View style={styles.uberTopRow}>
            <View style={[styles.productPill, { backgroundColor: t.productChip }]}>
              <Text style={[styles.productPillText, { color: t.productChipText }]}>
                {text.product}
              </Text>
            </View>
            <Pressable
              onPress={onDecline}
              style={({ pressed }) => [
                styles.closeButton,
                { backgroundColor: t.decline, opacity: pressed ? 0.6 : 1 },
              ]}
            >
              <Text style={[styles.closeText, { color: t.declineText }]}>{text.decline}</Text>
            </Pressable>
          </View>

          <Text style={[styles.uberFare, { color: t.text }]} numberOfLines={1}>
            {text.fare}
          </Text>

          <View style={styles.chipWrap}>
            <Chip theme={t} tone="neutral" label={text.payment} />
            {text.passenger !== null && <Chip theme={t} tone="neutral" label={text.passenger} />}
            {text.surge !== null && <Chip theme={t} tone="neutral" label={text.surge} />}
          </View>

          {text.netChip !== null && (
            <View style={styles.chipWrap}>
              <Chip theme={t} tone="neutral" label={text.netChip} />
            </View>
          )}

          <View style={[styles.hairline, { backgroundColor: t.divider }]} />
          {legs}
          <View style={[styles.hairline, { backgroundColor: t.divider }]} />

          {text.longTrip !== null && (
            <>
              <View style={styles.chipWrap}>
                <Chip theme={t} tone="neutral" label={text.longTrip} />
              </View>
              <View style={[styles.hairline, { backgroundColor: t.divider }]} />
            </>
          )}

          {accept}
        </>
      )}
    </View>
  );

  return (
    <View
      style={[styles.stack, { paddingTop: topInset + 10, paddingBottom: bottomInset + 12 }]}
      pointerEvents="box-none"
    >
      {/* Everything above the card is map. Bolt's decline lives up here, which
          is the whole reason the overlay's forbidden zone is at the BOTTOM: on
          Bolt the two controls sit at opposite ends of the screen. */}
      <View style={styles.mapSlot} pointerEvents="box-none">
        {bolt && (
          <Pressable
            onPress={onDecline}
            style={({ pressed }) => [
              styles.declinePill,
              { backgroundColor: t.decline, opacity: pressed ? 0.7 : 1 },
            ]}
          >
            <Text style={[styles.declinePillText, { color: t.declineText }]}>{text.decline}</Text>
          </Pressable>
        )}
      </View>

      <View style={[styles.block, { minHeight: minBlockHeight }]}>
        {card}
        {bolt && (
          <View style={{ marginHorizontal: t.cardInset, marginTop: 10 }}>{accept}</View>
        )}
      </View>
    </View>
  );
}

/** A pill with one `<Text>` in it. Every chip on both cards is one of these. */
function Chip({
  theme,
  tone,
  label,
}: {
  theme: PlatformTheme;
  tone: 'neutral' | 'good' | 'warn' | 'product';
  label: string;
}) {
  const background =
    tone === 'good'
      ? theme.chipGood
      : tone === 'warn'
        ? theme.chipWarn
        : tone === 'product'
          ? theme.productChip
          : theme.chip;
  const color =
    tone === 'good'
      ? theme.chipGoodText
      : tone === 'warn'
        ? theme.chipWarnText
        : tone === 'product'
          ? theme.productChipText
          : theme.chipText;

  return (
    <View style={[styles.chip, { backgroundColor: background }]}>
      <Text style={[styles.chipText, { color }]}>{label}</Text>
    </View>
  );
}

export const OfferCard = memo(OfferCardImpl);

const styles = StyleSheet.create({
  stack: { flex: 1 },
  mapSlot: { flex: 1, alignItems: 'flex-end' },
  block: { justifyContent: 'flex-end' },

  declinePill: {
    flexDirection: 'row',
    alignItems: 'center',
    height: 40,
    paddingHorizontal: 18,
    borderRadius: 20,
    marginRight: 14,
  },
  declinePillText: { fontSize: 15, fontWeight: '700' },

  card: { paddingHorizontal: 16, paddingTop: 12, paddingBottom: 16 },

  chipWrap: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginBottom: 4 },
  chip: { paddingHorizontal: 12, paddingVertical: 7, borderRadius: 999 },
  chipText: { fontSize: 14, fontWeight: '700' },

  // --- Bolt ---
  boltFare: { fontSize: 34, lineHeight: 42, fontWeight: '800', marginTop: 12 },
  boltFareSuffix: { fontSize: 22, lineHeight: 42, fontWeight: '500' },
  disclaimer: { fontSize: 15, lineHeight: 20, marginTop: 6 },
  dividerSlot: { marginTop: 16, marginBottom: 14, justifyContent: 'center' },
  passengerChip: {
    alignSelf: 'flex-start',
    paddingHorizontal: 14,
    paddingVertical: 8,
    borderRadius: 999,
  },
  passengerText: { fontSize: 15, fontWeight: '600' },

  // --- Uber ---
  uberTopRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 12,
  },
  productPill: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: 999 },
  productPillText: { fontSize: 15, fontWeight: '700' },
  closeButton: { width: 34, height: 34, borderRadius: 10, alignItems: 'center', justifyContent: 'center' },
  closeText: { fontSize: 16, fontWeight: '700' },
  uberFare: { fontSize: 46, lineHeight: 56, fontWeight: '800', marginBottom: 12 },
  hairline: { height: StyleSheet.hairlineWidth, marginVertical: 14 },

  // --- shared legs ---
  legs: { gap: 16 },
  connector: {
    // Joins the two dots. Absolute so neither leg's height affects the other.
    position: 'absolute',
    left: 6,
    top: 18,
    bottom: 18,
    width: 2,
  },
  legRow: { flexDirection: 'row', alignItems: 'flex-start', gap: 12 },
  legDot: { width: 14, height: 14, borderRadius: 7, borderWidth: 3, marginTop: 5 },
  legDotSquare: { borderRadius: 2 },
  legBody: { flex: 1 },
  legValue: { lineHeight: 26, fontWeight: '700' },
  legAddress: { fontSize: 14, lineHeight: 19, marginTop: 2 },

  accept: {
    alignItems: 'center',
    justifyContent: 'center',
    overflow: 'hidden',
  },
  acceptText: { fontSize: 18, fontWeight: '800' },
});
