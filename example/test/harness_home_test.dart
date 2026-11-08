import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub_example/harness_home.dart';

/// A minimal local fake -- scripts only the transport calls
/// `Type2Tag.readTagInfo()` actually makes (`readUid()` and
/// `readCapabilityContainer()`, best-effort). `readPages`/`getVersion`
/// aren't touched by `readTagInfo()` so they're left unscripted.
class _FakeType2Transport implements Type2Transport {
  _FakeType2Transport({this.uid, this.cc, this.throwOnUid = false});

  final Uint8List? uid;
  final Uint8List? cc;
  final bool throwOnUid;

  @override
  Future<Uint8List> readUid() async {
    if (throwOnUid) throw Exception('tag lost');
    return uid ?? (throw Exception('no uid scripted'));
  }

  @override
  Future<Uint8List> readCapabilityContainer() async =>
      cc ?? (throw Exception('no CC scripted'));

  @override
  Future<Uint8List> readPages(int startPage) async =>
      throw Exception('page $startPage not scripted');

  @override
  Future<Uint8List?> getVersion() async => null;
}

void main() {
  Widget host(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('shows the empty-state hint before any tag is detected',
      (tester) async {
    final tagsController = StreamController<TagDriver>.broadcast();
    final statesController = StreamController<CcidConnectionState>.broadcast();
    addTearDown(tagsController.close);
    addTearDown(statesController.close);

    await tester.pumpWidget(host(HarnessHome(
      tags: tagsController.stream,
      connectionState: statesController.stream,
    )));

    expect(find.textContaining('Tap a tag or place a card'), findsOneWidget);
  });

  testWidgets('a detected tag appears with its technology and UID',
      (tester) async {
    final tagsController = StreamController<TagDriver>.broadcast();
    final statesController = StreamController<CcidConnectionState>.broadcast();
    addTearDown(tagsController.close);
    addTearDown(statesController.close);

    await tester.pumpWidget(host(HarnessHome(
      tags: tagsController.stream,
      connectionState: statesController.stream,
    )));

    tagsController.add(Type2Tag(_FakeType2Transport(
      uid: Uint8List.fromList([0x04, 0x01, 0x02, 0x03]),
      cc: Uint8List.fromList([0xE1, 0x10, 0x06, 0x00]),
    )));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('NFC Forum Type 2'),
      findsOneWidget,
    );
    expect(find.textContaining('04010203'), findsOneWidget);
  });

  testWidgets('a second tag appears above the first (most-recent-first)',
      (tester) async {
    final tagsController = StreamController<TagDriver>.broadcast();
    final statesController = StreamController<CcidConnectionState>.broadcast();
    addTearDown(tagsController.close);
    addTearDown(statesController.close);

    await tester.pumpWidget(host(HarnessHome(
      tags: tagsController.stream,
      connectionState: statesController.stream,
    )));

    tagsController.add(Type2Tag(_FakeType2Transport(
      uid: Uint8List.fromList([0x04, 0x01, 0x02, 0x03]),
      cc: Uint8List.fromList([0xE1, 0x10, 0x06, 0x00]),
    )));
    await tester.pumpAndSettle();

    tagsController.add(Type2Tag(_FakeType2Transport(
      uid: Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD]),
      cc: Uint8List.fromList([0xE1, 0x10, 0x06, 0x00]),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('04010203'), findsOneWidget);
    expect(find.textContaining('aabbccdd'), findsOneWidget);

    final subtitles = tester
        .widgetList<Text>(find.textContaining('UID:'))
        .map((t) => t.data)
        .toList();
    expect(subtitles.length, 2);
    expect(subtitles.first, contains('aabbccdd'));
    expect(subtitles.last, contains('04010203'));
  });

  testWidgets(
      'a stream error (e.g. an unrecognized tap) shows a SnackBar instead '
      'of becoming an unhandled zone error', (tester) async {
    // Regression (final review, Finding 4): the harness listened without
    // onError, so a per-tap failure like UnrecognizedTagException crashed
    // the zone and hardware-validation scenario 9 was unobservable.
    final tagsController = StreamController<TagDriver>.broadcast();
    final statesController = StreamController<CcidConnectionState>.broadcast();
    addTearDown(tagsController.close);
    addTearDown(statesController.close);

    await tester.pumpWidget(host(HarnessHome(
      tags: tagsController.stream,
      connectionState: statesController.stream,
    )));

    tagsController.addError(const UnrecognizedTagException('unsupported tech'));
    await tester.pump(); // deliver the error
    await tester.pump(); // let the SnackBar animate in

    expect(find.textContaining('Could not read tag'), findsOneWidget);

    // The subscription survives: a good tag afterwards still appears.
    tagsController.add(Type2Tag(_FakeType2Transport(
      uid: Uint8List.fromList([0x04, 0x01, 0x02, 0x03]),
      cc: Uint8List.fromList([0xE1, 0x10, 0x06, 0x00]),
    )));
    await tester.pumpAndSettle();
    expect(find.textContaining('04010203'), findsOneWidget);
  });

  testWidgets(
      'a tag whose readTagInfo() throws still appears (with its error), '
      'and a following good tag still appears', (tester) async {
    final tagsController = StreamController<TagDriver>.broadcast();
    final statesController = StreamController<CcidConnectionState>.broadcast();
    addTearDown(tagsController.close);
    addTearDown(statesController.close);

    await tester.pumpWidget(host(HarnessHome(
      tags: tagsController.stream,
      connectionState: statesController.stream,
    )));

    tagsController.add(Type2Tag(_FakeType2Transport(throwOnUid: true)));
    await tester.pumpAndSettle();

    expect(find.text('Type2Tag'), findsOneWidget);
    expect(find.textContaining('tag lost'), findsOneWidget);

    tagsController.add(Type2Tag(_FakeType2Transport(
      uid: Uint8List.fromList([0x01, 0x02, 0x03, 0x04]),
      cc: Uint8List.fromList([0xE1, 0x10, 0x06, 0x00]),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('01020304'), findsOneWidget);
    expect(find.text('Type2Tag'), findsOneWidget);
  });
}
