/**
 * The depleting offer timer.
 *
 * Both driver apps put visible time pressure on screen, and they do it
 * differently — Bolt wraps the number in a ring that drains, Uber runs a bar
 * across the top of the card. A static number, which is what this mock had
 * before, loses the single most important quality of a real offer screen: the
 * feeling that it is running out.
 *
 * One component, two variants, because the behaviour is identical and only the
 * shape differs. Two separate components would drift.
 *
 * No `react-native-svg` dependency: the ring is built from rotated segments,
 * which needs nothing beyond core RN and reads as deliberate rather than as a
 * poor imitation of an arc.
 */

import { memo, useMemo } from 'react';
import { StyleSheet, Text, View } from 'react-native';

type Variant = 'ring' | 'bar';

interface Props {
  variant: Variant;
  secondsLeft: number;
  totalSeconds: number;
  color: string;
  trackColor: string;
  textColor: string;
  /** Turn the remaining time red once it is nearly gone. */
  urgentColor?: string;
}

const SEGMENTS = 28;
const RING_SIZE = 56;
const SEGMENT_WIDTH = 3;
const SEGMENT_LENGTH = 8;

function CountdownImpl({
  variant,
  secondsLeft,
  totalSeconds,
  color,
  trackColor,
  textColor,
  urgentColor = '#E5484D',
}: Props) {
  const progress = totalSeconds > 0 ? Math.max(0, Math.min(1, secondsLeft / totalSeconds)) : 0;
  const urgent = progress <= 0.25;
  const active = urgent ? urgentColor : color;

  if (variant === 'bar') {
    return (
      <View style={[styles.barTrack, { backgroundColor: trackColor }]}>
        <View
          style={[
            styles.barFill,
            { backgroundColor: active, width: `${progress * 100}%` },
          ]}
        />
      </View>
    );
  }

  return <Ring progress={progress} active={active} trackColor={trackColor} textColor={textColor} secondsLeft={secondsLeft} />;
}

function Ring({
  progress,
  active,
  trackColor,
  textColor,
  secondsLeft,
}: {
  progress: number;
  active: string;
  trackColor: string;
  textColor: string;
  secondsLeft: number;
}) {
  // Segment geometry never changes, so build it once rather than on every tick.
  const segments = useMemo(
    () =>
      Array.from({ length: SEGMENTS }, (_, i) => ({
        key: i,
        // Start at 12 o'clock and go clockwise, like a real countdown.
        rotate: `${(360 / SEGMENTS) * i}deg`,
      })),
    [],
  );

  const litCount = Math.ceil(progress * SEGMENTS);

  return (
    <View style={styles.ring}>
      {segments.map((s, i) => (
        <View
          key={s.key}
          style={[
            styles.segment,
            {
              backgroundColor: i < litCount ? active : trackColor,
              transform: [{ rotate: s.rotate }],
            },
          ]}
        />
      ))}
      <Text style={[styles.ringText, { color: textColor }]}>{secondsLeft}</Text>
    </View>
  );
}

export const Countdown = memo(CountdownImpl);

const styles = StyleSheet.create({
  // --- bar (Uber) ---
  barTrack: {
    height: 4,
    borderRadius: 2,
    overflow: 'hidden',
    width: '100%',
  },
  barFill: {
    height: '100%',
    borderRadius: 2,
  },

  // --- ring (Bolt) ---
  ring: {
    width: RING_SIZE,
    height: RING_SIZE,
    alignItems: 'center',
    justifyContent: 'center',
  },
  segment: {
    position: 'absolute',
    top: 0,
    width: SEGMENT_WIDTH,
    height: SEGMENT_LENGTH,
    borderRadius: SEGMENT_WIDTH / 2,
    // Rotating about the circle's centre rather than the segment's own centre
    // is what places each tick around the rim. `transformOrigin` is core RN
    // from 0.74 onward, so this needs no extra library.
    transformOrigin: `${SEGMENT_WIDTH / 2}px ${RING_SIZE / 2}px`,
  },
  ringText: {
    fontSize: 20,
    lineHeight: 24,
    fontWeight: '700',
  },
});
