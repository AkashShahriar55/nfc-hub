# NfcHubReader Simple Facade — Design

**Status:** Approved (2026-07-16)

**Goal:** Give `nfc_hub` a small, `nfc_manager`-style entry point —
`NfcHubReader.instance` + `startSession`/`stopSession` — so the common case
(auto-detect a tag, do something with it) is three obvious calls, while the
existing stream API (`NfcHub`) stays public for power users.

## Motivation

Today an app must construct `NfcHub()`, understand `Stream`/
`StreamSubscription`, call `tagStream().listen(...)`, and cancel the
subscription to stop. That is correct and composable but not beginner-simple.
The desired shape (from the user) is:

```dart
final reader = NfcHubReader.instance;
reader.startSession(onDiscovered: (NfcTag tag) async { /* ... */ });
reader.stopSession();
```

This facade is a thin wrapper over the already-working, already-hardware-
validated `NfcHub` stream API. It adds no new NFC capability; it repackages
the existing one behind friendlier names and a session lifecycle.

## Decisions (locked)

1. **Singleton + live availability check.** `NfcHubReader.instance` is a plain
   synchronous singleton (NOT awaited). Availability is a separate
   `isAvailable()` call, because the dual-source model (phone antenna +
   hot-pluggable USB readers) means "available" changes at runtime — a check
   frozen into `instance` would lie.
2. **`onDiscovered` hands you the already-identified driver, aliased as
   `NfcTag`.** This is the same object `tagStream` already emits. Callers cast
   to a family subtype (`MifareClassicTag`, `Type2Tag`, `FelicaTag`,
   `IsoDepTag`, `TypeBTag`) for family-specific reads. No new tag machinery.
3. **Keep both APIs public.** `NfcHubReader` is the documented default;
   `NfcHub` (streams, `connectionState`, per-source filters) stays public for
   power users and the example harness's live status view.

## Public surface (new)

New file: `lib/src/nfc_hub_reader.dart`, exported from `lib/nfc_hub.dart`.

```dart
/// Friendly alias for a discovered, already-identified tag. Identical to the
/// [TagDriver] the stream API emits — cast to a family subtype for its reads.
typedef NfcTag = TagDriver;

/// Friendly alias over the connection-state type the stream API emits.
typedef NfcConnectionState = CcidConnectionState;

/// Which source(s) a session listens to. Omit (null) for all sources merged
/// — the seamless default. Thin wrapper over [CcidSourceFilter].
@immutable
class NfcSource {
  const NfcSource.builtIn();            // phone antenna only
  const NfcSource.reader(String name);  // one named CCID/PC-SC reader
  // internal: converts to the matching CcidSourceFilter
}

class NfcHubReader {
  /// The process-wide singleton. Synchronous — no await.
  static final NfcHubReader instance = NfcHubReader._();

  /// Cheap snapshot: is at least one source ready to read right now?
  /// True when the phone's NFC is enabled OR at least one CCID reader is
  /// attached. Does NOT start the CCID poll loop (so it never triggers the
  /// USB permission prompt) — it only calls getNfcState + listReaders.
  Future<bool> isAvailable();

  /// Live, detailed connection state for building a status UI. Passthrough to
  /// the underlying [NfcHub.connectionState].
  Stream<NfcConnectionState> connectionState();

  /// Opens the system NFC settings screen so the user can enable NFC.
  Future<void> openNfcSettings();

  /// Starts auto-detecting tags from all sources (or the one named by [from]).
  /// [onDiscovered] is called once per tag as it arrives; if it returns a
  /// Future it is awaited before the next discovery is delivered, so reads on
  /// one tag never overlap the next (important for the single-threaded CCID
  /// reader). [onError] receives stream errors if supplied. Calling
  /// startSession while a session is active first stops the previous one.
  void startSession({
    required FutureOr<void> Function(NfcTag tag) onDiscovered,
    void Function(Object error)? onError,
    NfcSource? from,
  });

  /// Stops the active session and releases its subscription. No-op if there is
  /// no active session. Safe to call repeatedly.
  Future<void> stopSession();
}
```

## Behavior details

- **Single owned `NfcHub`.** The singleton constructs exactly one `NfcHub`
  internally and reuses it. This avoids the "two NfcHub instances" class of bug
  seen earlier in the example app.
- **One session at a time.** `startSession` replaces any active session
  (stops the old subscription, starts a new one). This is forgiving rather
  than throwing — a caller that starts twice gets the newer session.
- **`onDiscovered` serialization.** The session subscription's handler awaits
  the (possibly async) `onDiscovered` callback before processing the next
  event. On the CCID path, overlapping reads against one reader are unsafe;
  serializing here keeps the simple API safe by default.
- **`isAvailable()` is cheap and side-effect-free.** It must NOT subscribe to
  `connectionState()`/the poll loop (which would connect to readers and can
  raise the USB permission dialog). It resolves built-in NFC via the NFC
  state and readers via `listReaders()` only. Since `NfcHub` does not today
  expose a cheap NFC-state primitive publicly, this facade adds one to
  `NfcHub` — `Future<bool> isAvailable()` — implemented as
  `getNfcState() == enabled || (await listReaders()).isNotEmpty`, using the
  manager/platform `NfcHub` already holds. The facade delegates to it, so the
  whole thing stays behind `NfcHub`'s existing fake-injectable constructor and
  needs no hardware to test.
- **Errors.** If `onError` is omitted, stream errors are swallowed at the
  session level (they are already logged inside the sources). If supplied,
  they are forwarded. `onDiscovered` throwing does not tear down the session.

## What this does NOT change

- No change to `NfcHub`, `tagStream`, `readTag`, `connectionState`,
  `CcidSource`, `AndroidNfcSource`, the transports, or detection.
- No change to the native (Kotlin) layer.
- The wedged-CCID-reader hardware issue (`3b00` ATR) is unrelated and out of
  scope here; this facade is a pure-Dart repackaging and is unit-testable
  without hardware.

## Testing

Pure-Dart, no hardware needed — the facade wraps `NfcHub`, which already has a
fake-injectable constructor. Tests (a new `test/nfc_hub_reader_test.dart`)
cover, with a fake `NfcHub`/sources:

- `startSession` delivers each emitted tag to `onDiscovered` exactly once.
- `onDiscovered` returning a Future is awaited before the next delivery
  (serialization) — assert ordering with a gated completer.
- `stopSession` cancels the subscription (no further callbacks after stop);
  `stopSession` with no active session is a no-op.
- `startSession` twice replaces the session (old callback stops receiving).
- `from:` narrows to the selected source (`NfcSource.builtIn` /
  `NfcSource.reader`).
- `isAvailable()` returns true when NFC enabled or a reader is listed, false
  when neither — and does not start the poll loop (assert `connect` is never
  called on the fake platform).
- `onDiscovered` throwing does not stop subsequent deliveries.

## Naming note (non-breaking)

`CcidConnectionState` and `CcidSourceFilter` carry a `Ccid` prefix that predates
built-in-NFC support and now reads as misleading. This spec introduces
`NfcConnectionState` (typedef) and `NfcSource` (wrapper) as the friendly names
the facade uses. The original names remain exported and unchanged; a full
rename is deliberately out of scope for this facade.
