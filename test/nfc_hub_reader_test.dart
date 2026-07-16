import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';

/// A minimal identified tag for session tests — carries a name for ordering
/// assertions. readTagInfo() is never called by these tests.
class _FakeTag extends TagDriver {
  _FakeTag(this.name);
  final String name;

  @override
  Future<TagInfo> readTagInfo() async =>
      throw UnimplementedError('not needed in these tests');
}

/// A fake NfcHub the facade is built over. Records the last `from` filter,
/// exposes a controllable tag stream, and counts passthrough calls.
class _FakeNfcHub extends NfcHub {
  final tagController = StreamController<TagDriver>.broadcast();
  final stateController = StreamController<CcidConnectionState>.broadcast();

  CcidSourceFilter? lastFrom;
  bool tagStreamCalled = false;
  bool availableReturn = true;
  int openNfcSettingsCalls = 0;
  int connectionStateCalls = 0;

  @override
  Stream<TagDriver> tagStream({CcidSourceFilter? from}) {
    tagStreamCalled = true;
    lastFrom = from;
    return tagController.stream;
  }

  @override
  Stream<CcidConnectionState> connectionState() {
    connectionStateCalls++;
    return stateController.stream;
  }

  @override
  Future<bool> isAvailable() async => availableReturn;

  @override
  Future<void> openNfcSettings() async {
    openNfcSettingsCalls++;
  }
}

void main() {
  test('NfcSource.builtIn() maps to CcidSourceFilter.builtInNfc()', () {
    expect(const NfcSource.builtIn().toFilter(),
        equals(const CcidSourceFilter.builtInNfc()));
  });

  test('NfcSource.reader(name) maps to CcidSourceFilter.reader(name)', () {
    expect(const NfcSource.reader('ACR122U').toFilter(),
        equals(const CcidSourceFilter.reader('ACR122U')));
  });

  test('isAvailable() delegates to the underlying NfcHub', () async {
    final hub = _FakeNfcHub()..availableReturn = false;
    final reader = NfcHubReader.forTesting(hub);
    expect(await reader.isAvailable(), isFalse);
    hub.availableReturn = true;
    expect(await reader.isAvailable(), isTrue);
  });

  test('connectionState() delegates to the underlying NfcHub', () {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final stream = reader.connectionState();
    expect(hub.connectionStateCalls, 1);
    expect(stream, isA<Stream<NfcConnectionState>>());
  });

  test('openNfcSettings() delegates to the underlying NfcHub', () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    await reader.openNfcSettings();
    expect(hub.openNfcSettingsCalls, 1);
  });

  test('startSession delivers each emitted tag to onDiscovered once',
      () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final seen = <String>[];

    reader.startSession(onDiscovered: (tag) {
      seen.add((tag as _FakeTag).name);
    });
    hub.tagController.add(_FakeTag('A'));
    hub.tagController.add(_FakeTag('B'));
    await pumpEventQueue();

    expect(seen, ['A', 'B']);
  });

  test('stopSession cancels the subscription — no callbacks after stop',
      () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final seen = <String>[];

    reader.startSession(onDiscovered: (tag) => seen.add((tag as _FakeTag).name));
    hub.tagController.add(_FakeTag('A'));
    await pumpEventQueue();
    await reader.stopSession();
    hub.tagController.add(_FakeTag('B'));
    await pumpEventQueue();

    expect(seen, ['A']);
  });

  test('stopSession with no active session is a no-op', () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    await reader.stopSession(); // must not throw
  });

  test('startSession twice replaces the previous session', () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final first = <String>[];
    final second = <String>[];

    reader.startSession(onDiscovered: (tag) => first.add((tag as _FakeTag).name));
    reader.startSession(onDiscovered: (tag) => second.add((tag as _FakeTag).name));
    hub.tagController.add(_FakeTag('A'));
    await pumpEventQueue();

    expect(first, isEmpty);
    expect(second, ['A']);
  });

  test('onDiscovered is serialized — the next call waits for the previous',
      () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final events = <String>[];
    final gateA = Completer<void>();

    reader.startSession(onDiscovered: (tag) async {
      final name = (tag as _FakeTag).name;
      events.add('start:$name');
      if (name == 'A') await gateA.future;
      events.add('end:$name');
    });
    hub.tagController.add(_FakeTag('A'));
    hub.tagController.add(_FakeTag('B'));
    await pumpEventQueue();

    // B must not have started while A is still awaiting its gate.
    expect(events, ['start:A']);

    gateA.complete();
    await pumpEventQueue();
    expect(events, ['start:A', 'end:A', 'start:B', 'end:B']);
  });

  test(
      'startSession replace waits for an in-flight onDiscovered before the '
      'next session reads', () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final events = <String>[];
    final gateA = Completer<void>();

    // First session: A blocks on gateA while "in flight".
    reader.startSession(onDiscovered: (tag) async {
      final name = (tag as _FakeTag).name;
      events.add('start:$name');
      if (name == 'A') await gateA.future;
      events.add('end:$name');
    });
    hub.tagController.add(_FakeTag('A'));
    await pumpEventQueue();

    // A has started but is gated (still in flight).
    expect(events, ['start:A']);

    // Replace the session while A is still running.
    reader.startSession(onDiscovered: (tag) async {
      events.add('start:${(tag as _FakeTag).name}');
      events.add('end:${tag.name}');
    });
    hub.tagController.add(_FakeTag('B'));
    await pumpEventQueue();

    // B must NOT have started while A is still gated — serialization holds
    // across the replace.
    expect(events, ['start:A']);

    gateA.complete();
    await pumpEventQueue();

    // A finishes before B starts — no overlap across the session replace.
    expect(events, ['start:A', 'end:A', 'start:B', 'end:B']);
  });

  test('a throwing onDiscovered does not stop later deliveries', () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final seen = <String>[];

    reader.startSession(onDiscovered: (tag) {
      final name = (tag as _FakeTag).name;
      if (name == 'A') throw Exception('boom');
      seen.add(name);
    });
    hub.tagController.add(_FakeTag('A'));
    hub.tagController.add(_FakeTag('B'));
    await pumpEventQueue();

    expect(seen, ['B']);
  });

  test('onError is forwarded stream errors', () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final errors = <Object>[];

    reader.startSession(
      onDiscovered: (_) {},
      onError: errors.add,
    );
    hub.tagController.addError(StateError('stream failed'));
    await pumpEventQueue();

    expect(errors, hasLength(1));
    expect(errors.first, isA<StateError>());
  });

  test('from: narrows the underlying tagStream to that source', () {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);

    reader.startSession(onDiscovered: (_) {}, from: const NfcSource.reader('R1'));

    expect(hub.tagStreamCalled, isTrue);
    expect(hub.lastFrom, equals(const CcidSourceFilter.reader('R1')));
  });

  test('no from: passes null to the underlying tagStream (all sources)', () {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);

    reader.startSession(onDiscovered: (_) {});

    expect(hub.tagStreamCalled, isTrue);
    expect(hub.lastFrom, isNull);
  });
}
