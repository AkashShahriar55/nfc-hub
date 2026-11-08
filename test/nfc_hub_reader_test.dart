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

/// A dedicated fake for the session-restart contract: mirrors, at the
/// facade+fake level, the two production contracts a restart must not
/// violate --
///  - Task 7: `NfcHub.tagStream()` returns the *same* broadcast stream
///    instance across calls (here: a single `_controller` field, always
///    returned), so a restart re-listens on the same pipeline rather than
///    spinning up a parallel one.
///  - Task 5: the underlying source delivers a given physical presentation
///    exactly once -- a fresh listener (0->1 transition, as happens when a
///    restart cancels the old subscription and attaches a new one) must NOT
///    re-emit a tag that's already been delivered while still seated.
///
/// [tap] simulates a physical tap (or an already-seated card becoming
/// visible to a freshly-attached listener): it records the tag as "seated"
/// and delivers it once, exactly like the real poll loop would on first
/// sighting -- but, per Task 5, never again for that same seating.
class _SeatedCardHub extends NfcHub {
  TagDriver? _seatedTag;
  bool _delivered = false;

  late final StreamController<TagDriver> _controller =
      StreamController<TagDriver>.broadcast(onListen: () {
    // A fresh listener attaching (e.g. after a session restart) is exactly
    // when a real source's poll loop would re-examine a still-seated card.
    // The exactly-once contract (Task 5) says: only deliver if this seating
    // hasn't been delivered yet.
    if (_seatedTag != null && !_delivered) {
      _delivered = true;
      _controller.add(_seatedTag!);
    }
  });

  @override
  Stream<TagDriver> tagStream({CcidSourceFilter? from}) => _controller.stream;

  /// Simulates a tap landing while a session may or may not already be
  /// listening.
  void tap(TagDriver tag) {
    _seatedTag = tag;
    _delivered = _controller.hasListener;
    if (_controller.hasListener) _controller.add(tag);
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

  test('startSession delivers each emitted tag to onDiscovered once', () async {
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

    reader.startSession(
        onDiscovered: (tag) => seen.add((tag as _FakeTag).name));
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

    reader.startSession(
        onDiscovered: (tag) => first.add((tag as _FakeTag).name));
    reader.startSession(
        onDiscovered: (tag) => second.add((tag as _FakeTag).name));
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

  test(
      'an onDiscovered that throws (e.g. TagLostException mid-read) reports '
      'the error to onError, and the session still delivers the next tag',
      () async {
    // Regression (final review, Finding 3): the serialization chain's catch
    // swallowed everything onDiscovered threw -- including TagLostException
    // when the tag left the field mid-read -- despite the documented promise
    // that onError sees per-tap failures.
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final errors = <Object>[];
    final seen = <String>[];

    reader.startSession(
      onDiscovered: (tag) async {
        final name = (tag as _FakeTag).name;
        if (name == 'A') {
          throw const TagLostException('tag left the field mid-read');
        }
        seen.add(name);
      },
      onError: errors.add,
    );
    hub.tagController.add(_FakeTag('A'));
    hub.tagController.add(_FakeTag('B'));
    await pumpEventQueue();

    expect(errors, hasLength(1));
    expect(errors.single, isA<TagLostException>());
    expect(seen, ['B'],
        reason: 'the session must survive the throwing callback');
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

  test(
      'startSession forwards a per-tap UnrecognizedTagException to onError, '
      'and the session keeps delivering afterwards', () async {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);
    final errors = <Object>[];
    final seen = <String>[];

    reader.startSession(
      onDiscovered: (tag) => seen.add((tag as _FakeTag).name),
      onError: errors.add,
    );
    hub.tagController
        .addError(const UnrecognizedTagException('unsupported tech'));
    await pumpEventQueue();

    expect(errors, hasLength(1));
    expect(errors.single, isA<UnrecognizedTagException>());

    // A per-tap error (Task 6) does not tear the session down -- a later,
    // successful tap must still be delivered.
    hub.tagController.add(_FakeTag('A'));
    await pumpEventQueue();
    expect(seen, ['A']);
  });

  test('restarting a session over a still-seated card does not re-deliver it',
      () async {
    // Operates at the facade+dedicated-fake level (see _SeatedCardHub doc):
    // NfcHubReader.forTesting wraps whatever fake NfcHub it's given, so this
    // cannot exercise the real CcidSource/AndroidSource state machine --
    // that lives in the ccid_source/android_source tests. This test pins
    // that the facade itself introduces no double-delivery across a
    // startSession replace, given a fake that mirrors the Task 5 (exactly
    // once) + Task 7 (shared stream) contracts those sources provide.
    final hub = _SeatedCardHub();
    final reader = NfcHubReader.forTesting(hub);
    final seen = <String>[];

    reader.startSession(
        onDiscovered: (tag) => seen.add((tag as _FakeTag).name));
    hub.tap(_FakeTag('A'));
    await pumpEventQueue();
    expect(seen, ['A']);

    // Restart over the still-seated card -- no new tap occurs.
    reader.startSession(
        onDiscovered: (tag) => seen.add((tag as _FakeTag).name));
    await pumpEventQueue();

    expect(seen, ['A']);
  });

  test('from: narrows the underlying tagStream to that source', () {
    final hub = _FakeNfcHub();
    final reader = NfcHubReader.forTesting(hub);

    reader.startSession(
        onDiscovered: (_) {}, from: const NfcSource.reader('R1'));

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
