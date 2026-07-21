# NFC Hub Reliability Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the three field-reported reliability failures — missed reads (external CCID and built-in NFC), duplicate reads, and missing tag info — and bring the package to publishable Flutter-package quality.

**Architecture:** The library is layered: Kotlin plugin (`NfcHubPlugin` + `Ccid` for USB CCID, `NfcReaderModeController` for built-in NFC) → Dart platform wrappers (`MethodChannelNfcHub`, `AndroidNfcManager`) → tag sources (`CcidSource` poll loop, `AndroidNfcSource`) → merge layer (`nfc_hub_api.dart`) → drivers (`tag/*.dart`) → facades (`NfcHub`, `NfcHubReader`). The refactor keeps this layering and fixes correctness inside it: complete every pending platform `Result` (a hung `Result` freezes the CCID poll loop forever), move built-in-NFC I/O off the main thread, make each physical tag presentation emit exactly once process-wide, stop the liveness probe from corrupting in-flight reads, and fix tag-identification ordering.

**Tech Stack:** Flutter plugin (Dart 3.5+, Kotlin), `fake_async` + `flutter_test` for the Dart layers. Kotlin has no unit-test harness in this repo — Kotlin tasks are verified by compiling the example app (`cd example && flutter build apk --debug`) plus targeted manual hardware checks listed per task.

## Global Constraints

- Android-only scope: never add iOS/macOS/Linux/Windows work; leave `lib/src/platform/pcsc.dart` untouched (dead on Android, ignored per project scope).
- Public API of `NfcHub` / `NfcHubReader` may gain members and error codes but must not remove or rename existing ones, except where a task explicitly says so.
- Every Dart change is TDD: failing test first, in the existing test style (`FakeAsync`, scriptable fakes like `_FakePlatform` in `test/source/ccid_source_test.dart`).
- Run `flutter test` and `flutter analyze` (both must be clean) before every commit.
- Kotlin verification command (all Kotlin tasks): `cd example && flutter build apk --debug` — must exit 0.
- Commit after every task with a `fix:`/`feat:`/`refactor:`/`docs:` conventional message.

---

## Findings this plan fixes (review summary)

Symptom → root cause map (file references are pre-refactor):

**"Sometimes cannot read — external reader":**
- F1. A denied/ignored USB-permission dialog never completes the pending `Result` (`NfcHubPlugin.kt:115-117` logs and returns). The Dart `await _platform.connect()` inside `CcidSource._tryConnect` then never resolves, `_ticking` never clears (`ccid_source.dart:247`), and the poll loop is **permanently frozen** until app restart. Same hang if the reader detaches while a permission request is pending.
- F2. A fast re-tap of the same card is invisible: the poll state machine only emits on an empty→occupied edge; remove+replace within one 500 ms poll interval keeps the probe succeeding, so no new emission (`ccid_source.dart:369-385`).
- F3. The 500 ms liveness probe (`FFCA000000`) interleaves with in-flight app reads on the same card. A probe APDU landing between two frames of a chained command (DESFire GetVersion `60`/`AF`/`AF`, MIFARE load-key→auth→read) aborts the card-side transaction → failed/partial reads.
- F4. On permission denial (once F1 is fixed), the loop would retry `connect` every tick → permission-dialog spam.

**"Sometimes cannot read — internal NFC":**
- F5. `nfcTransceive`/`nfcMifareAuth`/`nfcMifareReadBlock` run blocking tag I/O **on the platform main thread** (`NfcHubPlugin.kt:242-278`), unlike the CCID path which was already moved off-thread. Slow tags jank the UI, delay discovery-event delivery, and get killed by the NFC presence check mid-read (surfacing as spurious TAG_LOST / missed reads).
- F6. Reader mode is never re-armed when the user turns NFC on mid-session: `ACTION_ADAPTER_STATE_CHANGED` only forwards the state event (`NfcHubPlugin.kt:64-73`); nothing re-calls `startReaderMode()`.
- F7. Unidentifiable/unrecognized taps are silently logged and dropped (`android_source.dart:121-141`); the app gets no signal at all, which reads as "it didn't scan".
- F8. `NfcReaderModeController.tags`/`connected` maps grow forever; stale `Tag` handles and open tech connections are never pruned when a new tag arrives.

**"Sometimes it reads double":**
- F9. `CcidSource.tags()`/`taggedTags()` replay every occupied reader's driver to **every new subscription** (`ccid_source.dart:178-191`). Every `tagStream()` / `readTag()` / `startSession()` call creates a fresh subscription, so a card left seated is re-delivered on each — widget rebuilds and session restarts produce duplicate reads.
- F10. `NfcHub.tagStream()` builds a **new** merged broadcast controller per call (`nfc_hub_api.dart:115-159`); two widgets listening independently each trigger their own replay and their own source subscriptions.
- F11. Android reader mode can re-deliver `onTagDiscovered` for the same physical tap (field flicker / tag re-enumeration); there is no UID/time debounce anywhere in the pipeline.

**"Sometimes few info is not there":**
- F12. `_identifyByProbing` classifies as ISO-DEP when `SELECT` returns *any* ≥4-hex-char response — including reader-level failure SWs (`63xx`/`6Fxx`) — and this check runs **before** the authoritative MIFARE SAK poll (`detection.dart:187-191`). MIFARE cards behind degenerate ATRs get misidentified → wrong driver → wrong/missing info.
- F13. The PN532 identity poll (`pollTypeA`) is attempted once, best-effort; one transient failure degrades uid/atqa/sak to empty for the whole session (`ccid_backend.dart:36-61`).
- F14. `_CcidIsoDepTransport.historicalBytes` returns the **whole ATR** (`ccid_backend.dart:219`) instead of the ATR's historical bytes.

**Package quality:**
- F15. `pubspec.yaml` declares ios/macos/linux/windows plugin classes with no real implementations behind them; package is Android-only in practice.
- F16. `AndroidNfcManager.tagLosses` is dead API — the Kotlin side never emits a `tagLost` event.

---

### Task 1: Complete every pending USB-permission `Result` (Kotlin)

**Files:**
- Modify: `android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt`

**Interfaces:**
- Consumes: existing `Reader` data class, `usbReceiver`, `connect(name, result)`.
- Produces: new method-channel error codes `CCID_PERMISSION_DENIED`, `CCID_PERMISSION_PENDING`, `CCID_READER_DETACHED` — Task 5's Dart code matches on `CCID_PERMISSION_DENIED` by string.

There is no Kotlin test harness; this task is compile + manual verification.

- [ ] **Step 1: Fail the pending Result on permission denial**

In `usbReceiver`'s `ACTION_USB_PERMISSION` branch, replace the denial else-arm (`Log.d(TAG, "permission denied for device $device")`) with:

```kotlin
} else {
    Log.d(TAG, "permission denied for device $device")
    val deniedName = intent.getStringExtra("name")
    val reader = deniedName?.let { readers[it] }
    val pending = reader?.result
    if (reader != null && pending != null) {
        readers[reader.name] = reader.copy(result = null)
        pending.error(
            "CCID_PERMISSION_DENIED",
            "USB permission denied for reader ${reader.name}",
            null
        )
    }
}
```

- [ ] **Step 2: Reject a second connect while a permission request is pending**

In `connect(name, result)`, immediately after the `reader == null` check, add:

```kotlin
if (reader.result != null) {
    // A permission request is already in flight for this reader; completing
    // a second one would orphan the first (a Result that never completes
    // hangs the Dart-side await forever -- see CcidSource's poll loop).
    result.error(
        "CCID_PERMISSION_PENDING",
        "A USB permission request is already pending for $name",
        null
    )
    return
}
```

- [ ] **Step 3: Fail the pending Result when the reader detaches**

In `usbReceiver`'s `ACTION_USB_DEVICE_DETACHED` branch, before `readers.entries.removeIf { ... }`, add:

```kotlin
readers.values
    .filter { it.deviceName == detachedDevice.deviceName }
    .forEach { r ->
        r.result?.error(
            "CCID_READER_DETACHED",
            "Reader ${r.name} detached while a request was pending",
            null
        )
    }
```

- [ ] **Step 4: Build**

Run: `cd example && flutter build apk --debug`
Expected: exit 0.

- [ ] **Step 5: Manual hardware check (note in commit message if skipped)**

Plug in a reader, deny the permission dialog: the app must keep polling (dialog handling per Task 5), not freeze. Detach the reader while the dialog is up: no crash, no hang.

- [ ] **Step 6: Commit**

```bash
git add android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt
git commit -m "fix: complete pending USB-permission Result on denial/detach/duplicate so the CCID poll loop can never hang"
```

---

### Task 2: Move built-in-NFC tag I/O off the main thread (Kotlin)

**Files:**
- Modify: `android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt`
- Modify: `android/src/main/kotlin/com/cheqplease/nfchub/NfcReaderModeController.kt`

**Interfaces:**
- Consumes: existing `nfcController.transceive/mifareAuthenticate/mifareReadBlock`, `mainHandler`.
- Produces: same method-channel surface (`nfcTransceive`, `nfcMifareAuth`, `nfcMifareReadBlock`) with unchanged codes (`TAG_LOST`, `MIFARE_AUTH_FAILED`) plus a new generic `NFC_IO_ERROR`; Dart side needs no change.

- [ ] **Step 1: Add a dedicated serial executor for NFC I/O**

In `NfcHubPlugin`, next to `ccidExecutor`, add:

```kotlin
// Built-in-NFC tag I/O (connect/transceive/auth/readBlock) is blocking RF
// I/O, exactly like the CCID USB path -- run it on its own serial executor
// so it neither janks the main thread nor queues behind slow USB work.
private val nfcExecutor: ExecutorService = Executors.newSingleThreadExecutor()
```

And in `onDetachedFromEngine`, next to `ccidExecutor.shutdown()`, add `nfcExecutor.shutdown()`.

- [ ] **Step 2: Wrap the three NFC handlers**

Replace the `"nfcTransceive"`, `"nfcMifareAuth"`, and `"nfcMifareReadBlock"` branches of `onMethodCall` with:

```kotlin
"nfcTransceive" -> {
    val handle = call.argument<Int>("handle")!!
    val tech = call.argument<String>("tech")!!
    val data = call.argument<ByteArray>("data")!!
    nfcExecutor.execute {
        try {
            val resp = nfcController.transceive(handle, tech, data)
            mainHandler.post { result.success(resp) }
        } catch (e: TagGoneException) {
            mainHandler.post { result.error("TAG_LOST", e.message, null) }
        } catch (e: Throwable) {
            // EVERY path must complete `result` (see the CCID transceive
            // comment above) -- an orphaned Result hangs the Dart await.
            mainHandler.post { result.error("NFC_IO_ERROR", e.message, null) }
        }
    }
}

"nfcMifareAuth" -> {
    val handle = call.argument<Int>("handle")!!
    val sector = call.argument<Int>("sector")!!
    val keyA = call.argument<Boolean>("keyA")!!
    val key = call.argument<ByteArray>("key")!!
    nfcExecutor.execute {
        try {
            val ok = nfcController.mifareAuthenticate(handle, sector, keyA, key)
            mainHandler.post {
                if (ok) result.success(null)
                else result.error(
                    "MIFARE_AUTH_FAILED",
                    "MIFARE sector authentication rejected", null
                )
            }
        } catch (e: TagGoneException) {
            mainHandler.post { result.error("TAG_LOST", e.message, null) }
        } catch (e: Throwable) {
            mainHandler.post { result.error("NFC_IO_ERROR", e.message, null) }
        }
    }
}

"nfcMifareReadBlock" -> {
    val handle = call.argument<Int>("handle")!!
    val block = call.argument<Int>("block")!!
    nfcExecutor.execute {
        try {
            val resp = nfcController.mifareReadBlock(handle, block)
            mainHandler.post { result.success(resp) }
        } catch (e: TagGoneException) {
            mainHandler.post { result.error("TAG_LOST", e.message, null) }
        } catch (e: Throwable) {
            mainHandler.post { result.error("NFC_IO_ERROR", e.message, null) }
        }
    }
}
```

- [ ] **Step 3: Make `NfcReaderModeController`'s mutable maps thread-safe**

The controller is now touched from three threads: the NFC-dispatch binder thread (`onTagDiscovered`), the main thread (`startReaderMode`/`stopReaderMode`), and `nfcExecutor`. `tags` is already `synchronized`; extend the same discipline to `connected`. Replace the `connect*` helpers and `close`/`closeAll` with:

```kotlin
private fun <T : Any> connectTech(h: Int, get: () -> T?, connect: (T) -> Unit): T {
    synchronized(connected) {
        @Suppress("UNCHECKED_CAST")
        (connected[h] as? T)?.let { return it }
    }
    val tech = get() ?: throw TagGoneException("Tech unavailable for handle $h")
    connect(tech)
    synchronized(connected) { connected[h] = tech }
    return tech
}

private fun connectNfcA(h: Int, tag: Tag): NfcA =
    connectTech(h, { NfcA.get(tag) }, { it.connect() })
private fun connectNfcB(h: Int, tag: Tag): NfcB =
    connectTech(h, { NfcB.get(tag) }, { it.connect() })
private fun connectNfcF(h: Int, tag: Tag): NfcF =
    connectTech(h, { NfcF.get(tag) }, { it.connect() })
private fun connectIsoDep(h: Int, tag: Tag): IsoDep =
    connectTech(h, { IsoDep.get(tag) }, { it.connect() })
private fun connectMifare(h: Int, tag: Tag): MifareClassic =
    connectTech(h, { MifareClassic.get(tag) }, { it.connect() })

private fun close(handle: Int) {
    synchronized(tags) { tags.remove(handle) }
    val tech = synchronized(connected) { connected.remove(handle) }
    (tech as? android.nfc.tech.TagTechnology)?.let {
        try { it.close() } catch (_: Exception) {}
    }
}
```

(`closeAll` is unchanged — it already delegates to `close`.)

- [ ] **Step 4: Build**

Run: `cd example && flutter build apk --debug`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt android/src/main/kotlin/com/cheqplease/nfchub/NfcReaderModeController.kt
git commit -m "fix: run built-in-NFC tag I/O on a background executor, mirroring the CCID off-thread fix"
```

---

### Task 3: Re-arm reader mode when NFC turns on; prune stale tag handles (Kotlin)

**Files:**
- Modify: `android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt`
- Modify: `android/src/main/kotlin/com/cheqplease/nfchub/NfcReaderModeController.kt`

**Interfaces:**
- Consumes: `nfcReaderModeRequested`, `nfcStateReceiver`, `onTagDiscovered`.
- Produces: no wire changes. Behavior: reader mode auto-recovers when the adapter is enabled mid-session; the handle map is bounded (a new discovery supersedes all prior handles).

- [ ] **Step 1: Re-apply reader mode on adapter-enabled**

In `nfcStateReceiver.onReceive`, before building the event map, add:

```kotlin
val adapterState = intent.getIntExtra(
    NfcAdapter.EXTRA_ADAPTER_STATE, NfcAdapter.STATE_OFF
)
// The app asked for reader mode while NFC was off (or the user toggled it
// off and on): enableReaderMode was a no-op then, so re-apply it the
// moment the adapter comes up -- otherwise built-in NFC stays dead until
// the app restarts its session.
if (adapterState == NfcAdapter.STATE_ON && nfcReaderModeRequested) {
    nfcController.startReaderMode()
}
```

- [ ] **Step 2: Supersede stale handles on new discovery**

In `NfcReaderModeController.onTagDiscovered`, make the first line:

```kotlin
override fun onTagDiscovered(tag: Tag) {
    // Android invalidates previous Tag objects once a new tag is enumerated
    // ("Tag out of date"); holding them only leaks memory and open tech
    // connections. One discovery at a time is reader mode's model, so a new
    // tag supersedes ALL previous handles.
    closeAll()
    val handle = synchronized(tags) { val h = nextHandle++; tags[h] = tag; h }
    ...
```

(rest of the method unchanged).

- [ ] **Step 3: Broaden discovery flags**

In `startReaderMode`, add `NfcAdapter.FLAG_READER_NFC_V` to `flags` (Type 5/ISO15693 tags are then at least *discovered*; Task 6 surfaces unknown-tech taps as errors instead of silence).

- [ ] **Step 4: Build**

Run: `cd example && flutter build apk --debug`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt android/src/main/kotlin/com/cheqplease/nfchub/NfcReaderModeController.kt
git commit -m "fix: re-arm reader mode when NFC is enabled mid-session; bound the tag-handle map; discover NfcV"
```

---

### Task 4: Serialize per-card APDUs and suppress the liveness probe during active reads (Dart)

**Files:**
- Modify: `lib/src/nfc_hub_base.dart` (CcidCard)
- Modify: `lib/src/source/ccid_source.dart`
- Test: `test/source/ccid_source_test.dart` (extend)

**Interfaces:**
- Consumes: `NfcHubPlatform.transceive`, existing `CcidSource` internals.
- Produces:
  - `CcidCard.transceive(String capdu) → Future<String?>` — unchanged signature, now serialized per card (no two APDUs of the same card in flight at once) and records activity.
  - `CcidCard.lastActivity → DateTime?` — time of last completed transceive (null before the first).
  - `CcidSource` constructor gains `DateTime Function() now` parameter (default `DateTime.now`) for testability.
  - Behavior: the poll tick skips the `FFCA000000` probe for a reader whose card has completed a transceive within the last `pollInterval` (recent traffic already proves presence, and probing mid-conversation corrupts chained commands).

- [ ] **Step 1: Write the failing tests**

Append to `test/source/ccid_source_test.dart` (inside the existing `group`):

```dart
test(
    'the liveness probe is SKIPPED while the app is actively reading the '
    'card (recent CcidCard.transceive traffic proves presence)', () {
  FakeAsync().run((async) {
    final platform = _FakePlatform()
      ..readers = ['reader-1']
      ..cardsPresent.add('reader-1');
    NfcHubPlatform.instance = platform;
    addTearDown(() => NfcHubPlatform.instance = null);

    var fakeNow = DateTime(2026, 1, 1);
    final source =
        CcidSource(platform, now: () => fakeNow);
    addTearDown(source.dispose);

    final drivers = <TagDriver>[];
    source.tags().listen(drivers.add);
    async.elapse(const Duration(milliseconds: 500));
    fakeNow = fakeNow.add(const Duration(milliseconds: 500));
    expect(drivers, hasLength(1));

    // The identify path + UID baseline ran; note the probe count now.
    final probesAfterConnect = platform.transceiveLog.length;

    // Simulate the app reading the card continuously: a driver transceive
    // completes just before each tick.
    final card = (drivers.single as Type2Tag);
    for (var i = 0; i < 4; i++) {
      card.readUid(); // issues a transceive through the same CcidCard
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 500));
      fakeNow = fakeNow.add(const Duration(milliseconds: 500));
    }

    // Probes issued by the POLL LOOP during those 4 ticks: zero. All
    // transceives logged were the driver's own readUid calls.
    final pollProbes = platform.transceiveLog.length -
        probesAfterConnect -
        4; // the 4 readUid calls
    expect(pollProbes, 0);
  });
});

test('CcidCard serializes concurrent transceives (no interleaving)', () async {
  final platform = _SlowPlatform();
  NfcHubPlatform.instance = platform;
  addTearDown(() => NfcHubPlatform.instance = null);

  final card = CcidCard('reader-1');
  final first = card.transceive('AA');
  final second = card.transceive('BB');
  platform.release('AA');
  platform.release('BB');
  await Future.wait([first, second]);
  // BB must not have STARTED until AA completed.
  expect(platform.order, ['start:AA', 'end:AA', 'start:BB', 'end:BB']);
});
```

And the supporting fake at the bottom of the file:

```dart
class _SlowPlatform extends NfcHubPlatform {
  final order = <String>[];
  final _gates = <String, Completer<void>>{};

  void release(String capdu) => _gates[capdu]?.complete();

  @override
  Future<String?> transceive(String reader, String capdu) async {
    order.add('start:$capdu');
    final gate = _gates[capdu] = Completer<void>();
    await gate.future;
    order.add('end:$capdu');
    return '9000';
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/source/ccid_source_test.dart`
Expected: FAIL — `now` is not a `CcidSource` parameter; interleaving order is `start:AA, start:BB, ...`.

- [ ] **Step 3: Implement `CcidCard` serialization + activity tracking**

In `lib/src/nfc_hub_base.dart`, replace `CcidCard.transceive` and add fields:

```dart
class CcidCard {
  final String reader;
  final Uint8List? atr;

  CcidCard(this.reader, {this.atr});

  /// Completion time of the most recent [transceive] (success OR failure).
  /// Null until the first transceive completes. CcidSource uses this to skip
  /// its liveness probe while the app is actively talking to the card.
  DateTime? lastActivity;

  // Serializes transceives per card: an APDU never starts until the
  // previous one completes. Probing and multi-step driver flows share one
  // card; without this, a poll-loop probe can land between two frames of a
  // chained command (DESFire GetVersion, MIFARE load-key/auth) and abort it.
  Future<void> _chain = Future<void>.value();

  Future<String?> transceive(String capdu) {
    final completer = Completer<String?>();
    _chain = _chain.then((_) async {
      try {
        completer.complete(
            await NfcHubPlatform.instance.transceive(reader, capdu));
      } catch (e, st) {
        completer.completeError(e, st);
      } finally {
        lastActivity = DateTime.now();
      }
    });
    return completer.future;
  }

  Future<void> disconnect() {
    return NfcHubPlatform.instance.disconnect(reader);
  }
}
```

- [ ] **Step 4: Route the probe through the card and gate it on activity**

In `lib/src/source/ccid_source.dart`:

1. Constructor: `CcidSource(this._platform, {this.pollInterval = const Duration(milliseconds: 500), DateTime Function()? now}) : _now = now ?? DateTime.now;` with field `final DateTime Function() _now;`.
2. Add `final Map<String, CcidCard> _occupiedCards = {};` next to `_occupiedDrivers`; populate it in `_tryConnect` (`_occupiedCards[reader] = card;` right after the status flip) and clear it everywhere `_occupiedDrivers` is cleared (`_markCardGone`, the vanished-reader branch, `dispose`).
3. Capture the UID baseline through the card, not the raw platform: in `_tryConnect` replace `await _platform.transceive(reader, _probeApdu)` with `await card.transceive(_probeApdu)`.
4. Rewrite `_probeStillPresent`:

```dart
Future<bool> _probeStillPresent(String reader) async {
  final card = _occupiedCards[reader];
  // Recent app traffic already proves the card is present -- and injecting
  // a probe APDU mid-conversation can abort a chained command. Skip.
  final last = card?.lastActivity;
  if (last != null && _now().difference(last) < pollInterval) return true;

  final String? response;
  try {
    response = card == null
        ? await _platform.transceive(reader, _probeApdu)
        : await card.transceive(_probeApdu);
  } catch (_) {
    await _markCardGone(reader);
    return false;
  }
  final baseline = _occupiedUid[reader];
  if (baseline != null && baseline.isNotEmpty && response != baseline) {
    await _markCardGone(reader);
    return false;
  }
  return true;
}
```

Note: `CcidCard.lastActivity` uses real `DateTime.now()` while the source compares with injected `_now` — in tests, keep the fake clock aligned with elapsed fake time (as the Step 1 test does) so the comparison is exact.

- [ ] **Step 5: Handle permission-denied without dialog spam**

Still in `ccid_source.dart`, add a denied-set and use it in `_tryConnect` / `_pollOnce`:

```dart
/// Readers whose USB permission the user denied. connect() is NOT retried
/// for these (each retry re-shows the OS dialog); the reader must detach
/// and re-attach (it then leaves _status and this set) to be retried.
final Set<String> _permissionDenied = {};
```

In `_pollOnce`'s vanished-reader loop add `_permissionDenied.remove(reader);`. In the per-reader loop, change the empty-branch to:

```dart
if (status == _ReaderStatus.empty) {
  if (_permissionDenied.contains(reader)) continue;
  if (await _tryConnect(reader)) changed = true;
}
```

And in `_tryConnect`'s catch:

```dart
} on PlatformException catch (e) {
  if (e.code == 'CCID_PERMISSION_DENIED') _permissionDenied.add(reader);
  return false;
} catch (_) {
  return false;
}
```

(add `import 'package:flutter/services.dart';` for `PlatformException`).

- [ ] **Step 6: Run the full suite**

Run: `flutter test`
Expected: PASS (new tests plus all pre-existing ones — the existing probe-counting tests may need their expected transceive counts revisited if they assumed a probe on every tick even with recent traffic; fix only test *arithmetic*, never the assertion's intent).

- [ ] **Step 7: Commit**

```bash
git add lib/src/nfc_hub_base.dart lib/src/source/ccid_source.dart test/source/ccid_source_test.dart
git commit -m "fix: serialize per-card APDUs and suppress liveness probe during active reads; stop permission-dialog spam"
```

---

### Task 5: Exactly-once delivery for seated CCID cards (kill replay double-reads)

**Files:**
- Modify: `lib/src/source/ccid_source.dart`
- Test: `test/source/ccid_source_test.dart` (extend)

**Interfaces:**
- Consumes: `_occupiedDrivers`, the `Stream.multi` construction in `tags()`/`taggedTags()`.
- Produces: unchanged signatures. New behavior contract (document in the class doc): **each card presentation is delivered exactly once process-wide** — to whichever listener exists first. A driver identified while nobody listens to `tags()`/`taggedTags()` is held and replayed to the *first* subsequent subscriber only; once delivered anywhere it is never replayed again.

- [ ] **Step 1: Write the failing test**

```dart
test(
    'a seated card is delivered exactly ONCE across resubscriptions: '
    'a second listener (or a re-listen) does not replay it', () {
  FakeAsync().run((async) {
    final platform = _FakePlatform()
      ..readers = ['reader-1']
      ..cardsPresent.add('reader-1');
    final source = CcidSource(platform);
    addTearDown(source.dispose);

    final first = <TagDriver>[];
    final sub1 = source.tags().listen(first.add);
    async.elapse(const Duration(milliseconds: 500));
    expect(first, hasLength(1));

    // Simulates a widget rebuild / session restart: cancel and re-listen.
    sub1.cancel();
    final second = <TagDriver>[];
    source.tags().listen(second.add);
    async.elapse(const Duration(milliseconds: 1500));
    expect(second, isEmpty,
        reason: 'the same presentation must not be re-delivered');
  });
});

test(
    'a driver identified while only readerStates is listened is replayed '
    'to the FIRST tags() subscriber (and only that one)', () {
  FakeAsync().run((async) {
    final platform = _FakePlatform()
      ..readers = ['reader-1']
      ..cardsPresent.add('reader-1');
    final source = CcidSource(platform);
    addTearDown(source.dispose);

    source.readerStates().listen((_) {}); // starts the loop, holds driver
    async.elapse(const Duration(milliseconds: 500));

    final a = <TagDriver>[];
    final b = <TagDriver>[];
    source.tags().listen(a.add);
    source.tags().listen(b.add);
    async.elapse(const Duration(milliseconds: 500));
    expect(a.length + b.length, 1,
        reason: 'held driver replays to exactly one listener');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/source/ccid_source_test.dart`
Expected: FAIL — today both re-listens and second listeners get replays.

- [ ] **Step 3: Implement a delivered-flag on held drivers**

In `ccid_source.dart`, change `_occupiedDrivers` to hold a small record and gate replay on it:

```dart
class _HeldDriver {
  _HeldDriver(this.driver);
  final TagDriver driver;
  bool delivered = false;
}
```

- `final Map<String, _HeldDriver> _occupiedDrivers = {};`
- In `_tryConnect`, after identification:

```dart
final held = _HeldDriver(driver);
_occupiedDrivers[reader] = held;
final tagsController = _tagsController;
final taggedController = _taggedTagsController;
if ((tagsController?.hasListener ?? false) ||
    (taggedController?.hasListener ?? false)) {
  held.delivered = true;
  tagsController?.add(driver);
  taggedController?.add(ReaderTaggedDriver(reader, driver));
}
```

- In `tags()`'s `Stream.multi` callback, replace the replay loop with:

```dart
for (final held in _occupiedDrivers.values) {
  if (!held.delivered) {
    held.delivered = true;
    controller.add(held.driver);
  }
}
```

and equivalently in `taggedTags()` (`controller.add(ReaderTaggedDriver(entry.key, held.driver))`).
- Update the places that read `_occupiedDrivers.remove(reader)` / `.clear()` — the value type changed, call sites stay the same shape.
- Update the `tags()`/`taggedTags()`/class docs: replace the "replays to each NEW subscription" contract with the exactly-once contract stated in this task's Interfaces block.

- [ ] **Step 4: Run the full suite**

Run: `flutter test`
Expected: PASS. Pre-existing tests that asserted replay-to-every-listener must be updated to the new exactly-once contract (they encode the old, buggy behavior).

- [ ] **Step 5: Commit**

```bash
git add lib/src/source/ccid_source.dart test/source/ccid_source_test.dart
git commit -m "fix: deliver each seated CCID card exactly once process-wide, ending replay double-reads"
```

---

### Task 6: Debounce Android rediscoveries; surface unreadable taps as errors

**Files:**
- Modify: `lib/src/source/android_source.dart`
- Test: `test/source/android_source_test.dart` (extend)

**Interfaces:**
- Consumes: `AndroidNfcManager.discoveries`, `hintFromTechList`, `identifyFromBackend`.
- Produces:
  - `AndroidNfcSource` constructor gains `{Duration rediscoverDebounce = const Duration(milliseconds: 1000), DateTime Function()? now}`.
  - Behavior: a discovery with the same UID as the previous one, arriving within `rediscoverDebounce`, is dropped (field-flicker re-enumeration). Different UID, or same UID after the window, passes.
  - Behavior: an unrecognized tech list, and a failed identification, are emitted as **stream errors** (`UnrecognizedTagException` / the original error) instead of being silently logged — `NfcHubReader.startSession`'s `onError` then sees them.

- [ ] **Step 1: Write the failing tests**

In `test/source/android_source_test.dart`, using its existing fake-manager pattern (a `StreamController<NfcTagDiscovery>` behind a fake `AndroidNfcManager` — reuse the file's existing fake class), add:

```dart
test('same-UID rediscovery within the debounce window is dropped', () async {
  var fakeNow = DateTime(2026, 1, 1);
  final source = AndroidNfcSource(manager, now: () => fakeNow);
  final tags = <TagDriver>[];
  source.tags().listen(tags.add);
  await pumpEventQueue();

  discoveryController.add(_type2Discovery(handle: 1));
  await pumpEventQueue();
  fakeNow = fakeNow.add(const Duration(milliseconds: 300));
  discoveryController.add(_type2Discovery(handle: 2)); // same uid, flicker
  await pumpEventQueue();
  expect(tags, hasLength(1));

  fakeNow = fakeNow.add(const Duration(milliseconds: 1200));
  discoveryController.add(_type2Discovery(handle: 3)); // deliberate re-tap
  await pumpEventQueue();
  expect(tags, hasLength(2));
});

test('an unrecognized tech list surfaces as a stream error, not silence',
    () async {
  final source = AndroidNfcSource(manager);
  final errors = <Object>[];
  source.tags().listen((_) {}, onError: errors.add);
  await pumpEventQueue();

  discoveryController.add(NfcTagDiscovery(
    handle: 9,
    techList: const ['android.nfc.tech.NfcV'],
    uid: Uint8List.fromList([1, 2, 3, 4]),
  ));
  await pumpEventQueue();
  expect(errors, hasLength(1));
  expect(errors.single, isA<UnrecognizedTagException>());
});
```

(`_type2Discovery` is a small local helper returning an `NfcTagDiscovery` with `techList: ['android.nfc.tech.NfcA']` and a fixed 7-byte uid; write it next to the tests.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/source/android_source_test.dart`
Expected: FAIL — no `now` parameter; duplicate passes through; unknown tech is silent.

- [ ] **Step 3: Implement debounce + error surfacing**

In `android_source.dart`:

```dart
class AndroidNfcSource implements TagSource {
  AndroidNfcSource(
    this._manager, {
    this.rediscoverDebounce = const Duration(milliseconds: 1000),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final AndroidNfcManager _manager;
  final Duration rediscoverDebounce;
  final DateTime Function() _now;

  String? _lastUidHex;
  DateTime? _lastDiscoveryAt;
  ...
```

And rewrite `_onDiscovery`:

```dart
Future<void> _onDiscovery(NfcTagDiscovery discovery) async {
  final uidHex = discovery.uid
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join();
  final at = _now();
  final lastAt = _lastDiscoveryAt;
  // Reader mode can re-enumerate the SAME physical tag on a field flicker
  // and call onTagDiscovered again -- to an app that is one tap read
  // twice. A same-UID discovery inside the debounce window is that
  // re-enumeration, not a new tap.
  if (uidHex == _lastUidHex &&
      lastAt != null &&
      at.difference(lastAt) < rediscoverDebounce) {
    _lastDiscoveryAt = at;
    return;
  }
  _lastUidHex = uidHex;
  _lastDiscoveryAt = at;

  final hint = hintFromTechList(discovery.techList);
  if (hint == null) {
    // Surface as an error: the user DID tap something; silence here is
    // indistinguishable from a broken reader.
    _controller?.addError(UnrecognizedTagException(
        'Tag with unsupported tech list: ${discovery.techList}'));
    return;
  }
  try {
    final backend = AndroidTransportBackend(_manager, discovery);
    final driver = await identifyFromBackend(backend, hint: hint);
    _controller?.add(driver);
  } catch (error, stackTrace) {
    _controller?.addError(error, stackTrace);
  }
}
```

Add `import '../tag/tag_driver.dart';` if not already imported (for `UnrecognizedTagException`), and update the class doc's "silent dropped tap" paragraph to describe the new error contract.

- [ ] **Step 4: Run the full suite**

Run: `flutter test`
Expected: PASS. Pre-existing tests asserting silent drops must be flipped to expect errors (they encode the old behavior).

- [ ] **Step 5: Commit**

```bash
git add lib/src/source/android_source.dart test/source/android_source_test.dart
git commit -m "fix: debounce same-tag rediscoveries; surface unreadable taps as stream errors"
```

---

### Task 7: One shared merged stream per filter in `NfcHub`

**Files:**
- Modify: `lib/src/nfc_hub_base.dart`
- Test: `test/nfc_hub_test.dart` (extend)

**Interfaces:**
- Consumes: `mergeTagStreams`, `CcidSourceFilter` (it already implements `==`/`hashCode`).
- Produces: `NfcHub.tagStream({CcidSourceFilter? from})` — unchanged signature; now returns the **same** broadcast stream instance for equal `from` values, so N listeners share one pipeline (one set of source subscriptions) instead of N parallel pipelines.

- [ ] **Step 1: Write the failing test**

In `test/nfc_hub_test.dart` (following its existing fake-source injection pattern):

```dart
test('tagStream() returns one shared stream per filter', () {
  final hub = NfcHub(
    androidNfcManager: manager,
    androidNfcSource: androidSource,
    ccidSource: ccidSource,
  );
  expect(identical(hub.tagStream(), hub.tagStream()), isTrue);
  expect(
    identical(
      hub.tagStream(from: const CcidSourceFilter.builtInNfc()),
      hub.tagStream(from: const CcidSourceFilter.builtInNfc()),
    ),
    isTrue,
  );
  expect(
    identical(hub.tagStream(),
        hub.tagStream(from: const CcidSourceFilter.builtInNfc())),
    isFalse,
  );
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/nfc_hub_test.dart`
Expected: FAIL — each call builds a fresh controller today.

- [ ] **Step 3: Implement the cache**

In `NfcHub`:

```dart
final Map<CcidSourceFilter?, Stream<TagDriver>> _tagStreams = {};

Stream<TagDriver> tagStream({CcidSourceFilter? from}) {
  return _tagStreams[from] ??= mergeTagStreams(
    androidSource: _nfcSource,
    ccidSource: _readerSource,
    filter: from,
  );
}
```

(The merged stream is a broadcast controller with onListen/onCancel — it starts and stops its sources with its own listener count, so caching it is safe across listen/cancel cycles.)

- [ ] **Step 4: Run the full suite**

Run: `flutter test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/src/nfc_hub_base.dart test/nfc_hub_test.dart
git commit -m "fix: share one merged tag stream per filter so parallel listeners cannot duplicate pipelines"
```

---

### Task 8: Fix CCID tag identification (probe order, SELECT check, historical bytes, PN532 retry)

**Files:**
- Modify: `lib/src/tag/detection.dart`
- Modify: `lib/src/transport/ccid_backend.dart`
- Test: `test/tag/detection_test.dart`, `test/transport/ccid_backend_test.dart` (extend)

**Interfaces:**
- Consumes: `stripAndCheckSw`, `pollTypeA`, existing probing chain.
- Produces:
  - `_identifyByProbing` runs the MIFARE SAK poll **before** the ISO-DEP SELECT probe, and the SELECT probe only classifies ISO-DEP when the SW proves an ISO7816 interpreter answered (`9000`, `61xx`, `6Cxx`, `6A82`, `6A86`, `6D00`, `6E00` — NOT reader-failure `63xx`/`6Fxx`).
  - `_CcidIsoDepTransport.historicalBytes` returns the ATR's historical bytes (T0 low nibble = count, bytes precede the trailing TCK), not the whole ATR.
  - `pollTypeA` results in `mifareClassic()`/`isoDep()` are retried once before degrading to empty identity.

- [ ] **Step 1: Write the failing tests**

In `test/tag/detection_test.dart` (its fake card pattern scripts `transceive` by capdu):

```dart
test(
    'a MIFARE Classic card whose reader answers SELECT with a failure SW '
    'is identified as MIFARE (SAK), not misclassified as ISO-DEP', () async {
  final card = _FakeCard(
    atr: null,
    responses: {
      'FFCA000000': '0102030449', // answers Get UID
      'FFB0000304': '6300',       // CC read fails
      '00A4040000': '6300',       // reader-level failure SW -- NOT iso-dep proof
      // PN532 InListPassiveTarget: Type A target, ATQA 0004, SAK 08 (Classic 1K)
      'FF00000004D44A0100':
          'D54B010100040804AABBCCDD9000',
    },
  );
  final driver = await identifyTag(CcidCard('r', atr: null)
      /* wire the fake through NfcHubPlatform override per this file's pattern */);
  expect(driver, isA<MifareClassicTag>());
});

test('SELECT answered with a card-level ISO7816 SW still means ISO-DEP',
    () async {
  // 6A82 = file not found -- only an ISO7816 interpreter says that.
  // Script: Get UID ok, CC read fails, SELECT -> 6A82.
  // Expect: IsoDepTag.
});
```

In `test/transport/ccid_backend_test.dart`:

```dart
test('historicalBytes parses the ATR (T0 nibble), not the whole ATR', () {
  // NTAG-style ATR: 3B 8F 80 01 | 80 4F 0C A0 00 00 03 06 03 00 03 00 00 00 00 | 68
  // T0=0x8F -> K=15 historical bytes; TCK is the final byte.
  final atr = Uint8List.fromList([
    0x3B, 0x8F, 0x80, 0x01,
    0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x03,
    0x00, 0x00, 0x00, 0x00,
    0x68,
  ]);
  expect(
    historicalBytesFromAtr(atr),
    Uint8List.fromList([
      0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x03,
      0x00, 0x00, 0x00, 0x00,
    ]),
  );
  expect(historicalBytesFromAtr(null), isNull);
  expect(historicalBytesFromAtr(Uint8List.fromList([0x3B, 0x80])), isNull);
});

test('pollTypeA is retried once before degrading to empty identity', () async {
  // Fake card: first InListPassiveTarget escape throws, second succeeds.
  // Expect: mifareClassic() transport carries the real uid/atqa/sak.
});
```

(Flesh these out against the file's existing fake-card helper; the scripted hex for `InListPassiveTarget` follows `pn532.dart`'s format: `D5 4B NbTg Tg ATQA(2) SAK UIDlen UID… + 9000`.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/tag/detection_test.dart test/transport/ccid_backend_test.dart`
Expected: FAIL — misclassified as `IsoDepTag`; `historicalBytesFromAtr` undefined; single poll attempt.

- [ ] **Step 3: Reorder probing and tighten the SELECT check**

In `detection.dart`'s `_identifyByProbing`, move the whole MIFARE-poll block (the `try { final mifareTransport = ... }` block) to run **before** the SELECT probe, and replace the SELECT classification with:

```dart
final selectResponse = await _tryTransceive(card, '00A4040000');
log.add('SELECT -> ${selectResponse ?? 'no response'}');
if (selectResponse != null && _isIsoDepSw(selectResponse)) {
  return IsoDepTag(await backend.isoDep());
}
```

with the helper (top-level, private, in `detection.dart`):

```dart
/// True when [responseHex]'s status word could only have been produced by
/// an ISO7816 command interpreter on the card: success (9000), data
/// available (61xx/6Cxx), or card-level "understood but can't" errors
/// (6A82 file not found, 6A86 wrong P1P2, 6D00 INS not supported, 6E00 CLA
/// not supported). Reader-level failure SWs (63xx, 6Fxx) prove nothing --
/// the ACR122U answers 6300 for a non-ISO-DEP card it couldn't talk to.
bool _isIsoDepSw(String responseHex) {
  if (responseHex.length < 4) return false;
  final sw = responseHex.substring(responseHex.length - 4).toUpperCase();
  return sw == '9000' ||
      sw.startsWith('61') ||
      sw.startsWith('6C') ||
      sw == '6A82' ||
      sw == '6A86' ||
      sw == '6D00' ||
      sw == '6E00';
}
```

- [ ] **Step 4: Fix historical bytes + PN532 retry in `ccid_backend.dart`**

Add (public, exported for tests):

```dart
/// The historical bytes of [atr], per ISO7816-3: T0's low nibble is the
/// count K; they are the K bytes immediately before the trailing TCK.
/// Null when [atr] is null, malformed, or carries none.
Uint8List? historicalBytesFromAtr(Uint8List? atr) {
  if (atr == null || atr.length < 3) return null;
  final k = atr[1] & 0x0F;
  if (k == 0 || atr.length < 2 + k + 1) return null;
  return Uint8List.sublistView(atr, atr.length - 1 - k, atr.length - 1);
}
```

Change `_CcidIsoDepTransport.historicalBytes` to `historicalBytesFromAtr(card.atr)`.

Add the retry helper and use it in both `mifareClassic()` and `isoDep()`:

```dart
/// One retry: a single transient escape-command failure (a probe racing
/// the card settling into the field) must not cost the whole session its
/// uid/atqa/sak identity.
Future<PassiveTargetTypeA?> _pollTypeAResilient(CcidCard card) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final target = await pollTypeA(card);
      if (target != null) return target;
    } catch (_) {}
  }
  return null;
}
```

- [ ] **Step 5: Run the full suite**

Run: `flutter test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/src/tag/detection.dart lib/src/transport/ccid_backend.dart test/tag/detection_test.dart test/transport/ccid_backend_test.dart
git commit -m "fix: MIFARE-before-SELECT probing, strict ISO-DEP SW check, real historical bytes, PN532 identity retry"
```

---

### Task 9: `NfcHubReader` session ergonomics — error forwarding verified end-to-end

**Files:**
- Modify: `lib/src/nfc_hub_reader.dart` (doc updates only, if behavior already correct)
- Test: `test/nfc_hub_reader_test.dart` (extend)

**Interfaces:**
- Consumes: Task 6's error-emitting sources, Task 7's shared streams.
- Produces: verified contract — `startSession(onError:)` receives `UnrecognizedTagException` and identification errors; a session restart over a still-seated card does **not** re-deliver it (Task 5's contract, asserted at the facade level).

- [ ] **Step 1: Write the failing/contract tests**

In `test/nfc_hub_reader_test.dart` (its existing pattern injects a fake `NfcHub` via `NfcHubReader.forTesting`):

```dart
test('startSession forwards source errors to onError', () async {
  // fake hub whose tagStream emits an UnrecognizedTagException error
  final errors = <Object>[];
  reader.startSession(onDiscovered: (_) {}, onError: errors.add);
  streamController.addError(
      const UnrecognizedTagException('unsupported tech'));
  await pumpEventQueue();
  expect(errors, hasLength(1));
});

test('restarting a session does not re-deliver the seated card', () async {
  // With Tasks 5+7 in place, the shared stream emits each presentation
  // once. Assert at facade level: deliver a tag, restart the session,
  // pump -- onDiscovered fired exactly once total.
});
```

- [ ] **Step 2: Run, implement any gap, re-run**

Run: `flutter test test/nfc_hub_reader_test.dart`
The forwarding already exists (`onError: (Object error) => onError?.call(error)`); these tests pin it. If the restart test fails, the bug is in Task 5/7 code — fix there, not here.

- [ ] **Step 3: Update docs**

In `nfc_hub_reader.dart`, update `startSession`'s doc: errors now include per-tap failures (unreadable tag, identification failure) — recommend always supplying `onError` and showing a "couldn't read tag, try again" UI.

- [ ] **Step 4: Commit**

```bash
git add lib/src/nfc_hub_reader.dart test/nfc_hub_reader_test.dart
git commit -m "test: pin session error-forwarding and no-redelivery-on-restart contracts"
```

---

### Task 10: Package quality — Android-only declaration, dead API, docs

**Files:**
- Modify: `pubspec.yaml`
- Modify: `lib/src/platform/android_nfc_manager.dart` (remove `tagLosses`)
- Modify: `README.md`, `CHANGELOG.md`
- Test: full suite + analyzer + pana

- [ ] **Step 1: Declare Android-only**

In `pubspec.yaml`, replace the `flutter.plugin.platforms` block with:

```yaml
flutter:
  plugin:
    platforms:
      android:
        package: com.cheqplease.nfchub
        pluginClass: NfcHubPlugin
```

(The ios/macos/linux/windows entries point at plugin classes that don't deliver the library's functionality; declaring them misleads pub.dev scoring and consumers. `lib/src/platform/pcsc.dart` and the `dart_pcsc` dependency stay untouched per project scope — they are simply no longer advertised.)

- [ ] **Step 2: Remove the dead `tagLosses` stream**

In `android_nfc_manager.dart`, delete `_tagLossesController`, the `tagLosses` getter, the `'tagLost'` cases in `_onEvent`, its line in `_onEventError`, and its `close()` in `dispose()`. The Kotlin side never emits `tagLost`; tag loss is (and remains) surfaced per-operation via `TAG_LOST` platform errors → `TagLostException`. Fix any test referencing it.

- [ ] **Step 3: Bump version + changelog**

`pubspec.yaml`: `version: 0.7.0`. Prepend to `CHANGELOG.md`:

```markdown
## 0.7.0

Reliability release.

- **Fixed** the CCID poll loop freezing permanently when a USB permission
  dialog was denied, ignored, or the reader detached mid-request.
- **Fixed** duplicate tag deliveries: a seated card now emits exactly once
  per presentation (no replay on resubscribe/session restart); same-tag
  rediscoveries on the built-in antenna are debounced.
- **Fixed** built-in-NFC tag I/O blocking the main thread (jank, presence-
  check drops mid-read).
- **Fixed** reader mode not re-arming when NFC is enabled mid-session.
- **Fixed** MIFARE Classic cards being misidentified as ISO-DEP during
  capability probing; ISO-DEP `historicalBytes` now returns the ATR's
  historical bytes rather than the whole ATR.
- The CCID liveness probe no longer interleaves with in-flight reads
  (previously corrupted chained commands like DESFire GetVersion).
- Unreadable taps now surface on `onError` / as stream errors instead of
  being silently dropped.
- **Breaking:** package now declares Android support only.
- **Breaking:** removed the never-functional `AndroidNfcManager.tagLosses`.
```

- [ ] **Step 4: README pass**

Update README: quickstart via `NfcHubReader.instance.startSession(onDiscovered: ..., onError: ...)`, the exactly-once delivery contract, the error contract, Android-only support badge/statement, and a troubleshooting section (USB permission denial requires re-attach; NFC-off states surface via `connectionState()`).

- [ ] **Step 5: Verify**

Run: `flutter test && flutter analyze && dart pub publish --dry-run`
Expected: tests pass, analyzer clean, dry-run reports no errors (warnings about version are fine).

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml lib/src/platform/android_nfc_manager.dart README.md CHANGELOG.md test
git commit -m "chore: 0.7.0 — Android-only platform declaration, remove dead tagLosses API, reliability changelog"
```

---

### Task 11: Hardware validation matrix (manual, gated release step)

**Files:**
- Create: `docs/hardware-validation.md`

No code. Run the example app on a physical device with an ACR122U and record results in a table committed to the repo. This is the acceptance gate for the release — the symptoms being fixed are hardware-timing bugs that pure-Dart tests cannot fully prove.

- [ ] **Step 1: Create the checklist document**

```markdown
# Hardware validation — 0.7.0 reliability release

Device: ____  Reader: ACR122U  Date: ____

| # | Scenario | Expected | Pass |
|---|----------|----------|------|
| 1 | Deny USB permission, then re-attach reader and grant | Poll loop keeps running; reader works after re-attach | |
| 2 | Seat card, leave it, restart session (navigate away/back) | Card is NOT re-delivered | |
| 3 | Seat card, lift, immediately re-seat (<0.5 s) | Second presentation IS delivered (within ~2 poll ticks) | |
| 4 | Tap phone antenna 10× with NTAG213 | Exactly 10 deliveries, no doubles, no misses | |
| 5 | Tap MIFARE Classic 1K on ACR122U 10× | Identified as MIFARE every time; uid/atqa/sak populated every time | |
| 6 | Tap DESFire on ACR122U | desfireVersion populated (GetVersion chain uninterrupted by probe) | |
| 7 | Long MIFARE full-dump read on built-in NFC | No UI jank; no spurious TAG_LOST with tag held still | |
| 8 | Turn NFC off then on while session active | Built-in reads resume without app restart | |
| 9 | Tap an unsupported tag (e.g. ISO15693) | onError fires with UnrecognizedTagException | |
| 10 | Unplug reader mid-read | No crash; readerStates drops the reader; re-plug works | |
```

- [ ] **Step 2: Execute and record; fix regressions found before release.**

- [ ] **Step 3: Commit**

```bash
git add docs/hardware-validation.md
git commit -m "docs: hardware validation matrix for the reliability release"
```

---

## Self-Review Notes

- Coverage check: F1→Task 1; F2→Task 11 scenario 3 validates existing edge behavior post-Task 4 (faster detection because probes are skipped only under traffic; the empty→occupied edge still needs a probe failure — if scenario 3 fails on hardware, lower `pollInterval` to 250 ms as a tuning follow-up); F3→Task 4; F4→Task 4 step 5; F5→Task 2; F6→Task 3; F7→Task 6; F8→Task 3; F9→Task 5; F10→Task 7; F11→Task 6; F12/F13/F14→Task 8; F15/F16→Task 10.
- Type consistency: `_HeldDriver` (Task 5) is internal to `ccid_source.dart`; `historicalBytesFromAtr` (Task 8) is top-level public in `ccid_backend.dart` and imported by its test; `CcidSource`'s and `AndroidNfcSource`'s injected clocks are both named `now` in the constructor and `_now` as fields.
- Ordering: Tasks 1–3 (Kotlin) are independent of 4–9 (Dart) and can be done in any order, but Task 9's restart test depends on Tasks 5 and 7; Task 10 depends on everything; Task 11 is last.
