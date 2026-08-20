import { StyleSheet, Text } from 'react-native';

import { markerText } from '../offerText';
import type { Platform } from '../offer';

/**
 * Renders `__rg_platform=bolt` / `__rg_platform=uber` as a real `<Text>`.
 *
 * ## Contract — read before touching the styles
 *
 * This app's package is `com.rideguard.mock`, so RideGuard cannot pick a
 * parser by package name the way it does for `ee.mtakso.driver` and
 * `com.ubercab.driver`. This string is how it knows which card it is looking
 * at. The reader (`AccessibilityTreeReader`) skips any node where
 * `isVisibleToUser` is false or `bounds.area <= 0`, so the marker must stay
 * genuinely laid out and genuinely visible:
 *
 *   - NO `display: 'none'`, NO `opacity: 0`, NO `width/height: 0`
 *   - NO `accessibilityElementsHidden` / `importantForAccessibility="no"`
 *   - NO putting it inside a zero-height or collapsed parent
 *
 * Tiny type plus a near-transparent colour makes it invisible to a human
 * while leaving a real, measurable TextView in the accessibility tree.
 */
export function PlatformMarker({ platform }: { platform: Platform }) {
  return (
    <Text style={styles.marker} selectable={false}>
      {markerText(platform)}
    </Text>
  );
}

const styles = StyleSheet.create({
  marker: {
    fontSize: 1,
    // A few real pixels of height so the node's bounds can never round to zero.
    lineHeight: 4,
    opacity: 0.02,
    color: '#808080',
  },
});
