import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';

import { ui } from '../src/theme';

/**
 * Two screens only: the control panel and the offer card.
 * expo-router already provides the SafeAreaProvider, so nothing else is needed.
 */
export default function RootLayout() {
  return (
    <>
      <StatusBar style="light" />
      <Stack
        screenOptions={{
          headerShown: false,
          contentStyle: { backgroundColor: ui.bg },
          animation: 'fade',
        }}
      >
        <Stack.Screen name="index" />
        <Stack.Screen
          name="offer"
          options={{ animation: 'slide_from_bottom', gestureEnabled: false }}
        />
      </Stack>
    </>
  );
}
