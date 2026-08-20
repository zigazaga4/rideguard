/**
 * The depleting offer timer.
 *
 * Both driver apps put visible time pressure on screen and neither prints a
 * number for it — a static "12" was the worst thing about the old harness,
 * because the whole feel of a real offer screen is that it is running out.
 *
 * One component, two variants, because the behaviour is identical and only the
 * shape differs. Two separate components would drift.
 *
 *   `divider` — Bolt: a short green bar sitting ON a divider line, centred,
 *               shrinking from both ends.
 *   `button`  — Uber: a black fill draining across the accept button itself.
 *
 * Neither variant renders a `<Text>`, on purpose: nothing here should ever end
 * up in the accessibility snapshot, or the HUD would re-fingerprint the screen
 * once a second and strobe at exactly the wrong moment.
 *
 * No `react-native-svg` and no red "urgent" recolour — the real cards do
 * neither, and the earlier ring was an invention.
 */

import { memo } from 'react';
import { StyleSheet, View } from 'react-native';

type Variant = 'divider' | 'button';

interface Props {
  variant: Variant;
  secondsLeft: number;
  totalSeconds: number;
  color: string;
  trackColor: string;
}

/** Bolt's bar is short and centred, not a full-width progress bar. */
const DIVIDER_BAR_WIDTH = 92;

function CountdownImpl({ variant, secondsLeft, totalSeconds, color, trackColor }: Props) {
  const progress = totalSeconds > 0 ? Math.max(0, Math.min(1, secondsLeft / totalSeconds)) : 0;

  if (variant === 'button') {
    return (
      <View style={StyleSheet.absoluteFill} pointerEvents="none">
        <View style={[StyleSheet.absoluteFill, { backgroundColor: trackColor }]} />
        <View
          style={[styles.buttonFill, { backgroundColor: color, width: `${progress * 100}%` }]}
        />
      </View>
    );
  }

  return (
    <View style={[styles.dividerLine, { backgroundColor: trackColor }]}>
      <View
        style={[
          styles.dividerBar,
          { backgroundColor: color, width: DIVIDER_BAR_WIDTH * progress },
        ]}
      />
    </View>
  );
}

export const Countdown = memo(CountdownImpl);

const styles = StyleSheet.create({
  // The fill is anchored left and shrinks toward it, so the remaining black is
  // always the remaining time — the same direction the driver reads in.
  buttonFill: { position: 'absolute', left: 0, top: 0, bottom: 0 },

  dividerLine: {
    height: 1,
    width: '100%',
    alignItems: 'center',
    justifyContent: 'center',
  },
  dividerBar: {
    // Absolute so a shrinking bar never reflows the divider row it sits on.
    position: 'absolute',
    height: 5,
    borderRadius: 3,
  },
});
