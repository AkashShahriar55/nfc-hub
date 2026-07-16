# NfcHubReader Simple Facade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small `nfc_manager`-style singleton facade (`NfcHubReader` +
`startSession`/`stopSession`) over the existing `NfcHub` stream API.

**Architecture:** Pure-Dart facade. `NfcHubReader.instance` owns one `NfcHub`
and turns `tagStream().listen()` into a session lifecycle. Friendly aliases
(`NfcTag`, `NfcConnectionState`, `NfcSource`) sit over the existing types.
No native changes; `NfcHub` and its stream API stay public and unchanged.

**Tech Stack:** Dart / Flutter, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-07-16-nfc-hub-reader-facade-design.md`

## Global Constraints

- Platform scope is Android-only; ignore iOS/macOS/Linux/Windows.
- Non-breaking: do NOT rename or remove any existing public type. `NfcHub`,
  `tagStream`, `readTag`, `connectionState`, `CcidConnectionState`,
  `CcidSourceFilter` all remain exported and unchanged.
- New public names (verbatim): `NfcHubReader`, `NfcTag` (typedef =
  `TagDriver`), `NfcConnectionState` (typedef = `CcidConnectionState`),
  `NfcSource` (with `.builtIn()` and `.reader(String name)`).
- `NfcHubReader.instance` is a SYNCHRONOUS singleton (no `await`).
- `isAvailable()` must be cheap and side-effect-free: it may call
  `getNfcState()` and `listReaders()` only, and must NOT subscribe to
  `connectionState()` or otherwise start the CCID poll loop / `connect()`
  (which can raise the USB permission dialog).
- `startSession` serializes `onDiscovered`: the (N+1)th call must not begin
  until the Nth call's returned Future completes.
- A throwing `onDiscovered` must NOT tear down the session.
- Pure-Dart, no hardware needed; test with fakes injected via the existing
  `@visibleForTesting` seams.

---

### Task 1: `NfcHub.isAvailable()` cheap availability primitive

**Files:**
- Modify: `lib/src/nfc_hub_base.dart` (add method to `NfcHub`)
- Test: `test/nfc_hub_available_test.dart` (create)

**Interfaces:**
- Consumes: existing `NfcHub({androidNfcManager})` test seam;
  `AndroidNfcManager.getNfcState() -> Future<NfcState>` where `NfcState` is
  `{ enabled, disabled, noHardware }` (in
  `lib/src/platform/android_nfc_manager.dart`); `NfcHub.listReaders() ->
  Future<List<String>>`; the global `NfcHubPlatform.instance` seam that
  `listReaders()` delegates to.
- Produces: `NfcHub.isAvailable() -> Future<bool>` — true when built-in NFC is
  enabled OR at least one CCID reader is listed. Used by Task 2's facade.

- [ ] **Step 1: Write the failing test**

Create `test/nfc_hub_available_test.dart`:

```dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/platform/android_nfc_manager.dart';

/// A manager whose getNfcState() returns a scripted value, and which records
/// whether getNfcState() was called. Everything else is inherited.
class _FakeManager extends AndroidNfcManager {
  _FakeManager()
      : super(
          methodChannel: const MethodChannel('nfc_hub'),
          eventChannel: const EventChannel('nfc_hub/events'),
        );

  NfcState nfcState = NfcState.disabled;

  @override
  Future<NfcState> getNfcState() async => nfcState;
}

/// A platform whose listReaders() returns a scripted list and which FAILS the
/// test if connect() is ever called (isAvailable must not start the poll loop).
class _FakePlatform extends NfcHubPlatform {
  List<String> readers = [];

  @override
  Future<List<String>> listReaders() async => List.of(readers);

  @override
  Future<CcidCard> connect(String reader) async =>
      throw StateError('connect() must not be called by isAvailable()');

  @override
  Future<String?> transceive(String reader, String capdu) async =>
      throw StateError('transceive() must not be called by isAvailable()');

  @override
  Future<void> disconnect(String reader) async {}
}

void main() {
  late _FakeManager manager;
  late _FakePlatform platform;

  setUp(() {
    manager = _FakeManager();
    platform = _FakePlatform();
    NfcHubPlatform.instance = platform;
  });

  NfcHub build() => NfcHub(androidNfcManager: manager);

  test('isAvailable() is true when built-in NFC is enabled', () async {
    manager.nfcState = NfcState.enabled;
    platform.readers = [];
    expect(await build().isAvailable(), isTrue);
  });

  test('isAvailable() is true when a reader is attached even if NFC is off',
      () async {
    manager.nfcState = NfcState.disabled;
    platform.readers = ['ACS ACR122U'];
    expect(await build().isAvailable(), isTrue);
  });

  test('isAvailable() is false when NFC is off and no reader is attached',
      () async {
    manager.nfcState = NfcState.disabled;
    platform.readers = [];
    expect(await build().isAvailable(), isFalse);
  });

  test('isAvailable() is false when there is no NFC hardware and no reader',
      () async {
    manager.nfcState = NfcState.noHardware;
    platform.readers = [];
    expect(await build().isAvailable(), isFalse);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/nfc_hub_available_test.dart`
Expected: FAIL — `NfcHub` has no method `isAvailable`.

- [ ] **Step 3: Implement `isAvailable()`**

In `lib/src/nfc_hub_base.dart`, add this import if not already present at the
top (it is needed for `NfcState`):

```dart
import 'platform/android_nfc_manager.dart';
```

(That import already exists in the file — verify; do not duplicate it.)

Add this method to the `NfcHub` class, right after `openNfcSettings()`:

```dart
  /// A cheap, side-effect-free snapshot of whether any source can read right
  /// now: true when the phone's NFC is enabled, or at least one CCID/PC-SC
  /// reader is attached. Deliberately does NOT start the CCID poll loop (so it
  /// never triggers the USB permission dialog) — it only reads the NFC state
  /// and lists readers. Any error resolving either source is treated as "that
  /// source is unavailable" rather than propagating.
  Future<bool> isAvailable() async {
    var nfcEnabled = false;
    try {
      nfcEnabled = (await _manager.getNfcState()) == NfcState.enabled;
    } catch (_) {
      nfcEnabled = false;
    }
    if (nfcEnabled) return true;
    try {
      return (await listReaders()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `flutter test test/nfc_hub_available_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/src/nfc_hub_base.dart test/nfc_hub_available_test.dart
git commit -m "feat: add cheap NfcHub.isAvailable() primitive"
```

---

### Task 2: `NfcHubReader` skeleton — singleton, aliases, `NfcSource`, passthroughs

**Files:**
- Create: `lib/src/nfc_hub_reader.dart`
- Modify: `lib/nfc_hub.dart` (add export)
- Test: `test/nfc_hub_reader_test.dart` (create)

**Interfaces:**
- Consumes: `NfcHub` (`isAvailable()`, `connectionState() ->
  Stream<CcidConnectionState>`, `openNfcSettings()`, `tagStream({from})`);
  `CcidSourceFilter` (`.builtInNfc()`, `.reader(String)`); `TagDriver`;
  `CcidConnectionState`.
- Produces: for Task 3 — the `NfcHubReader` class with a
  `@visibleForTesting NfcHubReader.forTesting(NfcHub hub)` constructor and a
  private `NfcHub get _hub`; the `NfcTag` typedef; the `NfcSource` type with
  `@visibleForTesting CcidSourceFilter toFilter()`.

- [ ] **Step 1: Write the failing test**

Create `test/nfc_hub_reader_test.dart`:

```dart
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';

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
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `flutter test test/nfc_hub_reader_test.dart`
Expected: FAIL — `NfcHubReader`, `NfcSource`, `NfcConnectionState` are undefined.

- [ ] **Step 3: Create the facade file**

Create `lib/src/nfc_hub_reader.dart`:

```dart
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'nfc_hub_api.dart';
import 'nfc_hub_base.dart';
import 'tag/tag_driver.dart';

/// Friendly alias for a discovered, already-identified tag. Identical to the
/// [TagDriver] the stream API emits — cast to a family subtype
/// ([MifareClassicTag], [Type2Tag], [FelicaTag], [IsoDepTag], [TypeBTag]) to
/// perform that family's reads.
typedef NfcTag = TagDriver;

/// Friendly alias over the connection-state type the stream API emits.
typedef NfcConnectionState = CcidConnectionState;

/// Which source a [NfcHubReader.startSession] listens to. Omit (pass null) for
/// all sources merged — the seamless default. A thin wrapper over
/// [CcidSourceFilter].
@immutable
class NfcSource {
  /// Only the phone's built-in NFC antenna.
  const NfcSource.builtIn()
      : _reader = null,
        _isBuiltIn = true;

  /// Only the named CCID/PC-SC reader, exactly as reported by
  /// [NfcHub.listReaders].
  const NfcSource.reader(String name)
      : _reader = name,
        _isBuiltIn = false;

  final String? _reader;
  final bool _isBuiltIn;

  /// Maps to the underlying stream-API filter.
  @visibleForTesting
  CcidSourceFilter toFilter() => _isBuiltIn
      ? const CcidSourceFilter.builtInNfc()
      : CcidSourceFilter.reader(_reader!);
}

/// A simple, `nfc_manager`-style singleton facade over [NfcHub].
///
/// The common case is three calls: grab [instance], [startSession] with an
/// `onDiscovered` callback, and [stopSession] when done. Every capability here
/// is a thin wrapper over the [NfcHub] stream API, which stays public for
/// callers that want streams, timeouts, or per-source filtering directly.
class NfcHubReader {
  /// The process-wide singleton entry point. Synchronous — no `await`.
  static final NfcHubReader instance = NfcHubReader._(NfcHub());

  NfcHubReader._(this._hub);

  /// Test seam: build a reader over an injected [NfcHub] (usually one wired to
  /// fakes). Production code uses [instance].
  @visibleForTesting
  factory NfcHubReader.forTesting(NfcHub hub) = NfcHubReader._;

  final NfcHub _hub;

  /// A cheap snapshot of whether any source can read right now. See
  /// [NfcHub.isAvailable].
  Future<bool> isAvailable() => _hub.isAvailable();

  /// Live, detailed connection state for building a status UI. Passthrough to
  /// [NfcHub.connectionState].
  Stream<NfcConnectionState> connectionState() => _hub.connectionState();

  /// Opens the system NFC settings screen so the user can enable NFC.
  Future<void> openNfcSettings() => _hub.openNfcSettings();
}
```

- [ ] **Step 4: Add the export**

In `lib/nfc_hub.dart`, add this line after the existing
`export 'src/nfc_hub_base.dart' ...;` line:

```dart
export 'src/nfc_hub_reader.dart'
    show NfcHubReader, NfcTag, NfcConnectionState, NfcSource;
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `flutter test test/nfc_hub_reader_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/src/nfc_hub_reader.dart lib/nfc_hub.dart test/nfc_hub_reader_test.dart
git commit -m "feat: add NfcHubReader facade skeleton (singleton, aliases, passthroughs)"
```

---

### Task 3: `startSession` / `stopSession` — session lifecycle, serialization, errors, filter

**Files:**
- Modify: `lib/src/nfc_hub_reader.dart` (add session methods + fields)
- Test: `test/nfc_hub_reader_test.dart` (add cases + a `_FakeTag`)

**Interfaces:**
- Consumes: the `_FakeNfcHub` from Task 2 (its `tagController` and `lastFrom`);
  `NfcHub.tagStream({from})`; `NfcSource.toFilter()`.
- Produces: `NfcHubReader.startSession({required FutureOr<void> Function(NfcTag)
  onDiscovered, void Function(Object)? onError, NfcSource? from}) -> void` and
  `NfcHubReader.stopSession() -> Future<void>`.

- [ ] **Step 1: Write the failing tests**

Add a minimal concrete tag near the top of `test/nfc_hub_reader_test.dart`
(after the imports, before `_FakeNfcHub`):

```dart
/// A minimal identified tag for session tests — carries a name for ordering
/// assertions. readTagInfo() is never called by these tests.
class _FakeTag extends TagDriver {
  _FakeTag(this.name);
  final String name;

  @override
  Future<TagInfo> readTagInfo() async =>
      throw UnimplementedError('not needed in these tests');
}
```

Note: `TagInfo` is already reachable via `package:nfc_hub/nfc_hub.dart` (already
imported at the top of the file). Add NO new imports for `_FakeTag` — an unused
import would fail `flutter analyze`.

Add these tests inside `main()`:

```dart
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
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `flutter test test/nfc_hub_reader_test.dart`
Expected: FAIL — `startSession`/`stopSession` are undefined.

- [ ] **Step 3: Implement the session methods**

In `lib/src/nfc_hub_reader.dart`, add these fields to `NfcHubReader` (after
`final NfcHub _hub;`):

```dart
  StreamSubscription<NfcTag>? _session;

  // Serializes onDiscovered: each call is chained onto the previous one's
  // Future so the (N+1)th never begins until the Nth completes. Reset on every
  // startSession so a new session starts with a clean chain.
  Future<void> _chain = Future<void>.value();
```

Add these methods to `NfcHubReader` (after `openNfcSettings()`):

```dart
  /// Starts auto-detecting tags from all sources (or the one named by [from]).
  ///
  /// [onDiscovered] is called once per tag as it arrives; if it returns a
  /// Future it is awaited before the next tag is delivered, so reads on one tag
  /// never overlap the next (important for the single-threaded CCID reader). A
  /// throwing/failing [onDiscovered] is isolated — it does not tear down the
  /// session. [onError], if given, receives stream errors. Calling
  /// startSession while a session is active first stops the previous one.
  void startSession({
    required FutureOr<void> Function(NfcTag tag) onDiscovered,
    void Function(Object error)? onError,
    NfcSource? from,
  }) {
    // Replace any active session. Cancel is fire-and-forget: the synchronous
    // prefix here (reading and nulling _session) completes before anything
    // else touches it, so no new subscription races the old one.
    final previous = _session;
    _session = null;
    if (previous != null) unawaited(previous.cancel());
    _chain = Future<void>.value();

    _session = _hub.tagStream(from: from?.toFilter()).listen(
      (tag) {
        _chain = _chain.then((_) async {
          try {
            await onDiscovered(tag);
          } catch (_) {
            // A throwing callback must not break the session or the chain.
          }
        });
      },
      onError: (Object error) => onError?.call(error),
    );
  }

  /// Stops the active session and releases its subscription. No-op if there is
  /// no active session. Safe to call repeatedly.
  Future<void> stopSession() async {
    final sub = _session;
    _session = null;
    await sub?.cancel();
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `flutter test test/nfc_hub_reader_test.dart`
Expected: PASS (all Task 2 + Task 3 cases).

- [ ] **Step 5: Run the full suite + analyzer**

Run: `flutter test`
Expected: PASS (all existing tests plus the new ones).

Run: `flutter analyze`
Expected: no new issues in `lib/` or `test/` (pre-existing example-app lints,
if any, are unrelated).

- [ ] **Step 6: Commit**

```bash
git add lib/src/nfc_hub_reader.dart test/nfc_hub_reader_test.dart
git commit -m "feat: add NfcHubReader startSession/stopSession with serialized onDiscovered"
```

---

## Self-Review

**1. Spec coverage:**
- Singleton + live availability → Task 2 (`instance`, synchronous) + Task 1
  (`isAvailable`) + Task 3 (session). ✓
- `onDiscovered` hands the identified driver as `NfcTag` → Task 2 (`typedef
  NfcTag = TagDriver`), Task 3 (`onDiscovered(NfcTag)`). ✓
- Keep both APIs public → nothing removed; `NfcHub` untouched except an added
  method. ✓
- Single owned `NfcHub` → Task 2 (`instance` builds one `NfcHub`). ✓
- One session at a time / replace → Task 3 (replace test + impl). ✓
- `onDiscovered` serialization → Task 3 (serialization test + `_chain`). ✓
- `isAvailable()` cheap, no poll loop → Task 1 (`connect` asserts never
  called). ✓
- Errors: `onError` optional, throwing callback isolated → Task 3. ✓
- `NfcConnectionState` / `NfcSource` friendly names → Task 2. ✓
- Testing list from spec → covered across Tasks 1–3. ✓

**2. Placeholder scan:** No TBD/TODO; every code step shows complete code. ✓

**3. Type consistency:** `NfcHubReader.forTesting`, `NfcTag`, `NfcSource.toFilter()`,
`_FakeNfcHub` (`tagController`, `lastFrom`, `availableReturn`,
`openNfcSettingsCalls`, `connectionStateCalls`, `tagStreamCalled`) are used
identically in every task that references them. `startSession`/`stopSession`
signatures match between the interface blocks and the implementation. ✓
