import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub_example/connection_status_bar.dart';

void main() {
  testWidgets('disabled NFC shows an Enable button that calls onEnableNfc',
      (tester) async {
    final controller = StreamController<NfcConnectionState>.broadcast();
    var enableCalled = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ConnectionStatusBar(
          states: controller.stream,
          onEnableNfc: () async => enableCalled = true,
        ),
      ),
    ));
    controller.add(const NfcConnectionState(
      builtInNfcAvailable: false,
      builtInNfcReason: NfcUnavailableReason.disabled,
      externalReaders: [],
    ));
    await tester.pump();
    expect(find.text('Enable'), findsOneWidget);
    await tester.tap(find.text('Enable'));
    expect(enableCalled, isTrue);
    await controller.close();
  });

  testWidgets('shows an attached reader with card-present state',
      (tester) async {
    final controller = StreamController<NfcConnectionState>.broadcast();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ConnectionStatusBar(states: controller.stream)),
    ));
    controller.add(const NfcConnectionState(
      builtInNfcAvailable: true,
      builtInNfcReason: NfcUnavailableReason.none,
      externalReaders: [ExternalReaderState('ACR122U', true)],
    ));
    await tester.pump();
    expect(find.textContaining('ACR122U'), findsOneWidget);
    await controller.close();
  });

  testWidgets('NFC ready shows no Enable button', (tester) async {
    final controller = StreamController<NfcConnectionState>.broadcast();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ConnectionStatusBar(states: controller.stream)),
    ));
    controller.add(const NfcConnectionState(
      builtInNfcAvailable: true,
      builtInNfcReason: NfcUnavailableReason.none,
      externalReaders: [],
    ));
    await tester.pump();
    expect(find.text('Enable'), findsNothing);
    expect(find.textContaining('NFC ready'), findsOneWidget);
    await controller.close();
  });
}
