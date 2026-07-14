# Android Built-in NFC & Unified Tag Stream Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second tag source — the device's built-in NFC antenna — behind the same `TagDriver` API the CCID readers already use, and expose a unified `tagStream()` / `readTag()` / `connectionState()` / `openNfcSettings()` so an app never has to know whether a tag came from the phone or a USB reader.

**Architecture:** Plan 3 of 4. Plan 2 decoupled the five drivers from `CcidCard` onto typed transport interfaces implemented by `CcidTransportBackend`. This plan adds `AndroidTransportBackend` implementing the *same* interfaces over `android.nfc.tech.*`, generalizes `identifyTag` to work over either backend, and builds the source-merging layer on top. **Keep the Kotlin as thin as physically possible** — it does only what Dart cannot (reader-mode, tag handles, lazy connect, the crypto1 auth). Every decision, every piece of parsing, every state machine lives in Dart, where it can be tested against fakes. The Kotlin native side cannot be unit-tested in this environment — it is compile-checked and reviewed, and settled only by the on-device hardware gate.

**Tech Stack:** Flutter 3.38.3 / Dart SDK `>=3.5.0 <4.0.0`, Kotlin (`android.nfc.*`, min SDK 26), `flutter_test`. No new dependencies.

## Global Constraints

Every task's requirements implicitly include this section.

- **Seamlessness is the whole point.** The default path — `await for (final tag in hub.tagStream())` yielding a `TagDriver` — must never require the app to branch on source. `readNdef()`, `readSector()`, `readWithoutEncryption()` must behave identically whether the tag came from the antenna or a reader. Anything source-aware (`CcidSourceFilter`, `connectionState()`, `openNfcSettings()`) is strictly opt-in.
- **Lazy connect, hold until the tag leaves the field.** On Android, identity fields (UID, ATQA/SAK, PMm/IDm, historical bytes) are read from the `Tag` object with NO `connect()`. `connect()` happens on the first actual read and the connection is held until the tag departs. A read after the tag is gone throws `TagLostException` — the same failure the CCID path gives when a card is pulled off the reader.
- **The transport interfaces are frozen.** Plan 2 shipped `Type2Transport`, `MifareClassicTransport`, `NfcFTransport`, `IsoDepTransport`, `NfcBTransport`. Do NOT change their signatures — the CCID backend depends on them and is hardware-validated. The Android backend implements them as-is.
- **The FeliCa frame contract (learned the hard way in Plan 2):** the frame passed INTO `NfcFTransport.transceive` is UNPREFIXED; the implementation prepends the length byte; the frame it returns is length-prefixed (driver offsets start at index 10). Android's `NfcF.transceive` requires the length byte, so `AndroidNfcFTransport.transceive` MUST prepend `frame.length + 1` exactly as the CCID backend does.
- **The DESFire no-status-word trap:** `IsoDepTransport.transceive` returns the raw response INCLUDING any trailing status word. DESFire native mode has NO status word — byte 0 is its own continuation status. Do NOT strip anything. `IsoDep.transceive` on Android already returns the full response; pass it through untouched.
- **Zero behavior change to the CCID path.** `NfcHub().listReaders()`, `.connect()`, `identifyTag(CcidCard)` keep working exactly as in 0.5.0. This plan is additive plus one internal refactor (generalizing `identifyTag`).
- **Test baseline: 116 passing, 0 failing.** Every Dart task ADDS tests. The count may only go up. The Kotlin task adds none (it is not unit-testable) but must not drop the count.
- `flutter analyze` clean (2 pre-existing info-lints in `example/test/mrt_transaction_test.dart` are expected).
- **`flutter pub publish --dry-run` must stay at 0 warnings, archive under 1 MB** (do not disturb `.pubignore`; pub uses it instead of `.gitignore`).
- Do NOT touch `LICENSE`.
- **Scope: library only.** The example-app rebuild is Plan 4. Do not rewrite `example/lib/main.dart` here beyond what's needed to keep it compiling.

Spec: `docs/superpowers/specs/2026-07-14-unified-nfc-transport-design.md` (read Layers 1-4 and the Android backend section).

## Roadmap

- **Plan 1 (done):** rename to `nfc_hub`, restructure `lib/`.
- **Plan 2 (done):** transport interfaces + CCID backend; drivers decoupled from `CcidCard`. Released 0.5.0.
- **Plan 3 (this document):** Android built-in-NFC backend + unified `tagStream()`/`readTag()`/`connectionState()`/`openNfcSettings()` + CCID auto-detect poll loop.
- **Plan 4 (next):** rebuild the example app as a real test harness against the unified API.

## What is testable here, and what is not

Be honest about this — it determines where the risk lives.

- **Testable in CI (fake the channels):** the `identifyTag` generalization, the Android channel *protocol* (Dart side, against a fake `MethodChannel`/`EventChannel`), the five Android transports (against a fake `AndroidNfcManager`), tag identification from a tech hint, the source-merge stream, the CCID poll-loop state machine, `connectionState()` transitions. **The bulk of this plan is testable.**
- **NOT testable in CI (compile + review + hardware gate only):** the Kotlin (`NfcHubPlugin` reader-mode, tag-handle map, lazy connect, `android.nfc.tech.*` calls). This is Task 5. It gets complete verbatim code in the plan because the implementer cannot discover it by running tests, plus a `./gradlew compileDebugKotlin` gate and a mandatory hardware-gate note.

## File Structure

New Dart:
```
lib/src/transport/backend.dart            # abstract TransportBackend + TagTechHint
lib/src/transport/android_backend.dart    # AndroidTransportBackend + the 5 android transports
lib/src/platform/android_nfc_manager.dart # thin Dart wrapper over the nfc_hub method+event channels
lib/src/source/tag_source.dart            # TagSource abstraction + TagSourceEvent
lib/src/source/android_source.dart        # AndroidNfcSource (reader mode -> TagDriver stream)
lib/src/source/ccid_source.dart           # CcidSource (poll loop -> TagDriver stream)
lib/src/nfc_hub_api.dart                  # tagStream / readTag / connectionState / openNfcSettings + state types
```
New Kotlin:
```
android/src/main/kotlin/com/cheqplease/nfchub/NfcReaderModeController.kt  # reader-mode + tag-handle map + tech calls
```
Changed:
```
lib/src/tag/detection.dart      # generalize identifyTag over TransportBackend + hint
lib/src/transport/ccid_backend.dart  # `implements TransportBackend`
lib/src/nfc_hub_base.dart       # NfcHub gains the new API (delegates to nfc_hub_api.dart)
lib/nfc_hub.dart                # export the new public types
android/.../NfcHubPlugin.kt     # wire in NfcReaderModeController + new method/event channel handlers
android/src/main/AndroidManifest.xml  # NFC permission + feature
```
New tests mirror each new Dart file under `test/`.

---

### Task 1: Generalize `identifyTag` over an abstract backend + tech hint

Today `identifyTag(CcidCard)` builds a `CcidTransportBackend` and probes. The Android source has no `CcidCard` and doesn't need to probe — `Tag.getTechList()` tells it the family outright. Introduce an abstract `TransportBackend` both backends implement, and split `identifyTag` into a backend-driven core (with an optional hint that short-circuits probing) plus the existing `identifyTag(CcidCard)` compatibility wrapper.

**Files:**
- Create: `lib/src/transport/backend.dart`
- Create: `test/transport/backend_identify_test.dart`
- Modify: `lib/src/transport/ccid_backend.dart` (add `implements TransportBackend`)
- Modify: `lib/src/tag/detection.dart` (extract the core, add hint short-circuit, keep `identifyTag(CcidCard)`)
- Modify: `lib/nfc_hub.dart` (export `TransportBackend`, `TagTechHint`, `identifyFromBackend`)

**Interfaces:**
- Consumes: the five transport interfaces + `CcidTransportBackend` from Plan 2.
- Produces:
  - `abstract class TransportBackend` with `Type2Transport type2()`, `Future<MifareClassicTransport> mifareClassic()`, `NfcFTransport nfcF()`, `Future<IsoDepTransport> isoDep()`, `Future<NfcBTransport?> nfcB()`. (These match `CcidTransportBackend`'s existing methods exactly, so it implements them for free.)
  - `enum TagTechHint { type2, mifareClassic, felica, isoDep, typeB }`
  - `Future<TagDriver> identifyFromBackend(TransportBackend backend, {Uint8List? atr, TagTechHint? hint})` — with a non-null hint it builds that family's driver directly (no ATR match, no probing); with a null hint it runs today's exact ATR-match → probing chain.
  - `Future<TagDriver> identifyTag(CcidCard card)` — unchanged signature, now a thin wrapper: `identifyFromBackend(CcidTransportBackend(card), atr: card.atr)`.

- [ ] **Step 1: Confirm baseline green**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test 2>&1 | tail -1
```
Expected: `All tests passed!`, 116.

- [ ] **Step 2: Write the failing test for hint-based identification**

`test/transport/backend_identify_test.dart`. A fake backend returns fake transports; assert that `identifyFromBackend` with each hint returns the matching driver WITHOUT touching the ATR/probe path.

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';

class _FakeType2Transport implements Type2Transport {
  @override
  Future<Uint8List> readUid() async => Uint8List.fromList([4, 1, 2, 3]);
  @override
  Future<Uint8List> readCapabilityContainer() async =>
      Uint8List.fromList([0xE1, 0x10, 0x6D, 0x00]);
  @override
  Future<Uint8List> readPages(int startPage) async => Uint8List(16);
  @override
  Future<Uint8List?> getVersion() async => null;
}

class _FakeMifareClassicTransport implements MifareClassicTransport {
  @override
  Uint8List get uid => Uint8List.fromList([4, 1, 2, 3]);
  @override
  Uint8List get atqa => Uint8List.fromList([0, 4]);
  @override
  int get sak => 0x08;
  @override
  Future<void> authenticate(int s, MifareKeyType t, Uint8List k) async {}
  @override
  Future<Uint8List> readBlock(int b) async => Uint8List(16);
}

// (Fakes for NfcF / IsoDep / NfcB analogous — implement each interface member
//  with a minimal valid return. Full bodies belong in this test file.)

class _FakeBackend implements TransportBackend {
  @override
  Type2Transport type2() => _FakeType2Transport();
  @override
  Future<MifareClassicTransport> mifareClassic() async =>
      _FakeMifareClassicTransport();
  @override
  NfcFTransport nfcF() => throw UnimplementedError();
  @override
  Future<IsoDepTransport> isoDep() async => throw UnimplementedError();
  @override
  Future<NfcBTransport?> nfcB() async => throw UnimplementedError();
}

void main() {
  test('hint type2 -> Type2Tag, no probing', () async {
    final driver = await identifyFromBackend(_FakeBackend(),
        hint: TagTechHint.type2);
    expect(driver, isA<Type2Tag>());
  });

  test('hint mifareClassic -> MifareClassicTag', () async {
    final driver = await identifyFromBackend(_FakeBackend(),
        hint: TagTechHint.mifareClassic);
    expect(driver, isA<MifareClassicTag>());
  });

  test('hint carries the atr through to the driver', () async {
    final atr = Uint8List.fromList([0x3B, 0x8F]);
    final driver = await identifyFromBackend(_FakeBackend(),
        hint: TagTechHint.mifareClassic, atr: atr);
    final info = await driver.readTagInfo();
    expect(info.atr, atr);
  });
}
```

- [ ] **Step 3: Run it, confirm it fails** (`identifyFromBackend`/`TransportBackend`/`TagTechHint` undefined).

```bash
flutter test test/transport/backend_identify_test.dart
```

- [ ] **Step 4: Write `lib/src/transport/backend.dart`**

```dart
import '../tag/tag_info.dart';
import 'transport.dart';

/// A source of typed per-technology transports for one tag. Implemented by
/// [CcidTransportBackend] (over a `CcidCard`) and `AndroidTransportBackend`
/// (over `android.nfc.tech.*`). `identifyFromBackend` builds a driver from
/// whichever transport its tag family needs.
abstract class TransportBackend {
  Type2Transport type2();
  Future<MifareClassicTransport> mifareClassic();
  NfcFTransport nfcF();
  Future<IsoDepTransport> isoDep();
  Future<NfcBTransport?> nfcB();
}

/// A definitive tag-family signal a source can supply to skip probing.
/// The Android source derives this from `Tag.getTechList()`; the CCID
/// source supplies null (it must probe).
enum TagTechHint { type2, mifareClassic, felica, isoDep, typeB }
```
(Note: this imports `tag_info.dart` only if needed for return types; if the analyzer says the import is unused, drop it. The enum and abstract class are the payload.)

- [ ] **Step 5: Make `CcidTransportBackend implements TransportBackend`**

In `lib/src/transport/ccid_backend.dart`, add the import and `implements` clause:
```dart
import 'backend.dart';
// ...
class CcidTransportBackend implements TransportBackend {
```
Its five methods already match the interface exactly — no body changes. Run the analyzer to confirm it satisfies the contract.

- [ ] **Step 6: Refactor `lib/src/tag/detection.dart`**

Extract the identification core to take a `TransportBackend` and an optional hint. Keep `identifyTag(CcidCard)` as the compat wrapper. **The ATR-matching logic and the probing order/log messages must stay byte-for-byte identical** — you are only threading a `TransportBackend` where `CcidTransportBackend` was hardcoded, and adding the hint short-circuit at the top.

```dart
Future<TagDriver> identifyTag(CcidCard card) async {
  return identifyFromBackend(CcidTransportBackend(card), atr: card.atr);
}

Future<TagDriver> identifyFromBackend(
  TransportBackend backend, {
  Uint8List? atr,
  TagTechHint? hint,
}) async {
  if (hint != null) {
    switch (hint) {
      case TagTechHint.type2:
        return Type2Tag(backend.type2(), atr: atr);
      case TagTechHint.mifareClassic:
        return MifareClassicTag(await backend.mifareClassic(), atr: atr);
      case TagTechHint.felica:
        return FelicaTag(backend.nfcF(), atr: atr);
      case TagTechHint.isoDep:
        return IsoDepTag(await backend.isoDep());
      case TagTechHint.typeB:
        final nfcB = await backend.nfcB();
        if (nfcB == null) {
          throw const UnrecognizedTagException(
              'Type B hinted but no Type B target present');
        }
        return TypeBTag(nfcB, atr: atr);
    }
  }
  // Null-hint path continues in Step 7 (paste its body here, before the
  // closing brace of identifyFromBackend).
  // --- null-hint path: the EXISTING ATR-match -> probing chain.
  //     This is CCID-only (probing uses PC/SC pseudo-APDUs). The exact
  //     body is given in Step 7 -- paste it here.
}
```

- [ ] **Step 7: Handle the probing path's `CcidCard` dependency**

`_identifyByProbing` sends raw probe pseudo-APDUs (`FFCA000000`, `FFB0000304`, `00A4040000`) via `_tryTransceive(card, ...)`. Those need a `CcidCard` — the Android source never probes (it always has a hint), so this path is CCID-only. Keep `_identifyFromAtr` and `_identifyByProbing` taking the concrete `CcidCard` + `CcidTransportBackend` exactly as they do today; the `identifyTag(CcidCard)` wrapper is the only caller that reaches them. `identifyFromBackend` with a null hint is only ever called with a `CcidTransportBackend` in practice — assert that:

```dart
  // Null-hint identification requires probing, which is CCID-specific.
  if (backend is! CcidTransportBackend) {
    throw ArgumentError(
        'identifyFromBackend without a hint requires a CcidTransportBackend '
        '(probing uses PC/SC pseudo-APDUs). Android sources must pass a hint.');
  }
  final card = backend.card;
  final atrToUse = atr;
  if (atrToUse != null) {
    final fromAtr = await _identifyFromAtr(card, backend, atrToUse);
    if (fromAtr != null) return fromAtr;
  }
  return _identifyByProbing(card, backend, atrToUse);
```
(`CcidTransportBackend.card` is already a public final field — confirm; if it's private, make it public.)

- [ ] **Step 8: Export the new symbols** from `lib/nfc_hub.dart`:
```dart
export 'src/transport/backend.dart' show TransportBackend, TagTechHint;
export 'src/tag/detection.dart' show identifyTag, identifyFromBackend;
```

- [ ] **Step 9: Verify**

```bash
flutter analyze
flutter test 2>&1 | tail -1        # > 116
flutter test test/tag/detection_test.dart   # unchanged behavior, must pass
```
`detection_test.dart` passing unchanged is the proof the CCID path didn't move.

- [ ] **Step 10: Commit**
```bash
git add -A
git commit -m "refactor: generalize identifyTag over an abstract TransportBackend + tech hint

CcidTransportBackend now implements TransportBackend. identifyFromBackend takes
any backend plus an optional TagTechHint that skips probing -- the Android source
will supply a hint from Tag.getTechList(). identifyTag(CcidCard) is unchanged."
```

---

### Task 2: The Android NFC channel protocol (Dart side, faked)

Define the Dart wrapper over the method+event channels the Kotlin will speak, and TEST it against a fake channel — before any Kotlin exists. This pins the protocol so Task 5's Kotlin has an exact contract to implement.

**Files:**
- Create: `lib/src/platform/android_nfc_manager.dart`
- Create: `test/platform/android_nfc_manager_test.dart`

**Interfaces:**
- Consumes: the `nfc_hub` MethodChannel and a new `nfc_hub/events` EventChannel.
- Produces: `AndroidNfcManager` with:
  - `Stream<NfcTagDiscovery> discoveries` — decoded from the event channel.
  - `Stream<int> tagLosses` — handles of departed tags.
  - `Stream<NfcState> nfcStateChanges`.
  - `Future<Uint8List> transceive(int handle, String tech, Uint8List data)` — method call `nfcTransceive`.
  - `Future<void> mifareAuthenticate(int handle, int sector, bool keyA, Uint8List key)` — `nfcMifareAuth`.
  - `Future<Uint8List> mifareReadBlock(int handle, int block)` — `nfcMifareReadBlock`.
  - `Future<void> startReaderMode()` / `stopReaderMode()` — `nfcStartReaderMode` / `nfcStopReaderMode`.
  - `Future<NfcState> getNfcState()` — `getNfcState`.
  - `Future<void> openNfcSettings()` — `openNfcSettings`.
  - `NfcTagDiscovery` value type: `{int handle, List<String> techList, Uint8List uid, Uint8List? atqa, int? sak, Uint8List? atqb, Uint8List? idm, Uint8List? pmm, Uint8List? historicalBytes}`.
  - `enum NfcState { enabled, disabled, noHardware }`.

- [ ] **Step 1: Write the failing test** (fake the method channel + event channel):

```dart
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/src/platform/android_nfc_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const method = MethodChannel('nfc_hub');
  final log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, (call) async {
      log.add(call);
      switch (call.method) {
        case 'nfcTransceive':
          return Uint8List.fromList([0x90, 0x00]);
        case 'getNfcState':
          return 'enabled';
      }
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(method, null);
    log.clear();
  });

  test('transceive forwards handle/tech/data and returns the response bytes',
      () async {
    final m = AndroidNfcManager();
    final r = await m.transceive(7, 'IsoDep',
        Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, 0x00]));
    expect(r, Uint8List.fromList([0x90, 0x00]));
    expect(log.single.method, 'nfcTransceive');
    final args = log.single.arguments as Map;
    expect(args['handle'], 7);
    expect(args['tech'], 'IsoDep');
    expect(args['data'], Uint8List.fromList([0x00, 0xA4, 0x04, 0x00, 0x00]));
  });

  test('getNfcState decodes the string into the enum', () async {
    final m = AndroidNfcManager();
    expect(await m.getNfcState(), NfcState.enabled);
  });
}
```

- [ ] **Step 2: Run, confirm failure.**

- [ ] **Step 3: Implement `lib/src/platform/android_nfc_manager.dart`.**

Use `const MethodChannel('nfc_hub')` and `const EventChannel('nfc_hub/events')`. The event channel emits maps with a `type` discriminator (`tagDiscovered` / `tagLost` / `nfcStateChanged`); demux them into the three streams (use a broadcast controller fanning out from a single `receiveBroadcastStream().listen`). Decode discovery maps into `NfcTagDiscovery`. Method calls pass `{'handle': h, 'tech': t, 'data': bytes}` etc. `getNfcState()` maps `'enabled'|'disabled'|'noHardware'` → enum. Keep it MECHANICAL — no logic beyond marshalling.

- [ ] **Step 4: Verify** (`flutter analyze`, the new test file, full suite > previous).

- [ ] **Step 5: Commit** `"feat: add AndroidNfcManager -- Dart wrapper over the NFC channel protocol"`.

---

### Task 3: The five Android transports + `AndroidTransportBackend`

Implement the transport interfaces over `AndroidNfcManager`, lazily connecting via the handle. Test each against a fake `AndroidNfcManager`. This is where the Android-side byte formats live (Type-2 `0x30`/`0x60`, FeliCa length-prefix, ISO-DEP passthrough) — all testable without hardware.

**Files:**
- Create: `lib/src/transport/android_backend.dart`
- Create: `test/transport/android_backend_test.dart`
- Modify: `lib/nfc_hub.dart` (no new public export needed unless a consumer must name these; keep them internal for now)

**Interfaces:**
- Consumes: `AndroidNfcManager`, `NfcTagDiscovery`, the five transport interfaces, `TransportBackend`.
- Produces: `AndroidTransportBackend implements TransportBackend`, constructed as `AndroidTransportBackend(manager, discovery)`. It builds each transport pre-populated with the discovery's identity fields, so `MifareClassicTransport.uid/atqa/sak`, `NfcFTransport.idm/pmm`, `NfcBTransport.pupi/atqb`, and `IsoDepTransport.historicalBytes` are all satisfied from the tap-time data with no I/O.
- The Android→wire mappings (mirror of the CCID backend's, but native):

| Transport member | Android implementation |
|---|---|
| `Type2Transport.readUid` | `discovery.uid` (from `Tag.getId()`, no connect) |
| `Type2Transport.readCapabilityContainer` | `transceive(h,'NfcA',[0x30,0x03])` then take bytes `[0..4)` |
| `Type2Transport.readPages(p)` | `transceive(h,'NfcA',[0x30,p])` → 16 bytes |
| `Type2Transport.getVersion` | `transceive(h,'NfcA',[0x60])` → 8 bytes, catch→null (must return exactly 8 or null) |
| `MifareClassicTransport.authenticate` | `manager.mifareAuthenticate(h, sector, keyA, key)` → throw `MifareAuthException` on `false` (verified: Android's `authenticateSectorWithKeyA` returns `false` on a wrong key, matching the CCID backend's contract) |
| `MifareClassicTransport.readBlock(b)` | `manager.mifareReadBlock(h, b)` |

**Verified Android behavioral note (carry into the code comments):** `MifareClassic.authenticateSectorWithKeyA/B` (a) requires the tech to be `connect()`ed first — the Kotlin `connectMifare()` handles this; (b) returns `false` on a rejected key (NOT an exception — so map `false` → `MifareAuthException` in the transport, and only a thrown `IOException`/`TagLostException` → `TagLostException`); (c) **a failed auth causes an implicit reconnect, so any prior sector's authentication is lost.** That third point matches CCID's per-sector model (each sector re-authenticates), so `readSector` already re-auths per call — no driver change needed, but do not assume a held auth survives a failed attempt.
| `MifareClassicTransport` uid/atqa/sak | from `discovery` |
| `NfcFTransport.transceive` | prepend `frame.length+1`, `transceive(h,'NfcF',framed)` — NO PN532 wrapping (that's CCID-only) |
| `NfcFTransport.idm/pmm` | from `discovery` (`Tag.getId()` / `NfcF.getManufacturer()`) |
| `IsoDepTransport.transceive` | `transceive(h,'IsoDep',apdu)` — return raw, SW included |
| `IsoDepTransport.uid/historicalBytes` | from `discovery` |
| `NfcBTransport.transceive` | `transceive(h,'NfcB',apdu)` |
| `NfcBTransport.pupi/atqb` | from `discovery` |

- [ ] **Step 1: Write failing tests** against a fake `AndroidNfcManager` that records `transceive(handle, tech, data)` calls and returns scripted responses. Assert, for each transport, the EXACT `(tech, data)` put on the wire:
  - Type2 `readPages(4)` → `('NfcA', [0x30, 0x04])`, returns 16 bytes.
  - Type2 `readCapabilityContainer()` → `('NfcA', [0x30, 0x03])`, returns first 4 of the 16.
  - Type2 `getVersion()` → `('NfcA', [0x60])`; and returns null when the fake throws.
  - NfcF `transceive([0x0C, ...idm])` → `('NfcF', [0x0A, 0x0C, ...idm])` (length byte `0x0A` = 9+1 prepended). **This is the contract that bit us in Plan 2 — pin it hard.**
  - IsoDep `transceive([0x00,0xA4,0x04,0x00,0x00])` → `('IsoDep', same)`, returns the raw response including SW, NOT stripped.
  - MifareClassic `authenticate(1, keyA, key)` → `manager.mifareAuthenticate(h, 1, true, key)`; throws `MifareAuthException` when the fake returns false.
  - Identity getters return the discovery's fields with no `transceive` call.

- [ ] **Step 2: Run, confirm failure.**

- [ ] **Step 3: Implement `lib/src/transport/android_backend.dart`.** One private transport class per family, each holding `(manager, handle, discovery)`. `AndroidTransportBackend`'s `type2()`/`nfcF()` are sync; `mifareClassic()`/`isoDep()` return `Future.value(...)` (identity is already in `discovery`, no poll needed); `nfcB()` returns the transport if the discovery has an ATQB, else null. Map a Kotlin-side `TagLostException` (surfaced as a `PlatformException` with a known code, e.g. `'TAG_LOST'`) onto the Dart `TagLostException` inside each `transceive`.

- [ ] **Step 4: Verify.**

- [ ] **Step 5: Commit** `"feat: add AndroidTransportBackend implementing the five transports natively"`.

---

### Task 4: `TagSource`, `AndroidNfcSource`, and the identity→hint mapping

A `TagSource` yields a stream of identified `TagDriver`s. `AndroidNfcSource` turns the manager's discovery stream into that: for each discovery, derive a `TagTechHint` from the tech list, build an `AndroidTransportBackend`, call `identifyFromBackend(..., hint:)`, and emit. Testable against a fake manager.

**Files:**
- Create: `lib/src/source/tag_source.dart`
- Create: `lib/src/source/android_source.dart`
- Create: `test/source/android_source_test.dart`

**Interfaces:**
- Produces:
  - `abstract class TagSource { Stream<TagDriver> tags(); Future<void> dispose(); }`
  - `AndroidNfcSource(AndroidNfcManager manager)` implementing it. `tags()` starts reader mode on first listen and stops it when the last listener cancels.
  - `TagTechHint? hintFromTechList(List<String> techList)` — the mapping (also used/tested standalone):
    - contains `android.nfc.tech.MifareClassic` → `mifareClassic`
    - else contains `android.nfc.tech.NfcF` → `felica`
    - else contains `android.nfc.tech.IsoDep` → `isoDep`
    - else contains `android.nfc.tech.NfcB` (without IsoDep) → `typeB`
    - else contains `android.nfc.tech.NfcA` (NDEF/Ultralight/Type 2) → `type2`
    - else → null (emit nothing; log)

- [ ] **Step 1: Write failing tests:**
  - `hintFromTechList` for each of the six cases above (including the precedence: a tag listing BOTH `MifareClassic` and `NfcA` → `mifareClassic`, since MifareClassic is a superset tech).
  - `AndroidNfcSource.tags()`: feed the fake manager a discovery with a MIFARE tech list → the stream emits a `MifareClassicTag`; feed a FeliCa discovery → `FelicaTag`; feed an unknown tech list → nothing emitted (and no throw).
  - starting `tags()` calls `manager.startReaderMode()`; cancelling the last subscription calls `stopReaderMode()`.

- [ ] **Step 2-4:** run→fail, implement, verify.

- [ ] **Step 5: Commit** `"feat: add AndroidNfcSource -- reader-mode discoveries to a TagDriver stream"`.

---

### Task 5: The Kotlin native side (NOT unit-testable — compile + review + hardware gate)

This is the one task with no unit test. It is compile-checked (`./gradlew compileDebugKotlin`), reviewed against the exact Dart protocol Task 2 pinned, and settled only on-device. **The plan gives complete code because the implementer cannot discover it by running tests.**

Keep it thin: reader-mode lifecycle, a `handle → Tag` map, lazy `connect()` on first transceive, the tech dispatch, MIFARE auth/read, `getNfcState`, `openNfcSettings`. No parsing, no identification — all of that is Dart.

**Files:**
- Create: `android/src/main/kotlin/com/cheqplease/nfchub/NfcReaderModeController.kt`
- Modify: `android/src/main/kotlin/com/cheqplease/nfchub/NfcHubPlugin.kt` (delegate the new methods + own the EventChannel)
- Modify: `android/src/main/AndroidManifest.xml`

**Interfaces:**
- Consumes: the exact method names + argument keys + event map shapes Task 2 defined.
- Produces: the native half of the protocol. Nothing else in the codebase calls it directly.

- [ ] **Step 1: Add the NFC manifest entries** to `android/src/main/AndroidManifest.xml`:
```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
  package="com.cheqplease.nfchub">
  <uses-permission android:name="android.permission.NFC"/>
  <uses-feature android:name="android.hardware.nfc" android:required="false"/>
</manifest>
```
`required="false"` so USB-reader-only devices (no NFC chip) still install.

- [ ] **Step 2: Write `NfcReaderModeController.kt`** (complete — copy verbatim, this cannot be discovered by tests):

```kotlin
package com.cheqplease.nfchub

import android.app.Activity
import android.content.Context
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.nfc.tech.MifareClassic
import android.nfc.tech.NfcA
import android.nfc.tech.NfcB
import android.nfc.tech.NfcF
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Owns reader mode, a handle->Tag map, and lazy per-tag tech connections.
 *  All identity extraction happens here (from the Tag, no connect()); all
 *  parsing/identification happens in Dart. */
class NfcReaderModeController(
    private val context: Context,
    private val events: EventChannel.EventSink?
) : NfcAdapter.ReaderCallback {

    private val adapter: NfcAdapter? = NfcAdapter.getDefaultAdapter(context)
    private val main = Handler(Looper.getMainLooper())
    private val tags = HashMap<Int, Tag>()
    private val connected = HashMap<Int, Any>() // handle -> connected tech
    private var nextHandle = 1
    private var activity: Activity? = null

    fun attachActivity(a: Activity?) { activity = a }

    fun nfcState(): String = when {
        adapter == null -> "noHardware"
        adapter.isEnabled -> "enabled"
        else -> "disabled"
    }

    fun startReaderMode() {
        val a = activity ?: return
        val flags = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
        adapter?.enableReaderMode(a, this, flags, null)
    }

    fun stopReaderMode() {
        val a = activity ?: return
        adapter?.disableReaderMode(a)
        closeAll()
    }

    override fun onTagDiscovered(tag: Tag) {
        val handle = synchronized(tags) { val h = nextHandle++; tags[h] = tag; h }
        val techList = tag.techList.toList()
        val map = HashMap<String, Any?>()
        map["type"] = "tagDiscovered"
        map["handle"] = handle
        map["techList"] = techList
        map["uid"] = tag.id
        NfcA.get(tag)?.let { map["atqa"] = it.atqa; map["sak"] = it.sak.toInt() }
        NfcB.get(tag)?.let {
            // ATQB reconstructed as 50 | PUPI(id) | AppData | ProtocolInfo
            map["atqb"] = byteArrayOf(0x50) + tag.id + it.applicationData + it.protocolInfo
        }
        NfcF.get(tag)?.let { map["idm"] = tag.id; map["pmm"] = it.manufacturer }
        IsoDep.get(tag)?.let { map["historicalBytes"] = it.historicalBytes ?: it.hiLayerResponse }
        main.post { events?.success(map) }
    }

    /** Lazily connects the requested tech and transceives. Throws to the
     *  MethodChannel Result as code TAG_LOST when the tag has left. */
    fun transceive(handle: Int, tech: String, data: ByteArray): ByteArray {
        val tag = synchronized(tags) { tags[handle] }
            ?: throw TagGoneException("Unknown or lost tag handle $handle")
        return try {
            when (tech) {
                "NfcA" -> connectNfcA(handle, tag).transceive(data)
                "NfcB" -> connectNfcB(handle, tag).transceive(data)
                "NfcF" -> connectNfcF(handle, tag).transceive(data)
                "IsoDep" -> connectIsoDep(handle, tag).transceive(data)
                else -> throw IllegalArgumentException("Unknown tech $tech")
            }
        } catch (e: android.nfc.TagLostException) {
            close(handle)
            throw TagGoneException("Tag lost during transceive: ${e.message}")
        }
    }

    fun mifareAuthenticate(handle: Int, sector: Int, keyA: Boolean, key: ByteArray): Boolean {
        val tag = synchronized(tags) { tags[handle] }
            ?: throw TagGoneException("Unknown or lost tag handle $handle")
        val mc = connectMifare(handle, tag)
        return if (keyA) mc.authenticateSectorWithKeyA(sector, key)
        else mc.authenticateSectorWithKeyB(sector, key)
    }

    fun mifareReadBlock(handle: Int, block: Int): ByteArray {
        val tag = synchronized(tags) { tags[handle] }
            ?: throw TagGoneException("Unknown or lost tag handle $handle")
        return connectMifare(handle, tag).readBlock(block)
    }

    private fun connectNfcA(h: Int, tag: Tag): NfcA =
        (connected[h] as? NfcA) ?: NfcA.get(tag).also { it.connect(); connected[h] = it }
    private fun connectNfcB(h: Int, tag: Tag): NfcB =
        (connected[h] as? NfcB) ?: NfcB.get(tag).also { it.connect(); connected[h] = it }
    private fun connectNfcF(h: Int, tag: Tag): NfcF =
        (connected[h] as? NfcF) ?: NfcF.get(tag).also { it.connect(); connected[h] = it }
    private fun connectIsoDep(h: Int, tag: Tag): IsoDep =
        (connected[h] as? IsoDep) ?: IsoDep.get(tag).also { it.connect(); connected[h] = it }
    private fun connectMifare(h: Int, tag: Tag): MifareClassic =
        (connected[h] as? MifareClassic) ?: MifareClassic.get(tag).also { it.connect(); connected[h] = it }

    private fun close(handle: Int) {
        synchronized(tags) { tags.remove(handle) }
        (connected.remove(handle) as? android.nfc.tech.TagTechnology)?.let {
            try { it.close() } catch (_: Exception) {}
        }
    }
    private fun closeAll() {
        synchronized(tags) { tags.keys.toList() }.forEach { close(it) }
    }
}

class TagGoneException(message: String) : Exception(message)
```

- [ ] **Step 3: Wire it into `NfcHubPlugin.kt`.** Add an `EventChannel("nfc_hub/events")` with a `StreamHandler` that hands its sink to a fresh `NfcReaderModeController`; give the controller the activity in `onAttachedToActivity`/`onDetachedFromActivity`. Add these `when (call.method)` cases, delegating to the controller and catching `TagGoneException` → `result.error("TAG_LOST", ...)`:
  - `"nfcStartReaderMode"` → `controller.startReaderMode(); result.success(null)`
  - `"nfcStopReaderMode"` → `controller.stopReaderMode(); result.success(null)`
  - `"nfcTransceive"` → `result.success(controller.transceive(handle, tech, data))`
  - `"nfcMifareAuth"` → `result.success(controller.mifareAuthenticate(handle, sector, keyA, key))`
  - `"nfcMifareReadBlock"` → `result.success(controller.mifareReadBlock(handle, block))`
  - `"getNfcState"` → `result.success(controller.nfcState())`
  - `"openNfcSettings"` → start `Intent(android.provider.Settings.ACTION_NFC_SETTINGS)` with `FLAG_ACTIVITY_NEW_TASK`; `result.success(null)`.
  Emit `{"type":"nfcStateChanged","state":...}` from a `BroadcastReceiver` on `NfcAdapter.ACTION_ADAPTER_STATE_CHANGED` (register in `onAttachedToActivity`, unregister in `onDetached`). The existing USB/CCID method cases and the USB permission receiver stay UNTOUCHED.

  **Verified reader-mode lifecycle constraint:** `enableReaderMode` throws `NullPointerException` on a null activity and `IllegalStateException` on a destroyed one; a backgrounded (not-yet-resumed) activity does NOT throw — the flags are stored and applied on the next `onActivityResumed`. So `NfcReaderModeController.startReaderMode()` returning early when `activity == null` (as written) is safe, and reader mode will engage once an activity attaches. But to honor the foreground requirement cleanly, ALSO call `startReaderMode()` from `onReattachedToActivityForConfigChanges`/`onAttachedToActivity` when a Dart listener is already active, and `stopReaderMode()` from `onDetachedFromActivity`. The Dart side (Task 4's `AndroidNfcSource`) is the source of truth for "should reader mode be on" (listener-count driven); the plugin just forwards `nfcStartReaderMode`/`nfcStopReaderMode` and re-applies across activity transitions.

- [ ] **Step 4: Compile-check (the only automated gate for this task).**
```bash
cd /Users/akashshahriar/StudioProjects/ccid/example
flutter build apk --debug
# and directly:
cd android && ./gradlew :nfc_hub:compileDebugKotlin --rerun-tasks
```
Expected: `BUILD SUCCESSFUL`. Also `flutter analyze` + `flutter test` (Dart untouched → still green at the current count).

- [ ] **Step 5: Commit** `"feat: add Android reader-mode NFC native backend (NfcReaderModeController)"`.

**HARDWARE GATE (record as outstanding, cannot be closed here):** on a physical NFC phone, tapping a tag must emit a discovery and reads must work. This is the only real verification of Task 5.

---

### Task 6: `CcidSource` + auto-detect poll loop

Turn the CCID readers into a `TagSource` too, so both feed one stream. A timer polls attached readers; on a newly-seated card it connects, identifies, and emits a `TagDriver`; when a held card's status probe fails, it disconnects and resumes polling. Pure Dart state machine, tested against a fake platform.

**Files:**
- Create: `lib/src/source/ccid_source.dart`
- Create: `test/source/ccid_source_test.dart`

**Interfaces:**
- Consumes: `NfcHubPlatform` (listReaders/connect/disconnect/transceive), `identifyTag`.
- Produces: `CcidSource(NfcHubPlatform platform, {Duration pollInterval})` implementing `TagSource`. Also exposes `Stream<List<ExternalReaderState>> readerStates()` for Task 7's connection state. The loop only runs while `tags()` or `readerStates()` has a listener.

- [ ] **Step 1: Write failing tests** against a fake `NfcHubPlatform` whose `listReaders`/`connect`/`transceive` are scriptable per tick, driving a `FakeAsync` clock:
  - reader appears with a card → after one poll interval, `tags()` emits a `TagDriver` and `readerStates()` shows `cardPresent: true`.
  - held card removed (a status probe throws) → `readerStates()` shows `cardPresent: false`, and a subsequent re-insertion emits a NEW `TagDriver`.
  - same card staying put does NOT re-emit (dedup: once a reader is "occupied", don't re-identify until it goes empty and refills).
  - no listeners → no `listReaders` calls (loop idle).

- [ ] **Step 2-4:** run→fail, implement (a `Timer.periodic` guarded by listener count; per-reader state `{empty, occupied}`; on `empty`→connect attempt, on `occupied`→status probe), verify with `fake_async`.

- [ ] **Step 5: Commit** `"feat: add CcidSource with an auto-detect poll loop"`.

---

### Task 7: The unified API — `tagStream`, `readTag`, `connectionState`, `openNfcSettings`

Merge the two sources and expose the public surface on `NfcHub`. Pure Dart, tested against fake sources.

**Files:**
- Create: `lib/src/nfc_hub_api.dart` (state types + the merge logic)
- Modify: `lib/src/nfc_hub_base.dart` (`NfcHub` delegates the new methods here)
- Modify: `lib/nfc_hub.dart` (export the new public types)
- Create: `test/nfc_hub_api_test.dart`

**Interfaces:**
- Produces on `NfcHub`:
  - `Stream<TagDriver> tagStream({CcidSourceFilter? from})` — merges `AndroidNfcSource` + `CcidSource`; the filter restricts to one source/reader.
  - `Future<TagDriver> readTag({CcidSourceFilter? from, Duration? timeout})` — `tagStream(from: from).first` with an optional timeout.
  - `Stream<CcidConnectionState> connectionState()` — built-in availability + per-reader presence.
  - `Future<void> openNfcSettings()`.
  - Value types: `CcidSourceFilter` (`.builtInNfc()` / `.reader(String)` / null=any), `CcidConnectionState {bool builtInNfcAvailable; NfcUnavailableReason builtInNfcReason; List<ExternalReaderState> externalReaders}`, `ExternalReaderState {String name; bool cardPresent}`, `enum NfcUnavailableReason { none, noHardware, disabled }`, `TagSource`-tag carries a `TagSourceKind` for optional display.

- [ ] **Step 1: Write failing tests** against fake sources:
  - `tagStream()` with no filter emits tags from BOTH a fake Android source and a fake CCID source, interleaved.
  - `tagStream(from: CcidSourceFilter.builtInNfc())` emits only Android-source tags.
  - `tagStream(from: CcidSourceFilter.reader('ACR122U'))` emits only that reader's tags.
  - `readTag()` returns the first tag from any source; `readTag(timeout:)` throws `TimeoutException` when nothing arrives.
  - `connectionState()` reflects `getNfcState()` (enabled → `builtInNfcAvailable: true, reason: none`; disabled → `false, disabled`; noHardware → `false, noHardware`) merged with the CCID `readerStates()`.
  - the merged tag stream starts/stops both sources based on listeners.

- [ ] **Step 2-4:** run→fail, implement the merge (a broadcast controller subscribing to both sources' `tags()`, filtered), the state combiner, `openNfcSettings` delegating to the manager; wire onto `NfcHub`. Verify.

- [ ] **Step 5: Commit** `"feat: unified tagStream/readTag/connectionState/openNfcSettings on NfcHub"`.

---

### Task 8: Release prep — exports, CHANGELOG, version, publish gate

**Files:**
- Modify: `lib/nfc_hub.dart`, `CHANGELOG.md`, `pubspec.yaml`

- [ ] **Step 1: Export the new public types** from `lib/nfc_hub.dart`: `NfcHub`'s new return/param types — `CcidSourceFilter`, `CcidConnectionState`, `ExternalReaderState`, `NfcUnavailableReason`, `TagSourceKind` (whatever the app needs to consume `tagStream`/`connectionState`). Do NOT export the internal source/backend/manager classes.

- [ ] **Step 2: CHANGELOG `## 0.6.0`** describing: built-in NFC support via `tagStream()`; the unified `readTag`/`connectionState`/`openNfcSettings`; CCID auto-detect; that drivers work identically on both sources; `identifyFromBackend` + `TagTechHint` for advanced callers. Note the CCID path is unchanged. Set `version: 0.6.0`.

- [ ] **Step 3: Full verification.**
```bash
flutter analyze
flutter test 2>&1 | tail -1
flutter pub publish --dry-run 2>&1 | tail -3        # 0 warnings
flutter pub publish --dry-run 2>&1 | grep -i "archive size"   # < 1 MB
(cd example && flutter build apk --debug)
```

- [ ] **Step 4: Commit** `"chore: release 0.6.0 -- built-in NFC + unified tag stream"`.

---

## Definition of Done

- `flutter analyze` clean; `flutter test` ≥ 116 + all new tests, 0 failing.
- `flutter pub publish --dry-run` 0 warnings, archive < 1 MB.
- `example` APK builds; `./gradlew :nfc_hub:compileDebugKotlin` succeeds.
- `identifyTag(CcidCard)` and `detection_test.dart` pass unchanged — the CCID path did not move.
- The FeliCa length-prefix and the DESFire no-SW behaviors are pinned by Android-transport tests (they are the two byte-format traps that would break the MRT and DESFire paths on the new backend).
- **OUTSTANDING HARDWARE GATES (cannot be closed in CI — carry to the user):**
  1. Plan 1's rename (method channel + USB permission action) — still unverified on device.
  2. Plan 2's new poll-before-auth / poll-before-SELECT orderings on the ACR122U.
  3. **Plan 3's entire Android path** — tap a tag on a physical NFC phone, confirm a discovery is emitted and `readNdef()` / `readSector()` / `readWithoutEncryption()` work, and confirm the SAME driver code path against the ACR122U still works (no regression). This is the plan's real acceptance test.
  4. CCID auto-detect's interaction with the USB permission dialog (the poll loop's first `connect()` prompts once).
