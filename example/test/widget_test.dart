// A smoke test for the harness home screen.
//
// This intentionally does NOT pump the real `MyApp()`: that widget builds
// a real `NfcHub`, which would hit platform channels that don't exist in
// the widget-test environment and hang/fail. Instead it pumps
// `HarnessHome` directly with injected empty streams, exercising the same
// widget tree `MyApp` wires up without touching any platform channel.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';

import 'package:nfc_hub_example/connection_status_bar.dart';
import 'package:nfc_hub_example/harness_home.dart';

void main() {
  testWidgets('HarnessHome renders the status bar and the empty-state hint',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: HarnessHome(
            tags: Stream<TagDriver>.empty(),
            connectionState: Stream<CcidConnectionState>.empty(),
          ),
        ),
      ),
    );
    await tester.pump();

    // The empty-state hint is shown when no tag has been detected yet.
    expect(
      find.text('Tap a tag or place a card on a reader…'),
      findsOneWidget,
    );

    // The dual-source connection status bar is always present.
    expect(find.byType(ConnectionStatusBar), findsOneWidget);
  });
}
