import { router, useFocusEffect } from 'expo-router';
import { useCallback, useMemo, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Switch, Text, View } from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';

import { Button, Chip, NumberField, Section, Segmented } from '../src/components/Controls';
import {
  DEFAULT_DRAFT,
  draftToOffer,
  encodeOffer,
  PLATFORMS,
  PRESETS,
  PRODUCTS,
  randomPreset,
  type Draft,
  type Platform,
} from '../src/offer';
import { markerText, previewLines } from '../src/offerText';
import { PLATFORM_THEME, ui } from '../src/theme';

const DEFAULT_SHOW_SECONDS = '15';
const DEFAULT_HIDE_SECONDS = '6';

/**
 * Control panel.
 *
 * Note what is NOT here: the `__rg_platform=` marker. Only the offer screen
 * emits it, so RideGuard has nothing to latch onto while you are setting an
 * offer up — which also makes this screen the natural "HUD should disappear
 * now" case to test.
 */
export default function ControlPanel() {
  const insets = useSafeAreaInsets();

  const [platform, setPlatform] = useState<Platform>('bolt');
  const [draft, setDraft] = useState<Draft>(DEFAULT_DRAFT);
  const [presetId, setPresetId] = useState<string>(PRESETS[0].id);
  const [showSeconds, setShowSeconds] = useState(DEFAULT_SHOW_SECONDS);
  const [hideSeconds, setHideSeconds] = useState(DEFAULT_HIDE_SECONDS);
  const [autoLoop, setAutoLoop] = useState(false);
  const [showPreview, setShowPreview] = useState(false);
  const [nextIn, setNextIn] = useState<number | null>(null);

  const seconds = useCallback((raw: string, fallback: number) => {
    const parsed = Number(raw.replace(',', '.'));
    return Number.isFinite(parsed) && parsed > 0 ? Math.round(parsed) : fallback;
  }, []);

  const set = useCallback((key: keyof Draft, value: string) => {
    setDraft((prev) => ({ ...prev, [key]: value }));
    setPresetId('');
  }, []);

  const fire = useCallback(
    (d: Draft, p: Platform, showFor: number) => {
      router.push({
        pathname: '/offer',
        params: {
          platform: p,
          offer: encodeOffer(draftToOffer(d, p)),
          seconds: String(showFor),
        },
      });
    },
    [],
  );

  const onPlatformChange = useCallback((next: Platform) => {
    setPlatform(next);
    // Product names are per-platform; drop back to the platform default rather
    // than showing Bolt a tier called "UberX".
    setDraft((prev) => ({ ...prev, product: '' }));
  }, []);

  /**
   * Auto-fire loop. Scoped to focus, so the timer only runs while the control
   * panel is on screen: hide for N seconds here, then push a random preset,
   * which shows for its own countdown and pops back here to start over.
   */
  useFocusEffect(
    useCallback(() => {
      if (!autoLoop) {
        setNextIn(null);
        return;
      }

      const hideFor = seconds(hideSeconds, 6);
      const showFor = seconds(showSeconds, 15);
      let remaining = hideFor;
      setNextIn(remaining);

      const tick = setInterval(() => {
        remaining = Math.max(0, remaining - 1);
        setNextIn(remaining);
      }, 1000);

      const shot = setTimeout(() => {
        const preset = randomPreset();
        setDraft(preset.draft);
        setPresetId(preset.id);
        fire(preset.draft, platform, showFor);
      }, hideFor * 1000);

      return () => {
        clearInterval(tick);
        clearTimeout(shot);
      };
    }, [autoLoop, hideSeconds, showSeconds, platform, fire, seconds]),
  );

  const preview = useMemo(
    () => previewLines(platform, draftToOffer(draft, platform)),
    [platform, draft],
  );

  const products = PRODUCTS[platform];
  const activeProduct = draft.product || products[0];

  return (
    <ScrollView
      style={styles.root}
      contentContainerStyle={[
        styles.content,
        { paddingTop: insets.top + 16, paddingBottom: insets.bottom + 32 },
      ]}
      keyboardShouldPersistTaps="handled"
    >
      <Text style={styles.title}>RideGuard mock driver</Text>
      <Text style={styles.subtitle}>
        com.rideguard.mock · fake Bolt / Uber offer screens for testing the overlay
      </Text>

      <Section title="Platform">
        <Segmented
          value={platform}
          onChange={onPlatformChange}
          options={PLATFORMS.map((p) => ({ value: p, label: PLATFORM_THEME[p].label }))}
        />
        <Text style={styles.hint}>Marker emitted on the offer screen: {markerText(platform)}</Text>
      </Section>

      <Section title="Presets">
        <View style={styles.wrap}>
          {PRESETS.map((preset) => (
            <Chip
              key={preset.id}
              label={preset.label}
              active={preset.id === presetId}
              onPress={() => {
                setDraft(preset.draft);
                setPresetId(preset.id);
              }}
            />
          ))}
        </View>
        {presetId !== '' && (
          <Text style={styles.hint}>
            {PRESETS.find((p) => p.id === presetId)?.note}
          </Text>
        )}
      </Section>

      <Section title="Offer">
        <View style={styles.wrap}>
          {/* Both apps are Romanian and both pay in RON; only the word on the
              card differs ("lei" on Bolt, "RON" on Uber). */}
          <NumberField
            label={platform === 'bolt' ? 'Fare (lei)' : 'Fare (RON)'}
            value={draft.fare}
            onChange={(v) => set('fare', v)}
          />
          <NumberField
            label="Pickup km"
            value={draft.pickupKm}
            onChange={(v) => set('pickupKm', v)}
            placeholder="blank = hide"
          />
          <NumberField
            label="Pickup min"
            value={draft.pickupMin}
            onChange={(v) => set('pickupMin', v)}
            placeholder="blank = hide"
          />
          <NumberField label="Trip km" value={draft.tripKm} onChange={(v) => set('tripKm', v)} />
          <NumberField label="Trip min" value={draft.tripMin} onChange={(v) => set('tripMin', v)} />
          <NumberField
            label="Rating"
            value={draft.passengerRating}
            onChange={(v) => set('passengerRating', v)}
          />
          <NumberField
            label="Surge x"
            value={draft.surge}
            onChange={(v) => set('surge', v)}
            placeholder="off"
          />
        </View>
        <Text style={styles.hint}>
          Leave a field blank to leave that text off the card entirely — that is how the
          &ldquo;Single distance&rdquo; low-confidence case is reproduced.
        </Text>
      </Section>

      <Section title="Product tier">
        <View style={styles.wrap}>
          {products.map((product) => (
            <Chip
              key={product}
              label={product}
              active={product === activeProduct}
              onPress={() => set('product', product)}
            />
          ))}
        </View>
      </Section>

      <Section title="Fire">
        <View style={styles.wrap}>
          <NumberField label="Show for (s)" value={showSeconds} onChange={setShowSeconds} />
          <NumberField label="Hide for (s)" value={hideSeconds} onChange={setHideSeconds} />
        </View>
        <View style={styles.fireRow}>
          <Button
            label="Fire offer"
            onPress={() => fire(draft, platform, seconds(showSeconds, 15))}
          />
        </View>
        <View style={styles.switchRow}>
          <View style={styles.switchText}>
            <Text style={styles.switchLabel}>Auto-fire loop</Text>
            <Text style={styles.hint}>
              {autoLoop
                ? `Random preset every ${seconds(hideSeconds, 6)}s${
                    nextIn === null ? '' : ` · next in ${nextIn}s`
                  }`
                : 'Show a random preset, hide, repeat — hands-free overlay testing'}
            </Text>
          </View>
          <Switch
            value={autoLoop}
            onValueChange={setAutoLoop}
            trackColor={{ true: ui.accent, false: ui.border }}
            thumbColor={ui.text}
          />
        </View>
      </Section>

      <Section title="Text nodes">
        <Pressable onPress={() => setShowPreview((v) => !v)} style={styles.previewToggle}>
          <Text style={styles.previewToggleText}>
            {showPreview ? 'Hide' : 'Show'} the exact strings the card will render
          </Text>
        </Pressable>
        {showPreview && (
          <View style={styles.preview}>
            {preview.map((line, index) => (
              <Text key={`${index}-${line}`} style={styles.previewLine}>
                {line}
              </Text>
            ))}
            <Text style={styles.hint}>
              Off by default: these strings are parseable, and showing them puts a
              second &ldquo;offer&rdquo; on screen while you are still setting one up.
            </Text>
          </View>
        )}
      </Section>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: ui.bg },
  content: { paddingHorizontal: 20 },
  title: { color: ui.text, fontSize: 24, fontWeight: '800' },
  subtitle: { color: ui.dim, fontSize: 13, marginTop: 6, lineHeight: 18 },
  hint: { color: ui.faint, fontSize: 12, marginTop: 8, lineHeight: 17 },
  wrap: { flexDirection: 'row', flexWrap: 'wrap', gap: 10 },
  fireRow: { marginTop: 14 },
  switchRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 16,
    marginTop: 18,
  },
  switchText: { flex: 1 },
  switchLabel: { color: ui.text, fontSize: 16, fontWeight: '700' },
  previewToggle: {
    paddingVertical: 10,
  },
  previewToggleText: { color: ui.accent, fontSize: 14, fontWeight: '600' },
  preview: {
    backgroundColor: ui.panel,
    borderRadius: 10,
    borderWidth: 1,
    borderColor: ui.border,
    padding: 14,
    gap: 4,
  },
  previewLine: {
    color: ui.text,
    fontSize: 13,
    fontFamily: 'monospace',
  },
});
