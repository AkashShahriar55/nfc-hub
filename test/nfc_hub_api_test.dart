import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/platform/android_nfc_manager.dart';
import 'package:nfc_hub/src/source/ccid_source.dart';

/// Real NTAG213/Ultralight-shaped ATR, lifted from
/// `test/source/ccid_source_test.dart` (itself lifted from
/// `test/tag/detection_test.dart`): resolves to a [Type2Tag] via
/// `identifyTag`'s ATR fast path with zero `transceive` calls, so
/// [_FakePlatform] only needs to answer [CcidSource]'s own liveness probe.
final _type2Atr = Uint8List.fromList([
  0x3B, 0x8F, 0x80, 0x01, //
  0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x03,
]);

/// Scriptable fake of [NfcHubPlatform]'s CCID surface -- the same shape as
/// `test/source/ccid_source_test.dart`'s `_FakePlatform`, duplicated here
/// (Dart privacy is per-file) rather than shared.
class _FakePlatform extends NfcHubPlatform {
  List<String> readers = [];
  final Set<String> cardsPresent = {};
  final List<String> listReadersLog = [];
  final List<String> connectLog = [];

  @override
  Future<List<String>> listReaders() async {
    listReadersLog.add('listReaders');
    return List.of(readers);
  }

  @override
  Future<CcidCard> connect(String reader) async {
    connectLog.add(reader);
    if (!cardsPresent.contains(reader)) {
      throw Exception('no card seated in $reader');
    }
    return CcidCard(reader, atr: _type2Atr);
  }

  @override
  Future<String?> transceive(String reader, String capdu) async {
    if (!cardsPresent.contains(reader)) {
      throw Exception('card removed from $reader');
    }
    return '9000';
  }

  @override
  Future<void> disconnect(String reader) async {}
}

/// Reuses the exact seam `test/source/android_source_test.dart` and
/// `test/platform/android_nfc_manager_test.dart` established: a real
/// [AndroidNfcManager] subclass wired to mocked method/event channels, with
/// startReaderMode/stopReaderMode/openNfcSettings overridden to record calls
/// instead of hitting a channel. `getNfcState()` and `nfcStateChanges` are
/// deliberately left un-overridden -- they go through the real mocked
/// method/event channel (see `setUp` below), exactly like
/// `android_nfc_manager_test.dart` exercises them.
class _FakeAndroidNfcManager extends AndroidNfcManager {
  _FakeAndroidNfcManager()
      : super(
          methodChannel: const MethodChannel('nfc_hub'),
          eventChannel: const EventChannel('nfc_hub/events'),
        );

  int startReaderModeCalls = 0;
  int stopReaderModeCalls = 0;
  int openNfcSettingsCalls = 0;

  @override
  Future<void> startReaderMode() async {
    startReaderModeCalls++;
  }

  @override
  Future<void> stopReaderMode() async {
    stopReaderModeCalls++;
  }

  @override
  Future<void> openNfcSettings() async {
    openNfcSettingsCalls++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const method = MethodChannel('nfc_hub');
  const event = EventChannel('nfc_hub/events');
  MockStreamHandlerEventSink? sink;
  var nfcStateResponse = 'enabled';

  setUp(() {
    sink = null;
    nfcStateResponse = 'enabled';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      if (call.method == 'getNfcState') return nfcStateResponse;
      return null;
    });
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

  void emitFelicaDiscovery(int handle) {
    sink!.success({
      'type': 'tagDiscovered',
      'handle': handle,
      'techList': ['android.nfc.tech.NfcF'],
      'uid': [0x00],
      'idm': [0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08],
      'pmm': [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10],
    });
  }

  group('NfcHub.tagStream', () {
    // These use real async timing (a short CCID poll interval + real
    // Future.delayed), NOT FakeAsync -- combining FakeAsync with
    // AndroidNfcSource doesn't work: cancelling a subscription that
    // traces back to AndroidNfcManager's mocked event channel (and
    // delivering a sink event through it) both need a genuine event-loop
    // turn that FakeAsync's synchronous time-faking cannot fake. The same
    // seam `android_source_test.dart`/`android_nfc_manager_test.dart` use
    // (`pumpEventQueue()`, real timers) is reused here instead.
    test(
        'no filter: emits tags from BOTH a fake Android source and a fake '
        'CCID source, interleaved', () async {
      final manager = _FakeAndroidNfcManager();
      final platform = _FakePlatform()
        ..readers = ['reader-1']
        ..cardsPresent.add('reader-1');
      final hub = NfcHub(
        androidNfcManager: manager,
        // A poll interval long enough that the first CCID tick can't have
        // fired yet by the time the Android-source assertion below runs
        // (a plain `pumpEventQueue()` completes in well under a
        // millisecond), so the two sources' arrival order is deterministic
        // despite using real wall-clock timing.
        ccidSource: CcidSource(
          platform,
          pollInterval: const Duration(milliseconds: 300),
        ),
      );

      final drivers = <TagDriver>[];
      final sub = hub.tagStream().listen(drivers.add);
      await pumpEventQueue();

      // Android-source tag first.
      emitFelicaDiscovery(1);
      await pumpEventQueue();
      expect(drivers, hasLength(1));
      expect(drivers.single, isA<FelicaTag>());

      // CCID-source tag next, once a poll tick runs.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(drivers, hasLength(2));
      expect(drivers.last, isA<Type2Tag>());

      await sub.cancel();
    });

    test('from: builtInNfc() emits ONLY Android-source tags', () async {
      final manager = _FakeAndroidNfcManager();
      final platform = _FakePlatform()
        ..readers = ['reader-1']
        ..cardsPresent.add('reader-1');
      final hub = NfcHub(
        androidNfcManager: manager,
        ccidSource: CcidSource(
          platform,
          pollInterval: const Duration(milliseconds: 5),
        ),
      );

      final drivers = <TagDriver>[];
      final sub = hub
          .tagStream(from: const CcidSourceFilter.builtInNfc())
          .listen(drivers.add);
      await pumpEventQueue();

      emitFelicaDiscovery(1);
      await pumpEventQueue();

      // Well past several CCID poll intervals -- CCID must never even be
      // started under this filter, so its card is never reported.
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(drivers, hasLength(1));
      expect(drivers.single, isA<FelicaTag>());
      expect(platform.listReadersLog, isEmpty,
          reason: 'CCID source was never started under this filter');

      await sub.cancel();
    });

    test("from: reader(name) emits ONLY that reader's tags", () {
      FakeAsync().run((async) {
        final manager = _FakeAndroidNfcManager();
        final platform = _FakePlatform()
          ..readers = ['reader-1', 'reader-2']
          ..cardsPresent.addAll(['reader-1', 'reader-2']);
        final hub = NfcHub(
          androidNfcManager: manager,
          ccidSource: CcidSource(platform),
        );

        final drivers = <TagDriver>[];
        final sub = hub
            .tagStream(from: const CcidSourceFilter.reader('reader-1'))
            .listen(drivers.add);

        async.elapse(const Duration(milliseconds: 500));

        // Both readers were actually polled and connected by CcidSource --
        // proving the filtering happens on top of both readers' real
        // activity, not because only one reader ever had a card.
        expect(platform.connectLog, containsAll(['reader-1', 'reader-2']));
        expect(drivers, hasLength(1),
            reason: "only reader-1's tag should have reached this stream");

        expect(manager.startReaderModeCalls, 0,
            reason: 'Android source was never started under this filter');

        sub.cancel();
      });
    });

    test(
        'starts BOTH sources on listen and stops them on cancel (no leaked '
        'reader mode / poll loop)', () async {
      final manager = _FakeAndroidNfcManager();
      final platform = _FakePlatform()..readers = ['reader-1'];
      final hub = NfcHub(
        androidNfcManager: manager,
        ccidSource: CcidSource(
          platform,
          pollInterval: const Duration(milliseconds: 5),
        ),
      );

      final sub = hub.tagStream().listen((_) {});
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(manager.startReaderModeCalls, 1);
      expect(platform.listReadersLog, isNotEmpty);

      await sub.cancel();
      await pumpEventQueue();

      expect(manager.stopReaderModeCalls, 1);
      final pollCountAtCancel = platform.listReadersLog.length;

      // Wait well past several more poll intervals: nothing further should
      // happen on either source now that the merged stream has no
      // listeners.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(platform.listReadersLog.length, pollCountAtCancel,
          reason: 'CCID polling must stop once the merged stream is '
              'cancelled');
    });
  });

  group('NfcHub.readTag', () {
    test('returns the first tag from any source', () async {
      final manager = _FakeAndroidNfcManager();
      final hub = NfcHub(
        androidNfcManager: manager,
        ccidSource: CcidSource(_FakePlatform()),
      );

      final future = hub.readTag();
      await pumpEventQueue();
      emitFelicaDiscovery(1);

      final driver = await future;
      expect(driver, isA<FelicaTag>());
    });

    test('with a timeout throws TimeoutException when nothing arrives',
        () async {
      final manager = _FakeAndroidNfcManager();
      final hub = NfcHub(
        androidNfcManager: manager,
        ccidSource: CcidSource(_FakePlatform()),
      );

      await expectLater(
        hub.readTag(timeout: const Duration(milliseconds: 20)),
        throwsA(isA<TimeoutException>()),
      );
    });
  });

  group('NfcHub.connectionState', () {
    test('NfcState.enabled -> builtInNfcAvailable: true, reason: none',
        () async {
      nfcStateResponse = 'enabled';
      final manager = _FakeAndroidNfcManager();
      final hub = NfcHub(
        androidNfcManager: manager,
        ccidSource: CcidSource(_FakePlatform()),
      );

      final states = <CcidConnectionState>[];
      final sub = hub.connectionState().listen(states.add);
      await pumpEventQueue();

      expect(states, isNotEmpty);
      expect(states.last.builtInNfcAvailable, true);
      expect(states.last.builtInNfcReason, NfcUnavailableReason.none);

      await sub.cancel();
    });

    test('NfcState.disabled -> builtInNfcAvailable: false, reason: disabled',
        () async {
      nfcStateResponse = 'disabled';
      final manager = _FakeAndroidNfcManager();
      final hub = NfcHub(
        androidNfcManager: manager,
        ccidSource: CcidSource(_FakePlatform()),
      );

      final states = <CcidConnectionState>[];
      final sub = hub.connectionState().listen(states.add);
      await pumpEventQueue();

      expect(states.last.builtInNfcAvailable, false);
      expect(states.last.builtInNfcReason, NfcUnavailableReason.disabled);

      await sub.cancel();
    });

    test(
        'NfcState.noHardware -> builtInNfcAvailable: false, '
        'reason: noHardware', () async {
      nfcStateResponse = 'noHardware';
      final manager = _FakeAndroidNfcManager();
      final hub = NfcHub(
        androidNfcManager: manager,
        ccidSource: CcidSource(_FakePlatform()),
      );

      final states = <CcidConnectionState>[];
      final sub = hub.connectionState().listen(states.add);
      await pumpEventQueue();

      expect(states.last.builtInNfcAvailable, false);
      expect(states.last.builtInNfcReason, NfcUnavailableReason.noHardware);

      await sub.cancel();
    });

    test('reflects CcidSource.readerStates() -- a reader with a card shows '
        'ExternalReaderState(name, true)', () {
      FakeAsync().run((async) {
        final manager = _FakeAndroidNfcManager();
        final platform = _FakePlatform()
          ..readers = ['reader-1']
          ..cardsPresent.add('reader-1');
        final hub = NfcHub(
          androidNfcManager: manager,
          ccidSource: CcidSource(platform),
        );

        final states = <CcidConnectionState>[];
        final sub = hub.connectionState().listen(states.add);

        async.elapse(const Duration(milliseconds: 500));

        expect(states.last.externalReaders,
            [const ExternalReaderState('reader-1', true)]);

        sub.cancel();
      });
    });
  });

  group('NfcHub.openNfcSettings', () {
    test('delegates to AndroidNfcManager.openNfcSettings()', () async {
      final manager = _FakeAndroidNfcManager();
      final hub = NfcHub(
        androidNfcManager: manager,
        ccidSource: CcidSource(_FakePlatform()),
      );

      await hub.openNfcSettings();

      expect(manager.openNfcSettingsCalls, 1);
    });
  });
}
