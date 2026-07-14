# Transport Abstraction & CCID Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decouple the five tag drivers from `CcidCard` by introducing per-technology transport interfaces, implemented by a CCID backend that relocates today's hardware-validated pseudo-APDUs verbatim — so that Plan 3 can add an Android built-in-NFC backend behind the same interfaces without touching a single driver.

**Architecture:** Plan 2 of 3. This is an **internal refactor with zero public API change and zero behavior change**. `NfcHub().listReaders()`, `.connect()`, and `identifyTag(card)` keep working exactly as they do today; the example app should need no edits beyond what Task 8 specifies. What changes is *below* that line: each driver stops holding a `CcidCard` and holds a typed transport instead, and the PC/SC + PN532 dialect moves out of the drivers and down into one CCID backend.

**Tech Stack:** Flutter 3.38.3 / Dart SDK `>=3.5.0 <4.0.0`, `flutter_test`, `flutter_lints` ^5.0.0. No new dependencies.

## Global Constraints

Every task's requirements implicitly include this section.

- **The byte sequences are sacred.** This library's correctness lives in exact APDU bytes, validated against real ACR122U hardware with real MIFARE Classic / FeliCa (Dhaka MRT) / NTAG cards. Every pseudo-APDU string moved in this plan must arrive **byte-identical**. A prior bug in this repo — `'FFB00000${pageHex}10'`, a 6-byte APDU with P2 stuck at `00` instead of the correct 5-byte `'FFB000${pageHex}10'` — survived multiple reviews. Assume that class of error is waiting to happen again.
- **Zero behavior change. Zero public API change.** `NfcHub`, `CcidCard`, `identifyTag(CcidCard)`, and every driver's public method signatures stay as they are. Only driver *constructors* change (they take a transport instead of a `CcidCard`), and those are effectively internal — `identifyTag` is how callers get drivers.
- **Test baseline: 84 passing, 0 failing.** Tasks will ADD tests (the transport backend needs byte-exactness tests that don't exist yet). The count may only go **up**, never down. A drop means a test was lost.
- `flutter analyze` must show no new issues. Two pre-existing info-lints in `example/test/mrt_transaction_test.dart` are expected.
- **Every task must leave the build green.** Drivers migrate one at a time; each migration task also updates that driver's construction sites (`identifyTag`, tests, example) in the same commit.
- **No `NfcATransport`.** Raw ISO14443-A byte access is not portable to CCID (see the spec's portability rule). Type 2 gets a method-based transport. Do not add a raw-byte NfcA interface "for completeness."
- Do NOT touch: `android/` (Kotlin), the method channel, `LICENSE`, or anything in Plan 3's scope (`tagStream`, `connectionState`, built-in NFC).

Spec: `docs/superpowers/specs/2026-07-14-unified-nfc-transport-design.md` (read its "Layer 1" and "Layer 2" sections before starting).

## Roadmap

- **Plan 1 (done):** rename `ccid` → `nfc_hub`, restructure `lib/`.
- **Plan 2 (this document):** transport interfaces + CCID backend. Drivers stop depending on `CcidCard`. Still CCID-only; no user-visible change.
- **Plan 3 (next):** Android built-in-NFC backend, unified `tagStream()`/`readTag()`/`connectionState()`/`openNfcSettings()`, CCID card-presence poll loop, and the rebuilt example app demonstrating both sources.

## File Structure

New:

```
lib/src/transport/transport.dart      # the 5 abstract interfaces + TagLostException
lib/src/transport/ccid_backend.dart   # CcidTransportBackend: all 5, over a CcidCard
test/transport/ccid_backend_test.dart # byte-exactness tests for every pseudo-APDU
```

Changed: each of `lib/src/tag/{type2,mifare_classic,felica,iso_dep,iso_b}.dart` swaps its `CcidCard` for a transport; `lib/src/tag/tag_driver.dart` drops the `card` field; `lib/src/tag/detection.dart` builds the backend and injects transports.

Eventually dead (removed in Task 9): `lib/src/apdu.dart`'s `transceiveEscape`, and `lib/src/pn532.dart` — both get absorbed into `ccid_backend.dart`, which becomes the single place the PN532/PC-SC dialect lives.

---

### Task 1: Define the transport interfaces

Pure interface declarations plus one exception type. No behavior, so no TDD cycle — the gate is that it analyzes and the existing 84 tests still pass. Also strips the `card` field from `TagDriver` so drivers can stop passing it up.

**Files:**
- Create: `lib/src/transport/transport.dart`
- Modify: `lib/src/tag/tag_driver.dart`
- Modify: `lib/src/tag/{type2,mifare_classic,felica,iso_dep,iso_b}.dart` (each temporarily declares its own `card` field)

**Interfaces:**
- Consumes: nothing.
- Produces: `Type2Transport`, `MifareClassicTransport`, `NfcFTransport`, `IsoDepTransport`, `NfcBTransport`, `TagLostException`. Every later task depends on these exact signatures.

- [ ] **Step 1: Confirm the baseline is green**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test 2>&1 | tail -1
```

Expected: `All tests passed!`, 84.

- [ ] **Step 2: Write `lib/src/transport/transport.dart`**

```dart
import 'dart:typed_data';

import '../tag/mifare_classic.dart' show MifareKeyType;

/// Thrown by any transport call after the tag has left the field or the
/// card was removed from the reader. Both backends map their native
/// failure onto this: Android's `TagLostException`, and a CCID
/// transceive/slot-status failure.
class TagLostException implements Exception {
  final String message;

  const TagLostException(this.message);

  @override
  String toString() => 'TagLostException: $message';
}

/// Transport for an NFC Forum Type 2 tag (NTAG / MIFARE Ultralight).
///
/// Method-based, not raw-byte: the ACR122U exposes Type-2 reads only as
/// PC/SC pseudo-APDUs (`FFB0` Read Binary, `FFCA` Get Data) which the
/// reader itself translates, so only the *operation* is portable, not the
/// byte sequence. Android implements these directly as `NfcA.transceive`
/// with the Type-2 command set (`0x30` READ, `0x60` GET_VERSION).
abstract class Type2Transport {
  /// The tag's UID.
  Future<Uint8List> readUid();

  /// The 4-byte Capability Container (page 3).
  Future<Uint8List> readCapabilityContainer();

  /// 16 bytes (4 pages) starting at [startPage].
  Future<Uint8List> readPages(int startPage);

  /// The NXP `GET_VERSION` (0x60) response, or null where the reader or
  /// tag doesn't support it. Must not throw for the unsupported case.
  Future<Uint8List?> getVersion();
}

/// Transport for a MIFARE Classic 1K/4K tag.
///
/// Method-based: Android's crypto1 handshake
/// (`MifareClassic.authenticateSectorWithKeyA/B`) is not a proxyable byte
/// stream, and on CCID the reader runs the cipher itself via the `FF82`
/// Load Key / `FF86` General Authenticate pseudo-APDUs.
abstract class MifareClassicTransport {
  Uint8List get uid;
  Uint8List get atqa;
  int get sak;

  /// Authenticates [sector] with [key] as key [type].
  /// Throws [MifareAuthException] if the key is rejected.
  Future<void> authenticate(int sector, MifareKeyType type, Uint8List key);

  /// Reads one 16-byte block. Its sector must already be authenticated.
  Future<Uint8List> readBlock(int block);
}

/// Transport for a FeliCa (NFC-F / JIS X 6319-4) tag.
///
/// Raw-frame: the same length-prefixed FeliCa frame is valid on both
/// sides. Android's `NfcF.transceive` takes exactly this; the CCID backend
/// wraps it in the PN532 InDataExchange command (`D4 40 01`) and strips
/// the `D5 41 <status>` response header.
abstract class NfcFTransport {
  /// The 8-byte IDm.
  Future<Uint8List> get idm;

  /// The 8-byte PMm (Manufacturer Parameter).
  Future<Uint8List> get pmm;

  /// Sends a length-prefixed FeliCa frame, returns the raw response frame
  /// (its own length byte included).
  Future<Uint8List> transceive(Uint8List felicaFrame);
}

/// Transport for a generic ISO14443-4 ("ISO-DEP") processor card.
///
/// Raw-frame: ISO 7816-4 APDUs pass through unchanged on both sides.
abstract class IsoDepTransport {
  /// The tag's UID. Empty if the source cannot supply one.
  Future<Uint8List> get uid;

  /// The card's ATR (CCID) or ISO-DEP historical bytes (Android), where
  /// the source supplies one.
  Uint8List? get historicalBytes;

  /// Sends a raw APDU and returns the raw response, INCLUDING any trailing
  /// status word. Callers do their own status-word handling — DESFire's
  /// native mode returns no SW at all, so this transport must not assume one.
  Future<Uint8List> transceive(Uint8List apdu);
}

/// Transport for an ISO14443-B card.
abstract class NfcBTransport {
  /// The PUPI (bytes 1-4 of ATQB).
  Uint8List get pupi;

  /// The 12-byte ATQB: `'50' | PUPI(4) | AppData(4) | ProtocolInfo(3)`.
  Uint8List get atqb;

  Future<Uint8List> transceive(Uint8List apdu);
}
```

- [ ] **Step 3: Strip the `card` field from `TagDriver`**

`lib/src/tag/tag_driver.dart` — the base class currently holds `final CcidCard card;` and a `const TagDriver(this.card);` constructor. Drivers are about to stop having a `CcidCard` at all. Replace the class body with:

```dart
/// Base class for tag-family-specific drivers returned by [identifyTag]
/// (see `detection.dart`).
///
/// Each driver wraps a typed transport (see `../transport/transport.dart`)
/// and exposes only the read operations that make sense for that tag
/// family. Drivers are transport-agnostic: the same driver serves a card on
/// a USB CCID reader and (from Plan 3) a tag on the device's own antenna.
abstract class TagDriver {
  const TagDriver();

  /// A generic identification summary for this tag: technology, UID, and
  /// ATR where the transport supplies one. Concrete drivers return their
  /// family-specific subtype (e.g. [Type2Tag] returns a `Type2TagInfo`).
  Future<TagInfo> readTagInfo();
}
```

Delete the now-unused `import 'ccid.dart';` / `CcidCard` import if it becomes unused. Keep `TagInfo` and `UnrecognizedTagException` in this file exactly as they are.

- [ ] **Step 4: Give each driver its own temporary `card` field**

The five drivers currently rely on `super(card)`. Until each is migrated (Tasks 3-7), each must hold its own field. In EACH of `lib/src/tag/{type2,mifare_classic,felica,iso_dep,iso_b}.dart`, change the constructor from `Type2Tag(super.card);` (or equivalent) to an explicit field. E.g. for `type2.dart`:

```dart
class Type2Tag extends TagDriver {
  final CcidCard card;

  const Type2Tag(this.card);
```

and add `import '../nfc_hub_base.dart';` if not already present. Do the same for the other four, preserving each class's existing extra constructor params (`TypeBTag(super.card, this.atqb)` becomes `TypeBTag(this.card, this.atqb)`).

This is scaffolding that Tasks 3-7 each delete one file at a time. It exists only so this task leaves a green build.

- [ ] **Step 5: Verify**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter analyze
flutter test 2>&1 | tail -1
```

Expected: analyze clean (2 pre-existing lints), `All tests passed!` with 84. Nothing changed behaviorally — this is declarations plus a field relocation.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add per-technology transport interfaces

Declares Type2Transport, MifareClassicTransport, NfcFTransport,
IsoDepTransport, NfcBTransport, and TagLostException. Drops the CcidCard
field from TagDriver; each driver temporarily holds its own until it is
migrated onto its transport."
```

---

### Task 2: CCID transport backend (byte-exactness is the whole point)

Implements all five transports over a `CcidCard`, relocating today's pseudo-APDUs verbatim. **This is the highest-risk task in the plan.** Every byte here is hardware-validated; a single wrong nibble silently breaks a read path that no unit test currently covers.

Written TDD: the tests assert the exact APDU hex string sent for every operation, so the byte sequences are pinned by a test before the implementation exists.

**Files:**
- Create: `lib/src/transport/ccid_backend.dart`
- Create: `test/transport/ccid_backend_test.dart`

**Interfaces:**
- Consumes: the five interfaces from Task 1; `CcidCard` from `lib/src/nfc_hub_base.dart`; `stripAndCheckSw`/`transceiveChecked` from `lib/src/apdu.dart`.
- Produces: `CcidTransportBackend`, constructed as `CcidTransportBackend(card)`, exposing:
  - `Type2Transport type2()` — **sync**, needs no round-trip
  - `NfcFTransport nfcF()` — **sync**, idm/pmm are fetched lazily by the transport itself
  - `Future<MifareClassicTransport> mifareClassic()` — **async**: must poll (PN532 `InListPassiveTarget`) for ATQA/SAK/UID, because the interface exposes those as sync getters
  - `Future<IsoDepTransport> isoDep()` — **async**, polls for the UID
  - `Future<NfcBTransport?> nfcB()` — **async**, null if no Type B target answers

  Sync vs. async here is load-bearing for Tasks 3-8: `await` the last three, do NOT
  `await` the first two. Task 8's `identifyTag` is the only consumer.

**THE EXACT APDUs — copy these verbatim, do not retype from memory:**

| Operation | APDU |
|---|---|
| Type2 `readUid`, FeliCa `idm` | `FFCA000000` |
| Type2 `readCapabilityContainer` | `FFB0000304` |
| Type2 `readPages(p)` | `FFB000${p as 2-hex}10` |
| Type2 `getVersion` | `FF0000000160` |
| MIFARE load key | `FF8200${slot 2-hex}06${key 12-hex UPPERCASE}` |
| MIFARE general auth | `FF860000050100${block 2-hex}${60 or 61}${slot 2-hex}` |
| MIFARE `readBlock(b)` | `FFB000${b as 2-hex}10` |
| Any escape command | `FF000000${Lc 2-hex}${payload hex}`, uppercased |
| PN532 poll Type A | escape payload `D44A0100` |
| PN532 poll Type B | escape payload `D44A0103` |
| FeliCa frame | escape payload `D44001` + `[len+1, ...frame]` |

(`60` = key A, `61` = key B. Slot is always `00`.)

- [ ] **Step 1: Write the failing byte-exactness tests**

Create `test/transport/ccid_backend_test.dart`. The fake platform records every C-APDU it is asked to send, so the tests assert on the exact wire bytes.

```dart
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/transport/ccid_backend.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// Records every C-APDU sent and replies from a scripted map.
class _FakePlatform extends NfcHubPlatform {
  _FakePlatform(this.responses) : super();

  final Map<String, String> responses;
  final List<String> sent = [];

  @override
  Future<List<String>> listReaders() async => ['fake'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}

  @override
  Future<String?> transceive(String reader, String capdu) async {
    sent.add(capdu.toUpperCase());
    return responses[capdu.toUpperCase()];
  }
}

void main() {
  late _FakePlatform platform;

  void install(Map<String, String> responses) {
    platform = _FakePlatform(responses);
    NfcHubPlatform.instance = platform;
  }

  tearDown(() => NfcHubPlatform.instance = null);

  group('Type2 transport', () {
    test('readUid sends the PC/SC Get Data pseudo-APDU', () async {
      install({'FFCA000000': '04AABBCCDDEEFF9000'});
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      final uid = await t.readUid();

      expect(platform.sent, ['FFCA000000']);
      expect(uid, Uint8List.fromList([0x04, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]));
    });

    test('readCapabilityContainer reads 4 bytes at page 3 (Le=04, NOT 10)',
        () async {
      install({'FFB0000304': 'E1106D009000'});
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      final cc = await t.readCapabilityContainer();

      expect(platform.sent, ['FFB0000304']);
      expect(cc, Uint8List.fromList([0xE1, 0x10, 0x6D, 0x00]));
    });

    test('readPages sends a 5-byte READ BINARY with P2 = the page number',
        () async {
      // Regression guard: the historical bug here was 'FFB00000${page}10',
      // a 6-byte APDU with P2 stuck at 00, so every page read returned page 0.
      install({'FFB0000410': '${'11' * 16}9000'});
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      final page = await t.readPages(4);

      expect(platform.sent, ['FFB0000410']);
      expect(page.length, 16);
    });

    test('getVersion sends the escape-wrapped GET_VERSION and returns 8 bytes',
        () async {
      install({'FF0000000160': '0004030101000B039000'});
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      final v = await t.getVersion();

      expect(platform.sent, ['FF0000000160']);
      expect(v!.length, 8);
    });

    test('getVersion returns null (does not throw) when unsupported',
        () async {
      install({'FF0000000160': '6A81'}); // not 9000
      final t = CcidTransportBackend(CcidCard('fake')).type2();

      expect(await t.getVersion(), isNull);
    });
  });

  group('MifareClassic transport', () {
    // ATQA 0400, SAK 08, UID 04AABBCC -- an InListPassiveTarget reply.
    const pollA = 'D54B01010004080404AABBCC9000';

    test('authenticate loads the key then general-authenticates the block',
        () async {
      install({
        'FF00000004D44A0100': pollA,
        'FF82000006FFFFFFFFFFFF': '9000',
        'FF860000050100046000': '9000',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();
      platform.sent.clear();

      await t.authenticate(
        1, // sector 1 -> block 4
        MifareKeyType.a,
        Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]),
      );

      expect(platform.sent, [
        // Load Key: slot 00, 6-byte key, UPPERCASE hex.
        'FF82000006FFFFFFFFFFFF',
        // General Authenticate: block 04, key A (60), slot 00.
        // 10 bytes: FF 86 00 00 Lc=05 | 01 00 04 60 00 (5 data bytes).
        'FF860000050100046000',
      ]);
    });

    test('readBlock sends READ BINARY with P2 = the block number', () async {
      install({
        'FF00000004D44A0100': pollA,
        'FFB0000410': '${'22' * 16}9000',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();
      platform.sent.clear();

      final block = await t.readBlock(4);

      expect(platform.sent, ['FFB0000410']);
      expect(block.length, 16);
    });

    test('identity fields come from the PN532 poll, not the ATR', () async {
      install({'FF00000004D44A0100': pollA});
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();

      expect(t.sak, 0x08);
      expect(t.atqa, Uint8List.fromList([0x00, 0x04]));
      expect(t.uid, Uint8List.fromList([0x04, 0xAA, 0xBB, 0xCC]));
    });

    test('authenticate throws MifareAuthException when the key is rejected',
        () async {
      install({
        'FF00000004D44A0100': pollA,
        'FF82000006FFFFFFFFFFFF': '6300', // rejected
      });
      final t = await CcidTransportBackend(CcidCard('fake')).mifareClassic();

      expect(
        () => t.authenticate(0, MifareKeyType.a,
            Uint8List.fromList([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])),
        throwsA(isA<MifareAuthException>()),
      );
    });
  });

  group('NfcF transport', () {
    test('transceive wraps the frame in PN532 InDataExchange and strips D541',
        () async {
      // Request System Code (0x0C) + 8-byte IDm = 9-byte frame.
      // Framed: [0x0A, 0x0C, idm...]  ->  payload D4 40 01 0A 0C <idm>
      // Lc = 3 + 10 = 13 = 0x0D.
      const idm = '0102030405060708';
      const capdu = 'FF0000000DD440010A0C$idm';
      install({capdu: 'D541000D0D${idm}0190E39000'});
      final t = CcidTransportBackend(CcidCard('fake')).nfcF();

      final frame = Uint8List.fromList([
        0x0C, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
      ]);
      final response = await t.transceive(frame);

      expect(platform.sent, [capdu]);
      // The D5 41 00 InDataExchange header is stripped; the raw FeliCa
      // response frame (length byte included) comes back.
      expect(response[0], 0x0D);
      expect(response[1], 0x0D); // Request System Code response code
    });

    test('idm reads via Get UID (the reader returns the FeliCa IDm)',
        () async {
      install({'FFCA000000': '01020304050607089000'});
      final t = CcidTransportBackend(CcidCard('fake')).nfcF();

      expect(await t.idm, Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]));
      expect(platform.sent, ['FFCA000000']);
    });
  });

  group('IsoDep transport', () {
    test('transceive passes the APDU straight through, SW included', () async {
      install({
        'FF00000004D44A0100': 'D54B01010004200404AABBCC9000',
        '00A4040000': '6A82',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).isoDep();
      platform.sent.clear();

      final r = await t.transceive(Uint8List.fromList([0, 0xA4, 4, 0, 0]));

      expect(platform.sent, ['00A4040000']);
      // SW is NOT stripped -- DESFire native mode has no SW at all.
      expect(r, Uint8List.fromList([0x6A, 0x82]));
    });

    test('historicalBytes is the card ATR', () async {
      install({'FF00000004D44A0100': 'D54B01010004200404AABBCC9000'});
      final atr = Uint8List.fromList([0x3B, 0x8F, 0x80]);
      final t = await CcidTransportBackend(CcidCard('fake', atr: atr)).isoDep();

      expect(t.historicalBytes, atr);
    });
  });

  group('NfcB transport', () {
    test('nfcB() returns null when no Type B target answers', () async {
      install({'FF00000004D44A0103': 'D54B009000'}); // NbTg = 0
      final t = await CcidTransportBackend(CcidCard('fake')).nfcB();

      expect(t, isNull);
    });

    test('pupi is bytes 1-4 of ATQB', () async {
      // ATQB: 50 | PUPI(11223344) | AppData(4) | ProtocolInfo(3)
      // ATQB = 50 | PUPI(11223344) | AppData(AABBCCDD) | ProtocolInfo(010203)
      install({
        'FF00000004D44A0103':
            'D54B01015011223344AABBCCDD010203009000',
      });
      final t = await CcidTransportBackend(CcidCard('fake')).nfcB();

      expect(t!.pupi, Uint8List.fromList([0x11, 0x22, 0x33, 0x44]));
      expect(t.atqb.length, 12);
    });
  });
}
```

- [ ] **Step 2: Run the tests to confirm they fail**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test test/transport/ccid_backend_test.dart
```

Expected: FAIL — `ccid_backend.dart` doesn't exist yet (`Target of URI doesn't exist`).

- [ ] **Step 3: Implement `lib/src/transport/ccid_backend.dart`**

Move the logic — do not reinvent it. Read the current implementations first and copy their APDU strings character for character:
- `lib/src/tag/type2.dart` — `readUid`, `readCapabilityContainer`, `_readPagesFrom`, `readChipVersion`
- `lib/src/tag/mifare_classic.dart` — `_loadKey`, `_generalAuthenticate`, `readBlock`
- `lib/src/tag/felica.dart` — `_transceiveFelicaFrame`, `idm`, `pmm`
- `lib/src/apdu.dart` — `transceiveEscape`, `transceiveChecked`, `stripAndCheckSw`
- `lib/src/pn532.dart` — `pollTypeA`, `pollTypeB`, `_inListPassiveTarget`

```dart
import 'dart:typed_data';

import 'package:convert/convert.dart';

import '../apdu.dart';
import '../nfc_hub_base.dart';
import '../pn532.dart';
import '../tag/mifare_classic.dart' show MifareKeyType, MifareAuthException;
import 'transport.dart';

/// Builds typed transports over a card connected through a CCID / PC-SC
/// reader. This is the ONLY place the ACR122U's PC/SC pseudo-APDU and
/// PN532 escape dialect lives; drivers above it are transport-agnostic.
class CcidTransportBackend {
  final CcidCard card;

  CcidTransportBackend(this.card);

  Type2Transport type2() => _CcidType2Transport(card);

  NfcFTransport nfcF() => _CcidNfcFTransport(card);

  /// Async: must poll the card (PN532 InListPassiveTarget) for ATQA/SAK/UID.
  Future<MifareClassicTransport> mifareClassic() async {
    final target = await pollTypeA(card);
    if (target == null) {
      throw const TagLostException('No Type A target answered the poll');
    }
    return _CcidMifareClassicTransport(card, target);
  }

  /// Async: polls for the UID.
  Future<IsoDepTransport> isoDep() async {
    final target = await pollTypeA(card);
    return _CcidIsoDepTransport(card, target?.uid ?? Uint8List(0));
  }

  /// Null if no Type B target answers.
  Future<NfcBTransport?> nfcB() async {
    final target = await pollTypeB(card);
    if (target == null) return null;
    return _CcidNfcBTransport(card, target.atqb);
  }
}

String _hex2(int v) => v.toRadixString(16).padLeft(2, '0');

class _CcidType2Transport implements Type2Transport {
  final CcidCard card;

  _CcidType2Transport(this.card);

  @override
  Future<Uint8List> readUid() => transceiveChecked(card, 'FFCA000000');

  @override
  Future<Uint8List> readCapabilityContainer() async {
    final bytes = await transceiveChecked(card, 'FFB0000304');
    if (bytes.length != 4) {
      throw Exception('Failed to read Capability Container (expected 4 '
          'bytes, got ${bytes.length})');
    }
    return bytes;
  }

  @override
  Future<Uint8List> readPages(int startPage) =>
      transceiveChecked(card, 'FFB000${_hex2(startPage)}10');

  @override
  Future<Uint8List?> getVersion() async {
    try {
      final data = stripAndCheckSw(await card.transceive('FF0000000160'));
      if (data == null || data.length != 8) return null;
      return data;
    } catch (_) {
      return null;
    }
  }
}

class _CcidMifareClassicTransport implements MifareClassicTransport {
  final CcidCard card;
  final PassiveTargetTypeA target;

  static const int _keySlot = 0x00;

  _CcidMifareClassicTransport(this.card, this.target);

  @override
  Uint8List get uid => target.uid;

  @override
  Uint8List get atqa => target.atqa;

  @override
  int get sak => target.sak;

  @override
  Future<void> authenticate(
      int sector, MifareKeyType type, Uint8List key) async {
    if (key.length != 6) {
      throw ArgumentError('MIFARE Classic keys are 6 bytes, got ${key.length}');
    }
    final keyHex = hex.encode(key).toUpperCase();
    final slotHex = _hex2(_keySlot);
    final loadResponse = await card.transceive('FF8200${slotHex}06$keyHex');
    if (stripAndCheckSw(loadResponse) == null) {
      throw const MifareAuthException('Failed to load key into reader');
    }

    final block = sector * 4;
    final blockHex = _hex2(block);
    final keyTypeHex = type == MifareKeyType.a ? '60' : '61';
    final authResponse =
        await card.transceive('FF860000050100$blockHex$keyTypeHex$slotHex');
    if (stripAndCheckSw(authResponse) == null) {
      throw MifareAuthException('Authentication failed for block $block');
    }
  }

  @override
  Future<Uint8List> readBlock(int block) =>
      transceiveChecked(card, 'FFB000${_hex2(block)}10');
}

class _CcidNfcFTransport implements NfcFTransport {
  final CcidCard card;

  Uint8List? _idm;
  Uint8List? _pmm;

  _CcidNfcFTransport(this.card);

  @override
  Future<Uint8List> get idm async {
    final cached = _idm;
    if (cached != null) return cached;
    final read = await transceiveChecked(card, 'FFCA000000');
    _idm = read;
    return read;
  }

  @override
  Future<Uint8List> get pmm async {
    final cached = _pmm;
    if (cached != null) return cached;
    final response = await transceive(Uint8List.fromList([
      0x00, // Polling
      0xFF, 0xFF, // wildcard system code
      0x00, // request code: none
      0x00, // time slot
    ]));
    // length(1) | responseCode(1)=0x01 | idm(8) | pmm(8)
    if (response.length < 18) {
      throw Exception(
          'FeliCa polling response too short (${response.length} bytes)');
    }
    final read = Uint8List.sublistView(response, 10, 18);
    _pmm = read;
    return read;
  }

  @override
  Future<Uint8List> transceive(Uint8List felicaFrame) async {
    final framed =
        Uint8List.fromList([felicaFrame.length + 1, ...felicaFrame]);
    final payload = Uint8List.fromList([0xD4, 0x40, 0x01, ...framed]);

    final response = await transceiveEscape(card, payload);
    if (response.length < 3 || response[0] != 0xD5 || response[1] != 0x41) {
      throw Exception(
          'Unexpected InDataExchange response header: ${hex.encode(response)}');
    }
    if (response[2] != 0x00) {
      throw Exception('InDataExchange failed with status '
          '0x${_hex2(response[2])}');
    }
    return Uint8List.sublistView(response, 3);
  }
}

class _CcidIsoDepTransport implements IsoDepTransport {
  final CcidCard card;
  final Uint8List _uid;

  _CcidIsoDepTransport(this.card, this._uid);

  @override
  Future<Uint8List> get uid async => _uid;

  @override
  Uint8List? get historicalBytes => card.atr;

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    final responseHex = await card.transceive(hex.encode(apdu).toUpperCase());
    if (responseHex == null || responseHex.isEmpty) {
      throw Exception('No response to APDU ${hex.encode(apdu)}');
    }
    return Uint8List.fromList(hex.decode(responseHex));
  }
}

class _CcidNfcBTransport implements NfcBTransport {
  final CcidCard card;

  @override
  final Uint8List atqb;

  _CcidNfcBTransport(this.card, this.atqb);

  @override
  Uint8List get pupi => Uint8List.sublistView(atqb, 1, 5);

  @override
  Future<Uint8List> transceive(Uint8List apdu) async {
    final responseHex = await card.transceive(hex.encode(apdu).toUpperCase());
    if (responseHex == null || responseHex.isEmpty) {
      throw Exception('No response to APDU ${hex.encode(apdu)}');
    }
    return Uint8List.fromList(hex.decode(responseHex));
  }
}
```

- [ ] **Step 4: Run the tests to confirm they pass**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test test/transport/ccid_backend_test.dart
flutter test 2>&1 | tail -1
```

Expected: the new file's tests pass; the full suite is 84 + the new tests, 0 failing.

- [ ] **Step 5: Diff the APDU strings against the originals — do not skip this**

The whole plan hinges on these bytes surviving. Prove it mechanically rather than by eye:

```bash
cd /Users/akashshahriar/StudioProjects/ccid
echo "--- APDU literals in the NEW backend ---"
grep -oE "'FF[0-9A-F$_{}a-zA-Z()]*'" lib/src/transport/ccid_backend.dart | sort -u
echo "--- APDU literals in the OLD drivers ---"
grep -ohE "'FF[0-9A-F$_{}a-zA-Z()]*'" lib/src/tag/type2.dart lib/src/tag/mifare_classic.dart lib/src/apdu.dart | sort -u
```

Every literal in the old set must have an identical counterpart in the new set (modulo the local variable name inside `${...}`). If any differs by even one character, STOP and fix it.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add CcidTransportBackend implementing all five transports

Relocates the hardware-validated PC/SC pseudo-APDUs and PN532 escape dialect
out of the drivers and into one backend. Adds byte-exactness tests pinning
every C-APDU on the wire, including a regression guard for the historical
'FFB00000<page>10' malformed-READ-BINARY bug."
```

---

### Task 3: Migrate `Type2Tag` onto `Type2Transport`

**Files:**
- Modify: `lib/src/tag/type2.dart`
- Modify: `lib/src/tag/detection.dart` (its `Type2Tag(...)` construction sites)
- Modify: `test/tag/type2_test.dart`, `test/nfc_hub_test.dart` (whichever construct `Type2Tag`)

**Interfaces:**
- Consumes: `Type2Transport` (Task 1), `CcidTransportBackend.type2()` (Task 2).
- Produces: `Type2Tag(Type2Transport transport)`. Its public methods (`readNdef`, `readUid`, `readTagInfo`, `readCapabilityContainer`, `readMemoryDump`, `readChipVersion`) keep their exact current signatures.

- [ ] **Step 1: Rewrite `Type2Tag` against the transport**

Replace the `card` field with `final Type2Transport transport;`, and reroute each method. The page-walking loop stays in the driver (it's tag logic, not transport logic); only the single-read primitive moves.

```dart
class Type2Tag extends TagDriver {
  final Type2Transport transport;

  const Type2Tag(this.transport);

  Future<List<NdefRecord>> readNdef() async {
    final cc = await readCapabilityContainer();
    if (!cc.isNdefFormatted) {
      throw Exception(
          'Tag does not contain NDEF data (no capability container found)');
    }
    final data = await _readPagesFrom(4, maxBytes: cc.dataAreaSize);
    final message = parseTlvForNdefMessage(data);
    if (message == null) {
      throw Exception('No NDEF message found on tag');
    }
    return parseNdefRecords(message);
  }

  Future<Uint8List> readUid() => transport.readUid();

  @override
  Future<Type2TagInfo> readTagInfo() async {
    final tagUid = await readUid();
    CapabilityContainer? cc;
    try {
      cc = await readCapabilityContainer();
    } catch (_) {
      // best-effort; leave cc null
    }
    return Type2TagInfo(
      technology: 'NFC Forum Type 2 (MIFARE Ultralight/NTAG)',
      uid: tagUid,
      atr: null,
      capabilityContainer: cc,
    );
  }

  Future<CapabilityContainer> readCapabilityContainer() async {
    return CapabilityContainer.parse(await transport.readCapabilityContainer());
  }

  Future<Uint8List> readMemoryDump() => _readPagesFrom(0);

  Future<ChipVersion?> readChipVersion() async {
    final data = await transport.getVersion();
    return data == null ? null : ChipVersion.parse(data);
  }

  Future<Uint8List> _readPagesFrom(int startPage, {int? maxBytes}) async {
    final buffer = BytesBuilder();
    var page = startPage;
    while ((maxBytes == null || buffer.length < maxBytes) && page <= 0xFF) {
      Uint8List chunk;
      try {
        chunk = await transport.readPages(page);
      } catch (_) {
        break;
      }
      buffer.add(chunk);
      page += 4;
    }
    return buffer.toBytes();
  }
}
```

**Note the `atr: null`.** `Type2TagInfo.atr` used to come from `card.atr`. The transport doesn't expose an ATR (only `IsoDepTransport` does — it's an ISO-DEP concept). Task 8 restores it: `identifyTag` knows the `CcidCard` and can pass the ATR in. For now, pass `null` — the field is already nullable and documented as "null on platforms that don't surface it".

- [ ] **Step 2: Update the construction sites**

In `lib/src/tag/detection.dart`, wherever `Type2Tag(card)` appears, build the backend once at the top of `identifyTag` and pass the transport:

```dart
final backend = CcidTransportBackend(card);
// ...
return Type2Tag(backend.type2());
```

The probing path also reads the CC directly via `_tryTransceive(card, 'FFB0000304')` — leave that as-is for now (Task 8 tidies detection); it's a probe, not a driver read.

- [ ] **Step 3: Update the tests**

`test/tag/type2_test.dart` (and `test/nfc_hub_test.dart` if it constructs `Type2Tag`) currently fake at the `NfcHubPlatform` level. Add a fake transport instead — it makes the tests shorter and independent of the CCID dialect:

```dart
class _FakeType2Transport implements Type2Transport {
  _FakeType2Transport({this.uid, this.cc, this.pages = const {}, this.version});

  final Uint8List? uid;
  final Uint8List? cc;
  final Map<int, Uint8List> pages;
  final Uint8List? version;

  @override
  Future<Uint8List> readUid() async =>
      uid ?? (throw Exception('no uid scripted'));

  @override
  Future<Uint8List> readCapabilityContainer() async =>
      cc ?? (throw Exception('no CC scripted'));

  @override
  Future<Uint8List> readPages(int startPage) async =>
      pages[startPage] ?? (throw Exception('page $startPage not scripted'));

  @override
  Future<Uint8List?> getVersion() async => version;
}
```

Keep every existing `expect(...)` assertion's expected VALUE identical — only the setup changes. If an assertion's expected value needs to change, STOP: that means behavior drifted.

- [ ] **Step 4: Verify**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter analyze
flutter test 2>&1 | tail -1
```

Expected: analyze clean, all tests pass, count >= 84.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: migrate Type2Tag onto Type2Transport"
```

---

### Task 4: Migrate `MifareClassicTag` onto `MifareClassicTransport`

**Files:**
- Modify: `lib/src/tag/mifare_classic.dart`
- Modify: `lib/src/tag/detection.dart`
- Modify: `test/tag/mifare_classic_test.dart`

**Interfaces:**
- Consumes: `MifareClassicTransport` (Task 1), `CcidTransportBackend.mifareClassic()` (Task 2, **async**).
- Produces: `MifareClassicTag(MifareClassicTransport transport)`. Public methods `authenticate`, `authenticateWithDefaultKeys`, `readBlock`, `readSector`, `readTagInfo` keep their signatures.

- [ ] **Step 1: Rewrite the driver**

The `_loadKey`/`_generalAuthenticate` pseudo-APDU pair moved into the backend in Task 2 — delete them here. The default-key list and the sector→block arithmetic are tag logic and stay.

```dart
class MifareClassicTag extends TagDriver {
  final MifareClassicTransport transport;

  const MifareClassicTag(this.transport);

  static const List<String> _defaultKeysHex = [
    'FFFFFFFFFFFF',
    'A0A1A2A3A4A5',
    'D3F7D3F7D3F7',
    '000000000000',
  ];

  Future<void> authenticate(
    int sector,
    MifareKeyType keyType,
    Uint8List key,
  ) =>
      transport.authenticate(sector, keyType, key);

  Future<void> authenticateWithDefaultKeys(int sector) async {
    for (final keyHex in _defaultKeysHex) {
      try {
        await authenticate(
          sector,
          MifareKeyType.a,
          Uint8List.fromList(hex.decode(keyHex)),
        );
        return;
      } on MifareAuthException {
        continue;
      }
    }
    throw MifareAuthException(
      'None of the default keys authenticated sector $sector',
    );
  }

  Future<Uint8List> readBlock(int block) => transport.readBlock(block);

  Future<List<Uint8List>> readSector(int sector) async {
    final firstBlock = sector * 4;
    final blocks = <Uint8List>[];
    for (var block = firstBlock; block < firstBlock + 4; block++) {
      blocks.add(await readBlock(block));
    }
    return blocks;
  }

  @override
  Future<MifareClassicInfo> readTagInfo() async {
    final family = mifareFamilyFromSak(transport.sak);
    return MifareClassicInfo(
      technology: mifareFamilyLabel(family),
      uid: transport.uid,
      atr: null, // restored by identifyTag in Task 8
      sak: transport.sak,
      atqa: transport.atqa,
    );
  }
}
```

Note `readTagInfo` no longer polls — the transport already carries `uid`/`sak`/`atqa` from the poll the backend did when it was built. That removes a redundant round-trip; it is not a behavior change to the wire (the same poll happens, once, earlier).

- [ ] **Step 2: Update `detection.dart`**

`identifyTag`'s ATR path and its probing path both construct `MifareClassicTag(card)`. Both now need `await backend.mifareClassic()`. The probing path calls `mifare.authenticateWithDefaultKeys(0)` inside a try/catch — that still works, but building the transport can now itself throw `TagLostException` if no Type A target answers. Wrap the construction in the same try/catch so a FeliCa card (which won't answer a Type A poll) still falls through to the FeliCa probe rather than aborting detection:

```dart
try {
  final mifare = MifareClassicTag(await backend.mifareClassic());
  await mifare.authenticateWithDefaultKeys(0);
  return mifare;
} catch (e) {
  log.add('MIFARE default-key auth -> failed: $e');
}
```

This preserves the existing behavior exactly — the current code already catches broadly here (commit `19c2943` widened it for precisely this reason).

- [ ] **Step 3: Update `test/tag/mifare_classic_test.dart`** with a `_FakeMifareClassicTransport` (records `authenticate` calls, returns scripted blocks, exposes fixed uid/atqa/sak). Keep every existing assertion's expected value identical.

- [ ] **Step 4: Verify**

```bash
flutter analyze && flutter test 2>&1 | tail -1
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: migrate MifareClassicTag onto MifareClassicTransport"
```

---

### Task 5: Migrate `FelicaTag` onto `NfcFTransport`

**Files:**
- Modify: `lib/src/tag/felica.dart`
- Modify: `lib/src/tag/detection.dart`
- Modify: `test/tag/felica_test.dart`

**Interfaces:**
- Consumes: `NfcFTransport` (Task 1), `CcidTransportBackend.nfcF()` (Task 2, sync).
- Produces: `FelicaTag(NfcFTransport transport)`. `idm`, `pmm`, `readWithoutEncryption`, `requestSystemCodes`, `readTagInfo` keep their signatures.

- [ ] **Step 1: Rewrite the driver**

`_transceiveFelicaFrame` (the `D4 40 01` wrapping) and the `idm`/`pmm` caching moved into the backend in Task 2. Delete them here. What remains is pure FeliCa frame construction and response parsing — genuinely tag logic.

```dart
class FelicaTag extends TagDriver {
  final NfcFTransport transport;

  const FelicaTag(this.transport);

  Future<Uint8List> get idm => transport.idm;

  Future<Uint8List> get pmm => transport.pmm;

  @override
  Future<FelicaInfo> readTagInfo() async {
    final cardIdm = await idm;
    final cardPmm = await pmm;
    final model = felicaModelName(cardPmm);
    var systemCodes = <int>[];
    try {
      systemCodes = await requestSystemCodes();
    } catch (_) {
      // best-effort; leave systemCodes empty
    }
    return FelicaInfo(
      technology: model == null ? 'FeliCa' : 'FeliCa ($model)',
      uid: cardIdm,
      atr: null, // restored by identifyTag in Task 8
      pmm: cardPmm,
      modelName: model,
      systemCodes: systemCodes,
    );
  }

  Future<FelicaReadResult> readWithoutEncryption(
    int serviceCode,
    List<int> blockList,
  ) async {
    final cardIdm = await idm;
    final frame = BytesBuilder();
    frame.addByte(0x06); // Read Without Encryption
    frame.add(cardIdm);
    frame.addByte(0x01); // number of service codes
    frame.addByte(serviceCode & 0xFF); // little-endian
    frame.addByte((serviceCode >> 8) & 0xFF);
    frame.addByte(blockList.length);
    for (final block in blockList) {
      frame.addByte(0x80); // 2-byte block list element
      frame.addByte(block & 0xFF);
    }
    final response = await transport.transceive(frame.toBytes());

    // length(1) | responseCode(1)=0x07 | idm(8) | SF1(1) | SF2(1) |
    // numBlocks(1) | blocks(16 each)
    if (response.length < 12) {
      throw Exception(
          'FeliCa read response too short (${response.length} bytes)');
    }
    final statusFlag1 = response[10];
    final statusFlag2 = response[11];
    final blocks = <Uint8List>[];
    if (statusFlag1 == 0x00 && statusFlag2 == 0x00) {
      final numBlocks = response.length > 12 ? response[12] : 0;
      var offset = 13;
      for (var i = 0; i < numBlocks && offset + 16 <= response.length; i++) {
        blocks.add(Uint8List.sublistView(response, offset, offset + 16));
        offset += 16;
      }
    }
    return FelicaReadResult(
      statusFlag1: statusFlag1,
      statusFlag2: statusFlag2,
      blocks: blocks,
    );
  }

  Future<List<int>> requestSystemCodes() async {
    final cardIdm = await idm;
    final response =
        await transport.transceive(Uint8List.fromList([0x0C, ...cardIdm]));
    // length(1) | responseCode(1)=0x0D | idm(8) | numSystems(1) | codes(2 each)
    if (response.length < 11) {
      throw Exception('Request System Code response too short '
          '(${response.length} bytes)');
    }
    final numSystems = response[10];
    final systemCodes = <int>[];
    var offset = 11;
    for (var i = 0; i < numSystems && offset + 2 <= response.length; i++) {
      systemCodes.add((response[offset] << 8) | response[offset + 1]);
      offset += 2;
    }
    return systemCodes;
  }
}
```

**Every byte offset above must match the current file exactly.** Compare them side by side — `response[10]`/`response[11]`, the `offset = 13`, the `16`-byte block stride, the `<< 8` big-endian system-code assembly. These were derived from real MRT card traces.

- [ ] **Step 2: Update `detection.dart`** — `FelicaTag(card)` → `FelicaTag(backend.nfcF())`.

- [ ] **Step 3: Update `test/tag/felica_test.dart`** with a `_FakeNfcFTransport` that records the frames handed to `transceive` and returns scripted response frames. The existing test fixtures are raw response frames WITH the `D5 41 00` InDataExchange prefix — that prefix is now the backend's business, so **strip it** from the fixtures the fake returns (the fake sits above that layer). This is the one place a fixture legitimately changes shape; the underlying assertion values must not.

- [ ] **Step 4: Verify**

```bash
flutter analyze && flutter test 2>&1 | tail -1
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: migrate FelicaTag onto NfcFTransport"
```

---

### Task 6: Migrate `IsoDepTag` onto `IsoDepTransport`

**Files:**
- Modify: `lib/src/tag/iso_dep.dart`
- Modify: `lib/src/tag/detection.dart`
- Modify: `test/tag/iso_dep_test.dart`

**Interfaces:**
- Consumes: `IsoDepTransport` (Task 1), `CcidTransportBackend.isoDep()` (Task 2, **async**).
- Produces: `IsoDepTag(IsoDepTransport transport)`. `selectApplication(String aidHex)`, `transceive(String capdu)`, `readDesfireVersion()`, `readTagInfo()` keep their signatures — note `selectApplication`/`transceive` keep their **hex-String** signatures for API compatibility even though the transport is bytes; convert inside.

- [ ] **Step 1: Rewrite the driver**

The critical subtlety, preserved verbatim from the current code: `_desfireFrame` must NOT strip a status word. Native-mode DESFire responses carry no PC/SC SW — byte 0 is DESFire's own continuation status (`0xAF` = more frames, `0x00` = last). `IsoDepTransport.transceive` returns the raw response including any SW, which is exactly what this needs.

```dart
class IsoDepTag extends TagDriver {
  final IsoDepTransport transport;

  const IsoDepTag(this.transport);

  Future<String?> selectApplication(String aidHex) {
    final lcHex = (aidHex.length ~/ 2).toRadixString(16).padLeft(2, '0');
    return transceive('00A40400$lcHex$aidHex');
  }

  Future<String?> transceive(String capdu) async {
    final response =
        await transport.transceive(Uint8List.fromList(hex.decode(capdu)));
    return hex.encode(response).toUpperCase();
  }

  @override
  Future<IsoDepInfo> readTagInfo() async {
    final tagUid = await transport.uid;
    DesfireVersion? version;
    try {
      version = await readDesfireVersion();
    } catch (_) {
      // best-effort; leave version null
    }
    final technology = version == null
        ? 'ISO14443-4 (generic)'
        : 'ISO14443-4: ${desfireGenerationLabel(version)}';
    return IsoDepInfo(
      technology: technology,
      uid: tagUid,
      atr: transport.historicalBytes,
      desfireVersion: version,
    );
  }

  // readDesfireVersion(): copy the body from the CURRENT lib/src/tag/iso_dep.dart
  // verbatim. Do not retype it. It performs the three-frame 60/AF/AF exchange,
  // asserts hwFrame[0]==0xAF, swFrame[0]==0xAF, tailFrame[0]==0x00, checks the
  // lengths (hw==7, sw==7, tail==14), and maps the 18 DesfireVersion fields in
  // order. Every offset was verified against ACS's documented worked example --
  // a single shifted index silently corrupts the decoded chip generation.
  // The ONLY change is that it calls the _desfireFrame below, which now goes
  // through the transport instead of card.transceive.
  Future<DesfireVersion> readDesfireVersion() async { /* see note above */ }

  Future<Uint8List> _desfireFrame(String capdu) async {
    final response =
        await transport.transceive(Uint8List.fromList(hex.decode(capdu)));
    if (response.isEmpty) {
      throw Exception('No response to DESFire command $capdu');
    }
    return response;
  }
}
```

Copy `readDesfireVersion`'s body across **unchanged** — its three-frame `60`/`AF`/`AF` exchange and all its length checks (`hw.length != 7`, `sw.length != 7`, `tail.length != 14`) and field offsets were verified against ACS's documented worked example.

Note `IsoDepInfo.atr` DOES survive here (`transport.historicalBytes`) — unlike the other four drivers, ISO-DEP genuinely has this concept.

- [ ] **Step 2: Update `detection.dart`** — `IsoDepTag(card)` → `IsoDepTag(await backend.isoDep())` (both the ATR path and the probing path).

- [ ] **Step 3: Update `test/tag/iso_dep_test.dart`** with a `_FakeIsoDepTransport` mapping request-hex → response-bytes. The DESFire GetVersion fixtures (the three ACS-documented frames) must be carried over byte for byte.

- [ ] **Step 4: Verify**

```bash
flutter analyze && flutter test 2>&1 | tail -1
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: migrate IsoDepTag onto IsoDepTransport"
```

---

### Task 7: Migrate `TypeBTag` onto `NfcBTransport`

The smallest of the five.

**Files:**
- Modify: `lib/src/tag/iso_b.dart`
- Modify: `lib/src/tag/detection.dart`
- Modify: `test/tag/iso_b_test.dart`

**Interfaces:**
- Consumes: `NfcBTransport` (Task 1), `CcidTransportBackend.nfcB()` (Task 2, async, **nullable**).
- Produces: `TypeBTag(NfcBTransport transport)` — note the `atqb` constructor param is GONE; it now comes from the transport.

- [ ] **Step 1: Rewrite the driver**

```dart
class TypeBTag extends TagDriver {
  final NfcBTransport transport;

  const TypeBTag(this.transport);

  Uint8List get atqb => transport.atqb;

  Future<String?> transceive(String capdu) async {
    final response =
        await transport.transceive(Uint8List.fromList(hex.decode(capdu)));
    return hex.encode(response).toUpperCase();
  }

  @override
  Future<TypeBInfo> readTagInfo() async {
    return TypeBInfo(
      uid: transport.pupi,
      atr: null, // restored by identifyTag in Task 8
      atqb: transport.atqb,
    );
  }
}
```

The PUPI extraction (`atqb[1..5]`) moved into the backend's `_CcidNfcBTransport.pupi` in Task 2 — don't duplicate it here.

- [ ] **Step 2: Update `detection.dart`**

The probing path currently does `pollTypeB(card)` then `TypeBTag(card, target.atqb)`. It becomes:

```dart
try {
  final nfcB = await backend.nfcB();
  if (nfcB != null) {
    log.add('Type B poll -> succeeded, atqb=${hex.encode(nfcB.atqb)}');
    return TypeBTag(nfcB);
  }
  log.add('Type B poll -> no target found');
} catch (e) {
  log.add('Type B poll -> failed: $e');
}
```

- [ ] **Step 3: Update `test/tag/iso_b_test.dart`** with a `_FakeNfcBTransport` exposing a fixed `atqb`/`pupi`.

- [ ] **Step 4: Verify**

```bash
flutter analyze && flutter test 2>&1 | tail -1
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: migrate TypeBTag onto NfcBTransport"
```

---

### Task 8: Restore ATR in `identifyTag`, and tidy detection

All five drivers now build from transports, but four of them lost their `atr` field (they pass `null`). `identifyTag` holds the `CcidCard` and therefore the ATR, so it can put it back — and it's the right place, because Plan 3's Android source has no ATR to give and will legitimately pass null.

**Files:**
- Modify: `lib/src/tag/detection.dart`
- Modify: `lib/src/tag/{type2,mifare_classic,felica,iso_b}.dart` (accept an optional ATR)
- Modify: `test/tag/detection_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 1-7.
- Produces: `identifyTag(CcidCard card)` — **unchanged public signature**, still returns `Future<TagDriver>`, still throws `UnrecognizedTagException` with the full probe log.

- [ ] **Step 1: Give the four drivers an optional ATR**

Each of `Type2Tag`, `MifareClassicTag`, `FelicaTag`, `TypeBTag` takes an optional `Uint8List? atr` constructor param, stored in a field, and returns it from `readTagInfo()` instead of the hardcoded `null`. E.g.:

```dart
class Type2Tag extends TagDriver {
  final Type2Transport transport;

  /// The card's ATR, where the source supplies one. Null on sources that
  /// have no ATR concept (the device's built-in NFC antenna).
  final Uint8List? atr;

  const Type2Tag(this.transport, {this.atr});
```

and in `readTagInfo()`: `atr: atr,`.

`IsoDepTag` does NOT need this — it already gets the ATR from `transport.historicalBytes`.

- [ ] **Step 2: Pass the ATR at every construction site in `detection.dart`**

```dart
Future<TagDriver> identifyTag(CcidCard card) async {
  final backend = CcidTransportBackend(card);
  final atr = card.atr;
  if (atr != null) {
    final fromAtr = await _identifyFromAtr(backend, atr);
    if (fromAtr != null) return fromAtr;
  }
  return _identifyByProbing(backend, card, atr);
}
```

with e.g. `return Type2Tag(backend.type2(), atr: atr);` inside. `_identifyFromAtr` becomes `async` (the MIFARE and ISO-DEP branches now await their transports).

Keep the ATR-matching logic (the PC/SC RID `A0 00 00 03 06` discrimination, the C0/C1 card-name bytes, the fallback heuristics) **byte-for-byte identical** — it was corrected twice against real hardware (commits `dd4d911`, `5cf5d4a`) and is the most-bugged function in this codebase.

Likewise keep `_identifyByProbing`'s probe ORDER and its `log` messages identical: Get UID → Read CC → SELECT → MIFARE → FeliCa → Type B, with every probe running regardless of earlier failures (commit `8b134f5` fixed exactly this — a failing Get UID must not short-circuit the FeliCa probe).

- [ ] **Step 3: Verify the existing detection tests pass unchanged**

`test/tag/detection_test.dart` fakes at the `NfcHubPlatform` level, so it exercises the whole stack (identifyTag → backend → pseudo-APDUs). It should pass **without changing a single assertion**. That is the strongest evidence this refactor preserved behavior.

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter test test/tag/detection_test.dart
```

If any assertion needs editing, STOP — behavior drifted.

- [ ] **Step 4: Verify the whole suite + build the example**

```bash
flutter analyze
flutter test 2>&1 | tail -1
(cd example && flutter build apk --debug)
```

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: restore ATR via identifyTag, complete the transport migration

identifyTag holds the CcidCard and therefore the ATR, so it injects it into
the drivers that surface one. Plan 3's Android source will pass null here --
the built-in antenna has no ATR concept."
```

---

### Task 9: Delete the now-dead CCID plumbing

With every driver on a transport, the PC/SC + PN532 dialect exists in exactly one place (`ccid_backend.dart`). The old shared helpers are now either dead or used only by the backend.

**Files:**
- Modify or delete: `lib/src/pn532.dart` (its `pollTypeA`/`pollTypeB` are now backend-internal)
- Modify: `lib/src/apdu.dart` (`transceiveEscape` is now backend-internal)
- Modify: `lib/nfc_hub.dart` (drop any export that no longer exists)
- Modify: `CHANGELOG.md`, `pubspec.yaml` (version)
- Modify: `test/src/{apdu,pn532}_test.dart` as needed

**Interfaces:**
- Consumes: Tasks 1-8.
- Produces: nothing new. This is cleanup.

- [ ] **Step 1: Find what is actually dead**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
for sym in transceiveEscape pollTypeA pollTypeB transceiveChecked stripAndCheckSw; do
  echo "=== $sym ==="
  grep -rn "$sym" lib | grep -v "^lib/src/apdu.dart:\|^lib/src/pn532.dart:"
done
```

Anything with no hits outside its own definition file (and outside `ccid_backend.dart`) is a candidate to make private or fold into the backend. `stripAndCheckSw`/`transceiveChecked` are still used by the backend and possibly by `detection.dart`'s probes — keep those.

- [ ] **Step 2: Move `pn532.dart` under the transport layer**

`pollTypeA`/`pollTypeB` are CCID/PN532-specific and now serve only `ccid_backend.dart`. Move the file:

```bash
git mv lib/src/pn532.dart lib/src/transport/pn532.dart
git mv test/src/pn532_test.dart test/transport/pn532_test.dart
```

Fix the imports the analyzer flags. This puts every CCID-dialect-aware file under `lib/src/transport/`, which is the point of the plan: one directory owns the reader dialect.

- [ ] **Step 3: Confirm no driver imports the CCID dialect any more**

This is the plan's actual success criterion — prove it:

```bash
cd /Users/akashshahriar/StudioProjects/ccid
echo "=== drivers must not reference CcidCard, PN532, or any pseudo-APDU ==="
grep -rn "CcidCard\|pollType\|transceiveEscape\|'FF" lib/src/tag/ && echo "!!! LEAKED" || echo "clean -- drivers are transport-agnostic"
```

Expected: `clean`. `detection.dart` is the one allowed exception — it is the CCID-specific factory and legitimately holds a `CcidCard` and runs probe APDUs. If a *driver* file (`type2/mifare_classic/felica/iso_dep/iso_b.dart`) shows a hit, the migration is incomplete.

- [ ] **Step 4: Update CHANGELOG and bump the version**

Prepend to `CHANGELOG.md`:

```markdown
## 0.5.0

**Internal:** tag drivers are now built on per-technology transport interfaces
(`Type2Transport`, `MifareClassicTransport`, `NfcFTransport`,
`IsoDepTransport`, `NfcBTransport`) rather than talking to a `CcidCard`
directly. The PC/SC and PN532 reader dialect now lives in exactly one place
(`CcidTransportBackend`). No behavior change: reading a tag through a CCID
reader works exactly as in 0.4.0.

This is the groundwork for built-in NFC support — a second backend can now
implement the same interfaces without touching a driver.

* Driver constructors now take a transport instead of a `CcidCard`. Use
  `identifyTag()` to obtain drivers; it is unchanged.
* `TagDriver` no longer exposes a `card` field.
```

Set `version: 0.5.0` in `pubspec.yaml`.

- [ ] **Step 5: Final verification**

```bash
cd /Users/akashshahriar/StudioProjects/ccid
flutter analyze
flutter test 2>&1 | tail -1
flutter pub publish --dry-run 2>&1 | tail -3
(cd example && flutter build apk --debug)
```

Expected: analyze clean; all tests pass (>= 84); "Package has 0 warnings."; APK builds.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "refactor: consolidate the CCID dialect under lib/src/transport/

pn532.dart moves under the transport layer -- every file that knows about
PC/SC pseudo-APDUs or PN532 escapes now lives in one directory. Drivers
reference none of it."
```

---

## Definition of Done

- `flutter analyze` → clean (2 pre-existing example lints only).
- `flutter test` → **≥ 84 passing, 0 failing**. New byte-exactness tests added; none lost.
- `flutter pub publish --dry-run` → 0 warnings.
- Example app builds AND still reads a real tag through the ACR122U — **this is the gate that matters.** The whole plan is a bet that the pseudo-APDUs survived relocation intact, and only hardware can settle it. Test MIFARE Classic, FeliCa (the MRT card), and an NTAG.
- `grep -rn "CcidCard\|pollType\|transceiveEscape\|'FF" lib/src/tag/` returns nothing for the five driver files — drivers are genuinely transport-agnostic, which is what makes Plan 3 possible.
- `test/tag/detection_test.dart` passes with **zero assertion changes** — the strongest available evidence that behavior was preserved.
