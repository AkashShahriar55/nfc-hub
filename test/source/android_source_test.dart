import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/platform/android_nfc_manager.dart';
import 'package:nfc_hub/src/source/android_source.dart';

/// A `tagDiscovered` wire event for a Type 2 (NfcA) tag with a fixed 7-byte
/// UID, addressed by [handle]. Successive calls with the same UID simulate
/// Android reader mode re-enumerating the same physical tag (field
/// flicker); a different [uid] simulates a genuinely different tap.
Map<String, Object?> _type2Event({
  required int handle,
  List<int> uid = const [0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06],
}) {
  return {
    'type': 'tagDiscovered',
    'handle': handle,
    'techList': ['android.nfc.tech.NfcA'],
    'uid': uid,
  };
}

/// Reuses the exact seam Task 3's `android_backend_test.dart` established:
/// a real [AndroidNfcManager] subclass wired to mocked method/event
/// channels, so no real platform channel is ever touched. On top of that,
/// this fake also captures the event-channel's [MockStreamHandlerEventSink]
/// (as `android_nfc_manager_test.dart` does) so tests can feed synthetic
/// `tagDiscovered` events straight through the manager's real decoding path,
/// and overrides startReaderMode/stopReaderMode to record calls instead of
/// hitting a channel.
class _FakeAndroidNfcManager extends AndroidNfcManager {
  _FakeAndroidNfcManager()
      : super(
          methodChannel: const MethodChannel('nfc_hub'),
          eventChannel: const EventChannel('nfc_hub/events'),
        );

  int startReaderModeCalls = 0;
  int stopReaderModeCalls = 0;

  @override
  Future<void> startReaderMode() async {
    startReaderModeCalls++;
  }

  @override
  Future<void> stopReaderMode() async {
    stopReaderModeCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('nfc_hub');
  const event = EventChannel('nfc_hub/events');
  MockStreamHandlerEventSink? sink;

  setUp(() {
    sink = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (_) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      event,
      MockStreamHandler.inline(onListen: (args, events) => sink = events),
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(event, null);
  });

  group('hintFromTechList', () {
    test(
        'a tag listing both NfcA and MifareClassic maps to mifareClassic, '
        'NOT type2 (precedence)', () {
      expect(
        hintFromTechList([
          'android.nfc.tech.NfcA',
          'android.nfc.tech.MifareClassic',
          'android.nfc.tech.MifareUltralight',
        ]),
        TagTechHint.mifareClassic,
      );
    });

    test('NfcA + Ndef (no MifareClassic) maps to type2', () {
      expect(
        hintFromTechList(['android.nfc.tech.NfcA', 'android.nfc.tech.Ndef']),
        TagTechHint.type2,
      );
    });

    test('NfcF maps to felica', () {
      expect(hintFromTechList(['android.nfc.tech.NfcF']), TagTechHint.felica);
    });

    test('NfcB alone (no IsoDep) maps to typeB', () {
      expect(hintFromTechList(['android.nfc.tech.NfcB']), TagTechHint.typeB);
    });

    test('IsoDep + NfcB maps to isoDep, NOT typeB (precedence)', () {
      expect(
        hintFromTechList(['android.nfc.tech.IsoDep', 'android.nfc.tech.NfcB']),
        TagTechHint.isoDep,
      );
    });

    test('an empty tech list maps to null', () {
      expect(hintFromTechList([]), isNull);
    });

    test('an unknown-only tech list maps to null', () {
      expect(hintFromTechList(['android.nfc.tech.NfcV']), isNull);
    });
  });

  group('AndroidNfcSource', () {
    test('listening to tags() calls startReaderMode() exactly once, '
        'even with two listeners (broadcast)', () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      final source = AndroidNfcSource(manager);
      final stream = source.tags();

      final sub1 = stream.listen((_) {});
      final sub2 = stream.listen((_) {});
      await pumpEventQueue();

      expect(manager.startReaderModeCalls, 1);

      await sub1.cancel();
      await sub2.cancel();
    });

    test('cancelling the last subscription calls stopReaderMode()', () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      final source = AndroidNfcSource(manager);
      final stream = source.tags();

      final sub1 = stream.listen((_) {});
      final sub2 = stream.listen((_) {});
      await pumpEventQueue();
      expect(manager.stopReaderModeCalls, 0);

      await sub1.cancel();
      await pumpEventQueue();
      expect(manager.stopReaderModeCalls, 0,
          reason: 'one listener remains');

      await sub2.cancel();
      await pumpEventQueue();
      expect(manager.stopReaderModeCalls, 1);
    });

    test('a MIFARE Classic discovery emits a MifareClassicTag', () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      final source = AndroidNfcSource(manager);
      final drivers = <TagDriver>[];
      final sub = source.tags().listen(drivers.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      sink!.success({
        'type': 'tagDiscovered',
        'handle': 1,
        'techList': [
          'android.nfc.tech.NfcA',
          'android.nfc.tech.MifareClassic',
        ],
        'uid': [0x01, 0x02, 0x03, 0x04],
        'atqa': [0x00, 0x04],
        'sak': 0x08,
      });
      await pumpEventQueue();

      expect(drivers, hasLength(1));
      expect(drivers.single, isA<MifareClassicTag>());
    });

    test('a FeliCa discovery emits a FelicaTag', () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      final source = AndroidNfcSource(manager);
      final drivers = <TagDriver>[];
      final sub = source.tags().listen(drivers.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      sink!.success({
        'type': 'tagDiscovered',
        'handle': 2,
        'techList': ['android.nfc.tech.NfcF'],
        'uid': [0x00],
        'idm': [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
        'pmm': [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10],
      });
      await pumpEventQueue();

      expect(drivers, hasLength(1));
      expect(drivers.single, isA<FelicaTag>());
    });

    test(
        'an unrecognized-tech discovery surfaces as a stream error, not '
        'silence -- a following known discovery still emits', () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      final source = AndroidNfcSource(manager);
      final drivers = <TagDriver>[];
      final errors = <Object>[];
      final sub = source.tags().listen(drivers.add,
          onError: (Object e) => errors.add(e));
      addTearDown(sub.cancel);
      await pumpEventQueue();

      sink!.success({
        'type': 'tagDiscovered',
        'handle': 1,
        'techList': ['android.nfc.tech.NfcV'],
        'uid': [0x01, 0x02, 0x03, 0x04],
      });
      await pumpEventQueue();

      expect(drivers, isEmpty);
      expect(errors, hasLength(1));
      expect(errors.single, isA<UnrecognizedTagException>());

      sink!.success({
        'type': 'tagDiscovered',
        'handle': 2,
        'techList': ['android.nfc.tech.NfcF'],
        'uid': [0x00],
        'idm': [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
        'pmm': [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10],
      });
      await pumpEventQueue();

      expect(drivers, hasLength(1));
      expect(drivers.single, isA<FelicaTag>());
    });

    test('same-UID rediscovery within the debounce window is dropped',
        () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      var fakeNow = DateTime(2026, 1, 1);
      final source = AndroidNfcSource(manager, now: () => fakeNow);
      final tags = <TagDriver>[];
      final sub = source.tags().listen(tags.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      sink!.success(_type2Event(handle: 1));
      await pumpEventQueue();
      fakeNow = fakeNow.add(const Duration(milliseconds: 300));
      sink!.success(_type2Event(handle: 2)); // same uid, flicker
      await pumpEventQueue();
      expect(tags, hasLength(1));

      fakeNow = fakeNow.add(const Duration(milliseconds: 1200));
      sink!.success(_type2Event(handle: 3)); // deliberate re-tap
      await pumpEventQueue();
      expect(tags, hasLength(2));
    });

    test('a different UID inside the debounce window still passes through',
        () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      var fakeNow = DateTime(2026, 1, 1);
      final source = AndroidNfcSource(manager, now: () => fakeNow);
      final tags = <TagDriver>[];
      final sub = source.tags().listen(tags.add);
      addTearDown(sub.cancel);
      await pumpEventQueue();

      sink!.success(_type2Event(handle: 1));
      await pumpEventQueue();
      fakeNow = fakeNow.add(const Duration(milliseconds: 300));
      sink!.success(_type2Event(
        handle: 2,
        uid: const [0x04, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF],
      ));
      await pumpEventQueue();

      expect(tags, hasLength(2));
    });

    test(
        'a stop/start cycle clears the debounce window -- a same-UID re-tap '
        'after restart is delivered, not dropped', () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      var fakeNow = DateTime(2026, 1, 1);
      final source = AndroidNfcSource(manager, now: () => fakeNow);
      final tags = <TagDriver>[];
      final sub1 = source.tags().listen(tags.add);
      await pumpEventQueue();

      sink!.success(_type2Event(handle: 1));
      await pumpEventQueue();
      expect(tags, hasLength(1));

      // Last listener cancels -- AndroidNfcSource stops reader mode.
      await sub1.cancel();
      await pumpEventQueue();

      // Still well inside what would have been the debounce window if it
      // had survived the stop.
      fakeNow = fakeNow.add(const Duration(milliseconds: 300));
      final sub2 = source.tags().listen(tags.add);
      addTearDown(sub2.cancel);
      await pumpEventQueue();

      sink!.success(_type2Event(handle: 2)); // same uid as before the stop
      await pumpEventQueue();

      expect(tags, hasLength(2),
          reason: 'a re-tap of the same tag after a stop/start cycle must '
              'not be debounced against a discovery from before the stop');
    });

    test('dispose() stops reader mode', () async {
      final manager = _FakeAndroidNfcManager();
      addTearDown(manager.dispose);
      final source = AndroidNfcSource(manager);
      final sub = source.tags().listen((_) {});
      await pumpEventQueue();

      await sub.cancel();
      await source.dispose();

      expect(manager.stopReaderModeCalls, greaterThanOrEqualTo(1));
    });
  });
}
