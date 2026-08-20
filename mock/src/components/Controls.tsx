import type { ReactNode } from 'react';
import { Pressable, StyleSheet, Text, TextInput, View } from 'react-native';

import { ui } from '../theme';

export function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <View style={styles.section}>
      <Text style={styles.sectionTitle}>{title}</Text>
      {children}
    </View>
  );
}

export function Segmented<T extends string>({
  options,
  value,
  onChange,
}: {
  options: { value: T; label: string }[];
  value: T;
  onChange: (next: T) => void;
}) {
  return (
    <View style={styles.segmented}>
      {options.map((option) => {
        const active = option.value === value;
        return (
          <Pressable
            key={option.value}
            onPress={() => onChange(option.value)}
            style={[styles.segment, active && styles.segmentActive]}
          >
            <Text style={[styles.segmentText, active && styles.segmentTextActive]}>
              {option.label}
            </Text>
          </Pressable>
        );
      })}
    </View>
  );
}

export function Chip({
  label,
  active,
  onPress,
}: {
  label: string;
  active?: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable onPress={onPress} style={[styles.chip, active && styles.chipActive]}>
      <Text style={[styles.chipText, active && styles.chipTextActive]}>{label}</Text>
    </Pressable>
  );
}

export function NumberField({
  label,
  value,
  onChange,
  placeholder,
}: {
  label: string;
  value: string;
  onChange: (next: string) => void;
  placeholder?: string;
}) {
  return (
    <View style={styles.field}>
      <Text style={styles.fieldLabel}>{label}</Text>
      <TextInput
        value={value}
        onChangeText={onChange}
        placeholder={placeholder ?? '—'}
        placeholderTextColor={ui.faint}
        keyboardType="decimal-pad"
        inputMode="decimal"
        style={styles.input}
        selectTextOnFocus
      />
    </View>
  );
}

export function Button({
  label,
  onPress,
  tone = 'primary',
}: {
  label: string;
  onPress: () => void;
  tone?: 'primary' | 'ghost' | 'danger';
}) {
  return (
    <Pressable
      onPress={onPress}
      style={({ pressed }) => [
        styles.button,
        tone === 'primary' && styles.buttonPrimary,
        tone === 'ghost' && styles.buttonGhost,
        tone === 'danger' && styles.buttonDanger,
        pressed && { opacity: 0.75 },
      ]}
    >
      <Text
        style={[
          styles.buttonText,
          tone === 'primary' && styles.buttonTextPrimary,
          tone === 'danger' && styles.buttonTextDanger,
        ]}
      >
        {label}
      </Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  section: { marginTop: 22 },
  sectionTitle: {
    color: ui.dim,
    fontSize: 12,
    fontWeight: '700',
    letterSpacing: 0.8,
    textTransform: 'uppercase',
    marginBottom: 10,
  },
  segmented: {
    flexDirection: 'row',
    backgroundColor: ui.field,
    borderRadius: 10,
    padding: 4,
    gap: 4,
  },
  segment: {
    flex: 1,
    height: 40,
    borderRadius: 8,
    alignItems: 'center',
    justifyContent: 'center',
  },
  segmentActive: { backgroundColor: ui.accent },
  segmentText: { color: ui.dim, fontSize: 15, fontWeight: '700' },
  segmentTextActive: { color: '#04070D' },
  chip: {
    paddingHorizontal: 12,
    paddingVertical: 9,
    borderRadius: 9,
    backgroundColor: ui.field,
    borderWidth: 1,
    borderColor: ui.border,
  },
  chipActive: { backgroundColor: ui.accent, borderColor: ui.accent },
  chipText: { color: ui.text, fontSize: 13, fontWeight: '600' },
  chipTextActive: { color: '#04070D' },
  field: { flexGrow: 1, flexBasis: '30%', minWidth: 96 },
  fieldLabel: { color: ui.dim, fontSize: 12, marginBottom: 5 },
  input: {
    height: 44,
    borderRadius: 9,
    backgroundColor: ui.field,
    borderWidth: 1,
    borderColor: ui.border,
    paddingHorizontal: 12,
    color: ui.text,
    fontSize: 16,
  },
  button: {
    height: 52,
    borderRadius: 11,
    alignItems: 'center',
    justifyContent: 'center',
    borderWidth: 1,
    borderColor: ui.border,
    backgroundColor: ui.field,
  },
  buttonPrimary: { backgroundColor: ui.accent, borderColor: ui.accent },
  buttonGhost: { backgroundColor: 'transparent' },
  buttonDanger: { backgroundColor: '#2A1416', borderColor: '#5A2429' },
  buttonText: { color: ui.text, fontSize: 16, fontWeight: '700' },
  buttonTextPrimary: { color: '#04070D' },
  buttonTextDanger: { color: '#FF8A8A' },
});
