# Generic Tag Info Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add generic tag identification (real SAK/ATQA via a raw PN532 poll, FeliCa PMm/chip-model/system-codes, DESFire GetVersion generation decoding, a new ISO14443-B family, and a common `TagInfo` summary) so the example app can show technology/UID/model/ATR for any supported card, in the spirit of the "NFC Tools" app.

**Architecture:** A new low-level PN532 `InListPassiveTarget` primitive (`lib/src/pn532.dart`) supplies real ATQA/SAK (Type A) or ATQB (Type B) directly from the card, independent of the ATR. Existing drivers (`Type2Tag`, `MifareClassicTag`, `FelicaTag`, `IsoDepTag`) each gain a `readTagInfo()` method returning a family-specific `TagInfo` subclass. A new `TypeBTag` driver and `identifyTag()` fallback step cover ISO14443-B. `identifyTag()`'s existing ATR/probing driver-selection logic is unchanged — the new primitive is additive, used for info-gathering and the new family, not for re-deciding driver selection that already works.

**Tech Stack:** Same as the rest of this plugin — Flutter/Dart, `flutter_test`, `package:convert`'s `hex` codec.

## Global Constraints

- Design reference: `docs/superpowers/specs/2026-07-09-generic-tag-info-design.md`.
- ISO15693 is out of scope entirely (confirmed hardware-impossible on this reader). NFC Forum Type 1/Jewel/Topaz gets no new driver (obsolete).
- FeliCa's IC-code→model table and System Code labels are community-sourced, not official Sony publications — doc comments and any UI text must say so, not present them as authoritative.
- DESFire native-mode responses (`readDesfireVersion()`) do **not** carry a real trailing PC/SC status word when the response is 2+ bytes (per ACS's own ACR122U documentation) — do not reuse `transceiveChecked`/`stripAndCheckSw` for this method; hex-decode the full response directly, with byte 0 carrying DESFire's own continuation status (`0xAF` = more frames, `0x00` = last frame).
- Every new/changed Dart file needs unit tests using the existing fake-`CcidPlatform` pattern from `test/ccid_test.dart`.
- `identifyTag()`'s existing ATR-first-then-probing logic for Type2/MIFARE Classic/FeliCa/generic-IsoDep is proven working against real hardware — do not modify it. Only add a new fallback step for Type B.

---

### Task 1: Shared escape-command helper + FelicaTag refactor

**Files:**
- Modify: `lib/src/apdu.dart`
- Modify: `lib/ccid_felica.dart:103-119` (`_transceiveFelicaFrame`)
- Test: `test/src/apdu_test.dart`

**Interfaces:**
- Produces: `Future<Uint8List> transceiveEscape(CcidCard card, Uint8List payload)` — Task 2's `pollTypeA`/`pollTypeB` and this task's refactored `FelicaTag._transceiveFelicaFrame` both use it.

- [ ] **Step 1: Write the failing test**

Add to `test/src/apdu_test.dart` (new `group`, alongside the existing ones):

```dart
group('transceiveEscape', () {
  test('wraps the payload in the FF 00 00 00 <Lc> escape command and '
      'returns the checked response', () async {
    CcidPlatform.instance = _FakeCcidPlatform(
        {'FF00000003AABBCC': '${hex.encode([0x01, 0x02])}9000'});
    final card = CcidCard('fake-reader');

    final data = await transceiveEscape(
        card, Uint8List.fromList([0xAA, 0xBB, 0xCC]));

    expect(data, equals([0x01, 0x02]));
  });
});
```

(Uses the same `_FakeCcidPlatform` already defined at the top of this file.)

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/src/apdu_test.dart`
Expected: FAIL — `transceiveEscape` isn't defined

- [ ] **Step 3: Implement `transceiveEscape`**

In `lib/src/apdu.dart`, add below the existing `transceiveChecked`:

```dart
/// Wraps [payload] in the reader's direct-transmit escape pseudo-APDU
/// (`FF 00 00 00 <Lc> <data>`) and returns the checked response data
/// (status-word-stripped, requiring a `9000` success).
Future<Uint8List> transceiveEscape(CcidCard card, Uint8List payload) {
  final lcHex = payload.length.toRadixString(16).padLeft(2, '0');
  final dataHex = hex.encode(payload);
  final capdu = 'FF000000$lcHex$dataHex'.toUpperCase();
  return transceiveChecked(card, capdu);
}
```

- [ ] **Step 4: Refactor `FelicaTag._transceiveFelicaFrame` to use it**

In `lib/ccid_felica.dart`, replace the method body:

```dart
  Future<Uint8List> _transceiveFelicaFrame(Uint8List felicaCommand) async {
    final framedFelicaCommand =
        Uint8List.fromList([felicaCommand.length + 1, ...felicaCommand]);
    final payload =
        Uint8List.fromList([0xD4, 0x40, 0x01, ...framedFelicaCommand]);

    final response = await transceiveEscape(card, payload);
    if (response.length < 3 || response[0] != 0xD5 || response[1] != 0x41) {
      throw Exception(
          'Unexpected InDataExchange response header: ${hex.encode(response)}');
    }
    if (response[2] != 0x00) {
      throw Exception('InDataExchange failed with status '
          '0x${response[2].toRadixString(16).padLeft(2, '0')}');
    }
    return Uint8List.sublistView(response, 3);
  }
```

- [ ] **Step 5: Run tests to verify everything passes**

Run: `flutter test test/src/apdu_test.dart test/ccid_felica_test.dart`
Expected: PASS (all tests — `transceiveEscape` new test plus unchanged `FelicaTag` tests, since the refactor doesn't change the wire bytes)

- [ ] **Step 6: Commit**

```bash
git add lib/src/apdu.dart lib/ccid_felica.dart test/src/apdu_test.dart
git commit -m "refactor: extract shared transceiveEscape() helper"
```

---

### Task 2: PN532 `InListPassiveTarget` primitive (Type A + Type B poll)

**Files:**
- Create: `lib/src/pn532.dart`
- Test: `test/src/pn532_test.dart`

**Interfaces:**
- Consumes: `transceiveEscape` (Task 1).
- Produces: `class PassiveTargetTypeA { atqa, sak, uid }`, `class PassiveTargetTypeB { atqb, attribResponse }`, `Future<PassiveTargetTypeA?> pollTypeA(CcidCard card)`, `Future<PassiveTargetTypeB?> pollTypeB(CcidCard card)`. Task 3 (MIFARE info), Task 9 (TypeBTag), and Task 10 (`readTagInfo()` on `MifareClassicTag`/`IsoDepTag`) all depend on this.

**Note:** Byte layout verified against ACS's own worked example (`FF 00 00 00 04 D4 4A 01 00` → `D5 4B 01 01 00 44 08 07 04 01 02 03 04 05 06 90 00`). Type B's response structure (`Tg | ATQB(12 bytes) | ATTRIB_RES length | ATTRIB_RES`) is grounded in the PN532 User Manual but has no confirmed real-hardware test yet — flag this in your self-review.

- [ ] **Step 1: Write the failing tests**

Create `test/src/pn532_test.dart`:

```dart
import 'dart:typed_data';

import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:ccid/src/pn532.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    if (!responses.containsKey(capdu)) {
      throw Exception('No fake response configured for capdu: $capdu');
    }
    return responses[capdu];
  }

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}

void main() {
  tearDown(() {
    CcidPlatform.instance = null;
  });

  group('pollTypeA', () {
    test('parses a found target (ACS worked example)', () async {
      // Full response: D5 4B (InListPassiveTarget) 01 (NbTg) 01 (Tg)
      // 00 44 (ATQA) 08 (SAK) 07 (UID length) 04 01 02 03 04 05 06 (UID).
      CcidPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100':
            'D54B01010044080704010203040506' '9000',
      });
      final card = CcidCard('fake-reader');

      final target = await pollTypeA(card);

      expect(target, isNotNull);
      expect(target!.atqa, equals([0x00, 0x44]));
      expect(target.sak, equals(0x08));
      expect(target.uid, equals([0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]));
    });

    test('returns null when no target is found', () async {
      CcidPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0100': 'D54B00' '9000',
      });
      final card = CcidCard('fake-reader');

      final target = await pollTypeA(card);

      expect(target, isNull);
    });
  });

  group('pollTypeB', () {
    test('parses a found target', () async {
      final atqb = List.filled(12, 0x11);
      final attrib = [0x22, 0x33];
      CcidPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0103': [
          'D54B', // InListPassiveTarget response header
          '01', // NbTg
          '01', // Tg
          atqb.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '02', // ATTRIB_RES length
          attrib.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
          '9000',
        ].join().toUpperCase(),
      });
      final card = CcidCard('fake-reader');

      final target = await pollTypeB(card);

      expect(target, isNotNull);
      expect(target!.atqb, equals(atqb));
      expect(target.attribResponse, equals(attrib));
    });

    test('returns null when no target is found', () async {
      CcidPlatform.instance = _FakeCcidPlatform({
        'FF00000004D44A0103': 'D54B00' '9000',
      });
      final card = CcidCard('fake-reader');

      final target = await pollTypeB(card);

      expect(target, isNull);
    });
  });
}
```

**Verification of the Lc byte**: `FF 00 00 00 04 D4 4A 01 00` — payload `D4 4A 01 00` is 4 bytes, so `Lc=04`, matching ACS's own worked example literally. This one Lc value is reused unchanged in every test above (Type A/B, found/not-found) since the request bytes never change — only the response differs.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/src/pn532_test.dart`
Expected: FAIL — `package:ccid/src/pn532.dart` doesn't exist

- [ ] **Step 3: Implement**

Create `lib/src/pn532.dart`:

```dart
import 'dart:typed_data';

import '../ccid.dart' show CcidCard;
import 'apdu.dart';

/// A Type A target found by [pollTypeA], with its real ATQA/SAK/UID read
/// directly from the card via the PN532's `InListPassiveTarget` command
/// (`D4 4A`), independent of the reader's ATR.
class PassiveTargetTypeA {
  final Uint8List atqa; // SENS_RES, 2 bytes
  final int sak; // SEL_RES, 1 byte
  final Uint8List uid;

  const PassiveTargetTypeA({
    required this.atqa,
    required this.sak,
    required this.uid,
  });
}

/// A Type B target found by [pollTypeB].
class PassiveTargetTypeB {
  final Uint8List atqb; // 12 bytes: '50' | PUPI(4) | AppData(4) | ProtocolInfo(3)
  final Uint8List attribResponse;

  const PassiveTargetTypeB({
    required this.atqb,
    required this.attribResponse,
  });
}

/// Polls for a Type A (ISO14443-A) target via the PN532's
/// `InListPassiveTarget` command, returning its real ATQA/SAK/UID.
/// Returns `null` if no tag answers.
Future<PassiveTargetTypeA?> pollTypeA(CcidCard card) async {
  final response = await _inListPassiveTarget(card, brTy: 0x00);
  if (response == null) return null;
  final atqa = Uint8List.sublistView(response, 1, 3);
  final sak = response[3];
  final uidLength = response[4];
  final uid = Uint8List.sublistView(response, 5, 5 + uidLength);
  return PassiveTargetTypeA(atqa: atqa, sak: sak, uid: uid);
}

/// Polls for a Type B (ISO14443-B) target via the PN532's
/// `InListPassiveTarget` command. Returns `null` if no tag answers.
Future<PassiveTargetTypeB?> pollTypeB(CcidCard card) async {
  final response = await _inListPassiveTarget(card, brTy: 0x03);
  if (response == null) return null;
  final atqb = Uint8List.sublistView(response, 1, 13);
  final attribLength = response[13];
  final attribResponse =
      Uint8List.sublistView(response, 14, 14 + attribLength);
  return PassiveTargetTypeB(atqb: atqb, attribResponse: attribResponse);
}

/// Sends `InListPassiveTarget` (max 1 target, the given [brTy] baud
/// rate/modulation) and returns the bytes after `NbTg`, i.e. starting at
/// `Tg`, or `null` if `NbTg` is 0 (no target found).
Future<Uint8List?> _inListPassiveTarget(CcidCard card, {required int brTy}) async {
  final payload = Uint8List.fromList([0xD4, 0x4A, 0x01, brTy]);
  final response = await transceiveEscape(card, payload);
  if (response.length < 3 || response[0] != 0xD5 || response[1] != 0x4B) {
    throw Exception(
        'Unexpected InListPassiveTarget response header: ${response}');
  }
  final numTargets = response[2];
  if (numTargets == 0) return null;
  return Uint8List.sublistView(response, 3);
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/src/pn532_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/src/pn532.dart test/src/pn532_test.dart
git commit -m "feat: add PN532 InListPassiveTarget poll (Type A + Type B)"
```

---

### Task 3: MIFARE family identification from SAK

**Files:**
- Create: `lib/ccid_mifare_info.dart`
- Test: `test/ccid_mifare_info_test.dart`

**Interfaces:**
- Produces: `enum MifareFamily { classic1k, classic4k, mini, ultralightOrNtag, desfireOrPlusSl3, unknown }`, `MifareFamily mifareFamilyFromSak(int sak)`, `String mifareFamilyLabel(MifareFamily family)`. Task 10 (`MifareClassicTag.readTagInfo()`) depends on this.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_mifare_info_test.dart`:

```dart
import 'package:ccid/ccid_mifare_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mifareFamilyFromSak', () {
    test('identifies MIFARE Classic 1K (0x08)', () {
      expect(mifareFamilyFromSak(0x08), equals(MifareFamily.classic1k));
    });

    test('identifies MIFARE Classic 4K (0x18)', () {
      expect(mifareFamilyFromSak(0x18), equals(MifareFamily.classic4k));
    });

    test('identifies MIFARE Mini (0x09)', () {
      expect(mifareFamilyFromSak(0x09), equals(MifareFamily.mini));
    });

    test('identifies Ultralight/NTAG family (0x00)', () {
      expect(mifareFamilyFromSak(0x00),
          equals(MifareFamily.ultralightOrNtag));
    });

    test('identifies DESFire/Plus-SL3 via the 0x20 ISO14443-4 bit, even '
        'combined with other bits', () {
      expect(mifareFamilyFromSak(0x20),
          equals(MifareFamily.desfireOrPlusSl3));
      expect(mifareFamilyFromSak(0x24),
          equals(MifareFamily.desfireOrPlusSl3));
    });

    test('returns unknown for an unrecognized SAK', () {
      expect(mifareFamilyFromSak(0x7F), equals(MifareFamily.unknown));
    });
  });

  group('mifareFamilyLabel', () {
    test('labels every family value', () {
      expect(mifareFamilyLabel(MifareFamily.classic1k),
          equals('MIFARE Classic 1K'));
      expect(mifareFamilyLabel(MifareFamily.classic4k),
          equals('MIFARE Classic 4K'));
      expect(mifareFamilyLabel(MifareFamily.mini), equals('MIFARE Mini'));
      expect(mifareFamilyLabel(MifareFamily.ultralightOrNtag),
          equals('MIFARE Ultralight / NTAG family'));
      expect(mifareFamilyLabel(MifareFamily.desfireOrPlusSl3),
          equals('MIFARE DESFire / MIFARE Plus (SL3)'));
      expect(mifareFamilyLabel(MifareFamily.unknown),
          equals('Unknown MIFARE-family card (SAK not recognized)'));
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_mifare_info_test.dart`
Expected: FAIL — `package:ccid/ccid_mifare_info.dart` doesn't exist

- [ ] **Step 3: Implement**

Create `lib/ccid_mifare_info.dart`:

```dart
/// The coarse MIFARE-family classification of a card, resolved from its
/// SAK (Select Acknowledge) byte per NXP's AN10833 "MIFARE Type
/// Identification Procedure". ATQA is deliberately not used for branching
/// here -- NXP's own guidance is that ATQA can be misleading and SAK is
/// the authoritative discriminator.
enum MifareFamily {
  classic1k,
  classic4k,
  mini,
  ultralightOrNtag,
  desfireOrPlusSl3,
  unknown,
}

/// Resolves the [MifareFamily] for [sak]. Bit `0x20` (ISO14443-4
/// compliance) is checked first, since DESFire/Plus-SL3 cards can present
/// it combined with other bits.
MifareFamily mifareFamilyFromSak(int sak) {
  if (sak & 0x20 != 0) return MifareFamily.desfireOrPlusSl3;
  switch (sak) {
    case 0x08:
      return MifareFamily.classic1k;
    case 0x18:
      return MifareFamily.classic4k;
    case 0x09:
      return MifareFamily.mini;
    case 0x00:
      return MifareFamily.ultralightOrNtag;
    default:
      return MifareFamily.unknown;
  }
}

/// A human-readable label for [family].
String mifareFamilyLabel(MifareFamily family) {
  switch (family) {
    case MifareFamily.classic1k:
      return 'MIFARE Classic 1K';
    case MifareFamily.classic4k:
      return 'MIFARE Classic 4K';
    case MifareFamily.mini:
      return 'MIFARE Mini';
    case MifareFamily.ultralightOrNtag:
      return 'MIFARE Ultralight / NTAG family';
    case MifareFamily.desfireOrPlusSl3:
      return 'MIFARE DESFire / MIFARE Plus (SL3)';
    case MifareFamily.unknown:
      return 'Unknown MIFARE-family card (SAK not recognized)';
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_mifare_info_test.dart`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/ccid_mifare_info.dart test/ccid_mifare_info_test.dart
git commit -m "feat: add MIFARE family identification from SAK"
```

---

### Task 4: Ultralight/NTAG exact model lookup

**Files:**
- Modify: `lib/ccid_tag_info.dart` (add to the end of the file)
- Test: `test/ccid_tag_info_test.dart` (add a new group)

**Interfaces:**
- Consumes: `ChipVersion` (existing, same file).
- Produces: `String? ultralightModelName(ChipVersion version)`. Task 10 (`Type2Tag.readTagInfo()`) depends on this.

- [ ] **Step 1: Write the failing test**

Add to `test/ccid_tag_info_test.dart` (new `group`, alongside the existing ones):

```dart
group('ultralightModelName', () {
  test('identifies NTAG213 from its exact GET_VERSION bytes', () {
    final version = ChipVersion.parse(Uint8List.fromList(
        [0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03]));

    expect(ultralightModelName(version), equals('NTAG 213'));
  });

  test('identifies NTAG215', () {
    final version = ChipVersion.parse(Uint8List.fromList(
        [0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03]));

    expect(ultralightModelName(version), equals('NTAG 215'));
  });

  test('identifies NTAG216', () {
    final version = ChipVersion.parse(Uint8List.fromList(
        [0x00, 0x04, 0x04, 0x02, 0x01, 0x00, 0x13, 0x03]));

    expect(ultralightModelName(version), equals('NTAG 216'));
  });

  test('identifies the original MIFARE Ultralight', () {
    final version = ChipVersion.parse(Uint8List.fromList(
        [0x00, 0x04, 0x03, 0x01, 0x00, 0x00, 0x0B, 0x03]));

    expect(ultralightModelName(version), equals('MIFARE Ultralight'));
  });

  test('falls back to a coarse NTAG family label for an unrecognized '
      'exact tuple', () {
    final version = ChipVersion.parse(Uint8List.fromList(
        [0x00, 0x04, 0x04, 0xFF, 0x01, 0x00, 0x0F, 0x03]));

    expect(ultralightModelName(version),
        equals('NTAG family (unrecognized exact model)'));
  });

  test('returns null for a non-NXP vendor ID', () {
    final version = ChipVersion.parse(Uint8List.fromList(
        [0x00, 0x99, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03]));

    expect(ultralightModelName(version), isNull);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_tag_info_test.dart`
Expected: FAIL — `ultralightModelName` isn't defined

- [ ] **Step 3: Implement**

Append to `lib/ccid_tag_info.dart`:

```dart
class _UltralightModelEntry {
  final int vendorId;
  final int productType;
  final int productSubtype;
  final int majorVersion;
  final int minorVersion;
  final int storageSize;
  final int protocolType;
  final String name;

  const _UltralightModelEntry(
    this.vendorId,
    this.productType,
    this.productSubtype,
    this.majorVersion,
    this.minorVersion,
    this.storageSize,
    this.protocolType,
    this.name,
  );
}

/// Known MIFARE Ultralight/NTAG `GET_VERSION` tuples, sourced from NXP's
/// NTAG213/215/216 and MF0ULX1 datasheets plus the Proxmark3 project's
/// field-validated `ul_family[]` table.
const _ultralightModels = <_UltralightModelEntry>[
  _UltralightModelEntry(
      0x04, 0x03, 0x01, 0x00, 0x00, 0x0B, 0x03, 'MIFARE Ultralight'),
  _UltralightModelEntry(0x04, 0x03, 0x01, 0x01, 0x00, 0x0B, 0x03,
      'MIFARE Ultralight EV1 (48B, 17pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x02, 0x01, 0x00, 0x0B, 0x03,
      'MIFARE Ultralight EV1 (48B, 50pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x01, 0x01, 0x00, 0x0E, 0x03,
      'MIFARE Ultralight EV1 (128B, 17pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x02, 0x01, 0x00, 0x0E, 0x03,
      'MIFARE Ultralight EV1 (128B, 50pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x01, 0x02, 0x00, 0x0B, 0x03,
      'MIFARE Ultralight Nano 40B (17pF)'),
  _UltralightModelEntry(0x04, 0x03, 0x01, 0x03, 0x00, 0x0B, 0x03,
      'MIFARE Ultralight Nano (17pF)'),
  _UltralightModelEntry(
      0x04, 0x04, 0x01, 0x01, 0x00, 0x0B, 0x03, 'NTAG 210'),
  _UltralightModelEntry(
      0x04, 0x04, 0x02, 0x01, 0x00, 0x0B, 0x03, 'NTAG 210'),
  _UltralightModelEntry(
      0x04, 0x04, 0x01, 0x01, 0x00, 0x0E, 0x03, 'NTAG 212'),
  _UltralightModelEntry(
      0x04, 0x04, 0x02, 0x01, 0x00, 0x0F, 0x03, 'NTAG 213'),
  _UltralightModelEntry(
      0x04, 0x04, 0x04, 0x01, 0x00, 0x0F, 0x03, 'NTAG 213F'),
  _UltralightModelEntry(
      0x04, 0x04, 0x02, 0x01, 0x01, 0x0F, 0x03, 'NTAG 213C'),
  _UltralightModelEntry(
      0x04, 0x04, 0x02, 0x03, 0x00, 0x0F, 0x03, 'NTAG 213TT'),
  _UltralightModelEntry(
      0x04, 0x04, 0x02, 0x01, 0x00, 0x11, 0x03, 'NTAG 215'),
  _UltralightModelEntry(
      0x04, 0x04, 0x04, 0x01, 0x00, 0x11, 0x03, 'NTAG 215F'),
  _UltralightModelEntry(
      0x04, 0x04, 0x02, 0x01, 0x00, 0x13, 0x03, 'NTAG 216'),
  _UltralightModelEntry(
      0x04, 0x04, 0x04, 0x01, 0x00, 0x13, 0x03, 'NTAG 216F'),
];

/// Resolves an exact NXP model name from [version], falling back to a
/// coarse family label (`productType`: `0x03` -> Ultralight family,
/// `0x04` -> NTAG family) if the exact tuple isn't in the table, matching
/// Proxmark3's own fallback strategy. Returns `null` for a non-NXP vendor
/// ID (`version.vendorId != 0x04`).
String? ultralightModelName(ChipVersion version) {
  for (final entry in _ultralightModels) {
    if (entry.vendorId == version.vendorId &&
        entry.productType == version.productType &&
        entry.productSubtype == version.productSubtype &&
        entry.majorVersion == version.majorVersion &&
        entry.minorVersion == version.minorVersion &&
        entry.storageSize == version.storageSize &&
        entry.protocolType == version.protocolType) {
      return entry.name;
    }
  }
  if (version.vendorId != 0x04) return null;
  if (version.productType == 0x03) {
    return 'MIFARE Ultralight family (unrecognized exact model)';
  }
  if (version.productType == 0x04) {
    return 'NTAG family (unrecognized exact model)';
  }
  return null;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_tag_info_test.dart`
Expected: PASS (all tests, including the 6 new ones)

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_tag_info.dart test/ccid_tag_info_test.dart
git commit -m "feat: add Ultralight/NTAG exact model lookup"
```

---

### Task 5: `FelicaTag.pmm`

**Files:**
- Modify: `lib/ccid_felica.dart`
- Test: `test/ccid_felica_test.dart`

**Interfaces:**
- Produces: `Future<Uint8List> get pmm` on `FelicaTag`. Task 7's `felicaModelName` and Task 10's `FelicaTag.readTagInfo()` depend on this.

- [ ] **Step 1: Write the failing test**

Add to `test/ccid_felica_test.dart`:

```dart
test('pmm polls the card and returns the 8-byte PMm, cached', () async {
  // Polling command (00 FF FF 00 00, 5 bytes) framed to 6 bytes (leading
  // length byte 06), wrapped in D4 40 01 -> 9-byte payload -> Lc=09.
  const pollCapdu = 'FF00000009D440010600FFFF0000';
  const pmmHex = '0135428282468CFF';
  // Response: D5 41 00 (InDataExchange success) + FeliCa response frame
  // (18 bytes: len=12, respCode=01, idm(8), pmm(8)).
  const pollResponse = 'D541001201$idmHex${pmmHex}9000';
  final fake = _FakeCcidPlatform({pollCapdu: pollResponse});
  CcidPlatform.instance = fake;
  final tag = FelicaTag(CcidCard('fake-reader'));

  final pmm = await tag.pmm;
  final pmmAgain = await tag.pmm;

  expect(pmm, equals(hex.decode(pmmHex)));
  expect(pmmAgain, equals(pmm));
  expect(
    fake.requestedCapdus.where((c) => c == pollCapdu),
    hasLength(1),
    reason: 'the second pmm access should use the cached value, not poll '
        'again',
  );
});
```

Add `import 'package:convert/convert.dart';` to the top of `test/ccid_felica_test.dart` if not already present (needed for `hex.decode`).

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_felica_test.dart`
Expected: FAIL — `pmm` isn't defined on `FelicaTag`

- [ ] **Step 3: Implement**

In `lib/ccid_felica.dart`, add a `_pmm` cache field next to `_idm`, and the `pmm` getter next to `idm`:

```dart
  Uint8List? _idm;
  Uint8List? _pmm;

  /// The card's 8-byte IDm, read once via the reader's standard PC/SC
  /// "Get Data" pseudo-APDU (`FF CA 00 00 00`) -- which returns the FeliCa
  /// IDm on this class of reader, per ACS's documentation -- and cached
  /// for the lifetime of this driver.
  Future<Uint8List> get idm async {
    final cached = _idm;
    if (cached != null) return cached;
    final read = await transceiveChecked(card, 'FFCA000000');
    _idm = read;
    return read;
  }

  /// The card's 8-byte PMm (Manufacturer Parameter), read once via a
  /// FeliCa Polling (SENSF_REQ) command sent through the same
  /// InDataExchange-wrapped escape command `readWithoutEncryption` uses,
  /// and cached for the lifetime of this driver. PMm's first two bytes
  /// (ROM Type, IC Type) identify the chip model -- see
  /// [felicaModelName] in `ccid_felica_info.dart`.
  Future<Uint8List> get pmm async {
    final cached = _pmm;
    if (cached != null) return cached;
    final command = Uint8List.fromList([
      0x00, // Polling command code
      0xFF, 0xFF, // System Code: wildcard
      0x00, // Request Code: none
      0x00, // Time Slot
    ]);
    final response = await _transceiveFelicaFrame(command);
    // Response frame: length(1) | responseCode(1)=0x01 | idm(8) | pmm(8).
    if (response.length < 18) {
      throw Exception(
          'FeliCa polling response too short (${response.length} bytes)');
    }
    final read = Uint8List.sublistView(response, 10, 18);
    _pmm = read;
    return read;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_felica_test.dart`
Expected: PASS (all tests, including the new one)

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_felica.dart test/ccid_felica_test.dart
git commit -m "feat: add FelicaTag.pmm"
```

---

### Task 6: `FelicaTag.requestSystemCodes()`

**Files:**
- Modify: `lib/ccid_felica.dart`
- Test: `test/ccid_felica_test.dart`

**Interfaces:**
- Consumes: `idm` (existing).
- Produces: `Future<List<int>> requestSystemCodes()` on `FelicaTag`. Task 10's `FelicaTag.readTagInfo()` depends on this.

- [ ] **Step 1: Write the failing test**

Add to `test/ccid_felica_test.dart`:

```dart
test('requestSystemCodes() enumerates every system on the card', () async {
  const uidResponseLocal = '${idmHex}9000';
  // Request System Code command (0C + idm(8), 9 bytes) framed to 10 bytes
  // (leading length byte 0A), wrapped in D4 40 01 -> 13-byte payload ->
  // Lc=0D.
  const requestCapdu = 'FF0000000DD440010A0CAABBCCDDEE001122';
  // Response frame: len=0F (15 bytes: len+respCode+idm(8)+numSystems+
  // 2 system codes), respCode=0D, idm(8), numSystems=02,
  // systemCode0=0003, systemCode1=90E3.
  const requestResponse =
      'D541000F' '0D' idmHex '02' '000390E3' '9000';
  final fake = _FakeCcidPlatform({
    uidCapdu: uidResponseLocal,
    requestCapdu: requestResponse,
  });
  CcidPlatform.instance = fake;
  final tag = FelicaTag(CcidCard('fake-reader'));

  final systemCodes = await tag.requestSystemCodes();

  expect(systemCodes, equals([0x0003, 0x90E3]));
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_felica_test.dart`
Expected: FAIL — `requestSystemCodes` isn't defined. If the hand-computed `requestCapdu`/`requestResponse` hex strings don't match what the implementation below actually builds/expects, print `fake.requestedCapdus` and re-derive them byte-by-byte from the frame layout in the doc comment (same approach used for the original FeliCa fix) rather than guessing.

- [ ] **Step 3: Implement**

In `lib/ccid_felica.dart`, add below `readWithoutEncryption`:

```dart
  /// Enumerates every System Code present on the card via the native
  /// "Request System Code" command (`0x0C`), not just whichever System a
  /// specific service-code read happens to target.
  Future<List<int>> requestSystemCodes() async {
    final cardIdm = await idm;
    final command = Uint8List.fromList([0x0C, ...cardIdm]);
    final response = await _transceiveFelicaFrame(command);
    // Response frame: length(1) | responseCode(1)=0x0D | idm(8) |
    // numSystems(1) | systemCode(2) x numSystems.
    if (response.length < 11) {
      throw Exception('Request System Code response too short '
          '(${response.length} bytes)');
    }
    final numSystems = response[10];
    final systemCodes = <int>[];
    var offset = 11;
    for (var i = 0;
        i < numSystems && offset + 2 <= response.length;
        i++) {
      systemCodes.add((response[offset] << 8) | response[offset + 1]);
      offset += 2;
    }
    return systemCodes;
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_felica_test.dart`
Expected: PASS (all tests)

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_felica.dart test/ccid_felica_test.dart
git commit -m "feat: add FelicaTag.requestSystemCodes()"
```

---

### Task 7: FeliCa chip-model and system-code label lookups

**Files:**
- Create: `lib/ccid_felica_info.dart`
- Test: `test/ccid_felica_info_test.dart`

**Interfaces:**
- Produces: `String? felicaModelName(Uint8List pmm)`, `String? felicaSystemCodeLabel(int systemCode)`. Task 10's `FelicaTag.readTagInfo()` depends on both.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_felica_info_test.dart`:

```dart
import 'dart:typed_data';

import 'package:ccid/ccid_felica_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('felicaModelName', () {
    test('identifies RC-SA01/2 (the confirmed Dhaka MRT chip)', () {
      final pmm = Uint8List.fromList(
          [0x03, 0x35, 0x42, 0x82, 0x82, 0x46, 0x8C, 0xFF]);

      expect(felicaModelName(pmm), equals('RC-SA01/2'));
    });

    test('identifies FeliCa Lite (RC-S965), which has no ROM constraint',
        () {
      final pmm = Uint8List.fromList(
          [0x00, 0xF0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

      expect(felicaModelName(pmm), equals('FeliCa Lite (RC-S965)'));
    });

    test('returns null for an unrecognized IC code', () {
      final pmm = Uint8List.fromList(
          [0x00, 0xAB, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]);

      expect(felicaModelName(pmm), isNull);
    });
  });

  group('felicaSystemCodeLabel', () {
    test('labels the Dhaka MRT system code', () {
      expect(felicaSystemCodeLabel(0x90E3), equals('MRT_PASS (Dhaka MRT/RapidPass)'));
    });

    test('labels the NFC Forum Type 3 Tag system code', () {
      expect(felicaSystemCodeLabel(0x12FC),
          equals('NFC Forum Type 3 Tag (NDEF)'));
    });

    test('returns null for an unrecognized system code', () {
      expect(felicaSystemCodeLabel(0x1234), isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_felica_info_test.dart`
Expected: FAIL — `package:ccid/ccid_felica_info.dart` doesn't exist

- [ ] **Step 3: Implement**

Create `lib/ccid_felica_info.dart`:

```dart
import 'dart:typed_data';

class _FelicaChipEntry {
  final int? rom;
  final int ic;
  final String name;

  const _FelicaChipEntry(this.rom, this.ic, this.name);
}

/// Known FeliCa IC Code (PMm bytes 0-1: ROM Type, IC Type) -> chip model
/// mappings. **Community-sourced** (reverse-engineered by open-source
/// projects such as `nfcpy` and `kormax/felica-tool`) -- Sony does not
/// publish this table. Do not present results as officially authoritative.
const _felicaChips = <_FelicaChipEntry>[
  _FelicaChipEntry(0x01, 0x20, 'RC-S962 (FeliCa Standard)'),
  _FelicaChipEntry(0x03, 0x32, 'RC-SA00/1'),
  _FelicaChipEntry(0x03, 0x33, 'RC-SA00/2'),
  _FelicaChipEntry(0x03, 0x34, 'RC-SA01/1'),
  _FelicaChipEntry(0x03, 0x35, 'RC-SA01/2'),
  _FelicaChipEntry(0x01, 0x36, 'RC-SA04/1'),
  _FelicaChipEntry(null, 0x3E, 'RC-SA08'),
  _FelicaChipEntry(0x01, 0x44, 'RC-SA20/1'),
  _FelicaChipEntry(0x01, 0x46, 'RC-SA21/2'),
  _FelicaChipEntry(null, 0xF0, 'FeliCa Lite (RC-S965)'),
  _FelicaChipEntry(0x00, 0xF1, 'FeliCa Lite-S (RC-S966)'),
  _FelicaChipEntry(null, 0xE0, 'FeliCa Plug (RC-S926)'),
];

/// Resolves a chip model name from [pmm]'s IC Code bytes (`pmm[0]` = ROM
/// Type, `pmm[1]` = IC Type). Tries an exact `(rom, ic)` match first, then
/// falls back to an `ic`-only match for entries with no fixed ROM Type.
/// Returns `null` if [pmm] is too short or the IC code isn't recognized.
String? felicaModelName(Uint8List pmm) {
  if (pmm.length < 2) return null;
  final rom = pmm[0];
  final ic = pmm[1];
  for (final entry in _felicaChips) {
    if (entry.ic == ic && entry.rom == rom) return entry.name;
  }
  for (final entry in _felicaChips) {
    if (entry.ic == ic && entry.rom == null) return entry.name;
  }
  return null;
}

/// Known FeliCa System Code -> description mappings. **Community-sourced**
/// -- Sony does not publish a public System Code registry (codes are
/// privately assigned per issuer). Returns `null` for an unrecognized code.
const _systemCodeLabels = <int, String>{
  0x0003: 'Japan transit common area (Suica/PASMO/ICOCA/etc.)',
  0x8008: 'Octopus (Hong Kong)',
  0x86A7: 'Suica-family secondary system',
  0x88B4: 'FeliCa Lite/Lite-S native system',
  0x12FC: 'NFC Forum Type 3 Tag (NDEF)',
  0xFE00: 'FeliCa Networks common area (Edy/nanaco/WAON/etc.)',
  0x90E3: 'MRT_PASS (Dhaka MRT/RapidPass)',
  0xFFFF: 'Wildcard / unformatted',
};

String? felicaSystemCodeLabel(int systemCode) => _systemCodeLabels[systemCode];
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_felica_info_test.dart`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/ccid_felica_info.dart test/ccid_felica_info_test.dart
git commit -m "feat: add FeliCa chip-model and system-code label lookups"
```

---

### Task 8: DESFire `GetVersion` and generation decoding

**Files:**
- Create: `lib/ccid_desfire_info.dart`
- Modify: `lib/ccid_iso_dep.dart` (add `readDesfireVersion()`)
- Test: `test/ccid_desfire_info_test.dart`, `test/ccid_iso_dep_test.dart`

**Interfaces:**
- Produces: `class DesfireVersion { ... }`, `String desfireGenerationLabel(DesfireVersion version)` (`ccid_desfire_info.dart`); `Future<DesfireVersion> readDesfireVersion()` on `IsoDepTag`. Task 10's `IsoDepTag.readTagInfo()` depends on both.

**Note:** the test data below is transcribed verbatim from ACS's own ACR122U API documentation's DESFire native-mode worked example (Example 4) — a real device's actual response, not synthetic. Per that same document, native-mode DESFire responses of 2+ bytes carry **no** appended PC/SC status word at all (only sub-2-byte responses get a padded `9000`) — `readDesfireVersion()` must hex-decode the full response directly rather than stripping a trailing status word.

- [ ] **Step 1: Write the failing tests**

Create `test/ccid_desfire_info_test.dart`:

```dart
import 'dart:typed_data';

import 'package:ccid/ccid_desfire_info.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('desfireGenerationLabel identifies the original DESFire (MF3ICD40)',
      () {
    const version = DesfireVersion(
      hardwareVendorId: 0x04,
      hardwareType: 0x01,
      hardwareSubtype: 0x01,
      hardwareMajor: 0x00,
      hardwareMinor: 0x02,
      hardwareStorageSize: 0x18,
      hardwareProtocol: 0x05,
      softwareVendorId: 0x04,
      softwareType: 0x01,
      softwareSubtype: 0x01,
      softwareMajor: 0x00,
      softwareMinor: 0x06,
      softwareStorageSize: 0x18,
      softwareProtocol: 0x05,
      uid: [0x04, 0x52, 0x5A, 0x19, 0xB2, 0x1B, 0x80],
      batch: [0x8E, 0x36, 0x54, 0x4D, 0x40],
      productionWeek: 0x26,
      productionYear: 0x04,
    );

    expect(desfireGenerationLabel(version),
        equals('DESFire (original, MF3ICD40)'));
  });

  test('desfireGenerationLabel identifies DESFire EV1', () {
    const version = DesfireVersion(
      hardwareVendorId: 0x04,
      hardwareType: 0x01,
      hardwareSubtype: 0x01,
      hardwareMajor: 0x01,
      hardwareMinor: 0x00,
      hardwareStorageSize: 0x18,
      hardwareProtocol: 0x05,
      softwareVendorId: 0x04,
      softwareType: 0x01,
      softwareSubtype: 0x01,
      softwareMajor: 0x01,
      softwareMinor: 0x00,
      softwareStorageSize: 0x18,
      softwareProtocol: 0x05,
      uid: [0, 0, 0, 0, 0, 0, 0],
      batch: [0, 0, 0, 0, 0],
      productionWeek: 0,
      productionYear: 0,
    );

    expect(desfireGenerationLabel(version), equals('DESFire EV1'));
  });

  test('desfireGenerationLabel reports an unrecognized combination '
      'explicitly rather than guessing', () {
    const version = DesfireVersion(
      hardwareVendorId: 0x04,
      hardwareType: 0xFF,
      hardwareSubtype: 0x01,
      hardwareMajor: 0xFF,
      hardwareMinor: 0xFF,
      hardwareStorageSize: 0x18,
      hardwareProtocol: 0x05,
      softwareVendorId: 0x04,
      softwareType: 0xFF,
      softwareSubtype: 0x01,
      softwareMajor: 0xFF,
      softwareMinor: 0xFF,
      softwareStorageSize: 0x18,
      softwareProtocol: 0x05,
      uid: [0, 0, 0, 0, 0, 0, 0],
      batch: [0, 0, 0, 0, 0],
      productionWeek: 0,
      productionYear: 0,
    );

    expect(
        desfireGenerationLabel(version),
        equals('Unrecognized DESFire generation (type=0xff, major=0xff, '
            'minor=0xff)'));
  });
}
```

Add to `test/ccid_iso_dep_test.dart`:

```dart
group('readDesfireVersion', () {
  test('parses the 3-frame GetVersion exchange (real example from ACS '
      'ACR122U API documentation)', () async {
    final fake = _SequencedFakeCcidPlatform([
      'AF04010100021805',
      'AF04010100061805',
      '0004525A19B21B808E36544D402604',
    ]);
    CcidPlatform.instance = fake;
    final tag = IsoDepTag(CcidCard('fake-reader'));

    final version = await tag.readDesfireVersion();

    expect(version.hardwareVendorId, equals(0x04));
    expect(version.hardwareType, equals(0x01));
    expect(version.hardwareSubtype, equals(0x01));
    expect(version.hardwareMajor, equals(0x00));
    expect(version.hardwareMinor, equals(0x02));
    expect(version.hardwareStorageSize, equals(0x18));
    expect(version.hardwareProtocol, equals(0x05));
    expect(version.softwareMinor, equals(0x06));
    expect(version.uid, equals([0x04, 0x52, 0x5A, 0x19, 0xB2, 0x1B, 0x80]));
    expect(version.batch, equals([0x8E, 0x36, 0x54, 0x4D, 0x40]));
    expect(version.productionWeek, equals(0x26));
    expect(version.productionYear, equals(0x04));
    expect(fake.requestedCapdus, equals(['60', 'AF', 'AF']));
  });
});
```

Add this fake platform class to `test/ccid_iso_dep_test.dart` (alongside the existing `_FakeCcidPlatform`) — DESFire's native protocol reuses the identical `AF` request for both continuation frames, so it needs responses returned in call order rather than looked up by capdu content:

```dart
class _SequencedFakeCcidPlatform extends CcidPlatform {
  final List<String?> responses;
  final List<String> requestedCapdus = [];
  int _index = 0;

  _SequencedFakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    requestedCapdus.add(capdu);
    if (_index >= responses.length) {
      throw Exception('No more fake responses configured (requested $capdu)');
    }
    return responses[_index++];
  }

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/ccid_desfire_info_test.dart test/ccid_iso_dep_test.dart`
Expected: FAIL — `package:ccid/ccid_desfire_info.dart` doesn't exist, `readDesfireVersion` isn't defined

- [ ] **Step 3: Implement**

Create `lib/ccid_desfire_info.dart`:

```dart
/// The parsed result of a MIFARE DESFire `GetVersion` (native command
/// `0x60`) exchange -- a 3-frame, 28-byte response identifying the exact
/// chip generation (EV1/EV2/EV3/...), distinct from and unrelated to the
/// Ultralight/NTAG `GET_VERSION` format (`ChipVersion` in
/// `ccid_tag_info.dart`).
class DesfireVersion {
  final int hardwareVendorId;
  final int hardwareType;
  final int hardwareSubtype;
  final int hardwareMajor;
  final int hardwareMinor;
  final int hardwareStorageSize;
  final int hardwareProtocol;
  final int softwareVendorId;
  final int softwareType;
  final int softwareSubtype;
  final int softwareMajor;
  final int softwareMinor;
  final int softwareStorageSize;
  final int softwareProtocol;
  final List<int> uid;
  final List<int> batch;
  final int productionWeek;
  final int productionYear;

  const DesfireVersion({
    required this.hardwareVendorId,
    required this.hardwareType,
    required this.hardwareSubtype,
    required this.hardwareMajor,
    required this.hardwareMinor,
    required this.hardwareStorageSize,
    required this.hardwareProtocol,
    required this.softwareVendorId,
    required this.softwareType,
    required this.softwareSubtype,
    required this.softwareMajor,
    required this.softwareMinor,
    required this.softwareStorageSize,
    required this.softwareProtocol,
    required this.uid,
    required this.batch,
    required this.productionWeek,
    required this.productionYear,
  });
}

/// Resolves a generation label from [version]'s hardware type/major/minor
/// bytes, per the Proxmark3 project's field-validated `getCardType()`
/// table. Reports an explicit "unrecognized" message (with the raw bytes)
/// rather than guessing when the combination isn't in the table.
String desfireGenerationLabel(DesfireVersion version) {
  final type = version.hardwareType;
  final major = version.hardwareMajor;
  final minor = version.hardwareMinor;
  if (type == 0x01 && major == 0x00 && minor == 0x02) {
    return 'DESFire (original, MF3ICD40)';
  }
  if (type == 0x01 && major == 0x01 && minor == 0x00) return 'DESFire EV1';
  if (type == 0x01 && major == 0x12 && minor == 0x00) return 'DESFire EV2';
  if (type == 0x01 && major == 0x22 && minor == 0x00) {
    return 'DESFire EV2 XL';
  }
  if (type == 0x01 && major == 0x33 && minor == 0x00) return 'DESFire EV3';
  if (type == 0x81 && major == 0x43 && minor == 0x01) {
    return 'DESFire EV3 (microcontroller)';
  }
  if (type == 0x01 && major == 0xA0 && minor == 0x00) return 'DUOX';
  if (type == 0x08 && major == 0x30 && minor == 0x00) {
    return 'DESFire Light';
  }
  if (type == 0x81 && major == 0x42 && minor == 0x00) {
    return 'DESFire EV2 (combo DESFire/EMV)';
  }
  return 'Unrecognized DESFire generation (type=0x'
      '${type.toRadixString(16).padLeft(2, '0')}, major=0x'
      '${major.toRadixString(16).padLeft(2, '0')}, minor=0x'
      '${minor.toRadixString(16).padLeft(2, '0')})';
}
```

In `lib/ccid_iso_dep.dart`, add the import and the method:

```dart
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'ccid_desfire_info.dart';
import 'ccid_tag_driver.dart';

export 'ccid_desfire_info.dart' show DesfireVersion;

class IsoDepTag extends TagDriver {
  IsoDepTag(super.card);

  Future<String?> selectApplication(String aidHex) {
    final lcHex = (aidHex.length ~/ 2).toRadixString(16).padLeft(2, '0');
    return card.transceive('00A40400$lcHex$aidHex');
  }

  Future<String?> transceive(String capdu) => card.transceive(capdu);

  /// Reads the card's DESFire `GetVersion` (native command `0x60`),
  /// identifying the exact chip generation. Only valid for DESFire-class
  /// cards; on anything else this will throw or return garbage.
  Future<DesfireVersion> readDesfireVersion() async {
    final hwFrame = await _desfireFrame('60');
    if (hwFrame.isEmpty || hwFrame[0] != 0xAF) {
      throw Exception(
          'Unexpected DESFire GetVersion response (hardware frame): $hwFrame');
    }
    final hw = hwFrame.sublist(1);

    final swFrame = await _desfireFrame('AF');
    if (swFrame.isEmpty || swFrame[0] != 0xAF) {
      throw Exception(
          'Unexpected DESFire GetVersion response (software frame): $swFrame');
    }
    final sw = swFrame.sublist(1);

    final tailFrame = await _desfireFrame('AF');
    if (tailFrame.isEmpty || tailFrame[0] != 0x00) {
      throw Exception(
          'Unexpected DESFire GetVersion response (UID/batch frame): $tailFrame');
    }
    final tail = tailFrame.sublist(1);

    if (hw.length != 7 || sw.length != 7 || tail.length != 14) {
      throw Exception('Malformed DESFire GetVersion frame lengths '
          '(hw=${hw.length}, sw=${sw.length}, tail=${tail.length})');
    }

    return DesfireVersion(
      hardwareVendorId: hw[0],
      hardwareType: hw[1],
      hardwareSubtype: hw[2],
      hardwareMajor: hw[3],
      hardwareMinor: hw[4],
      hardwareStorageSize: hw[5],
      hardwareProtocol: hw[6],
      softwareVendorId: sw[0],
      softwareType: sw[1],
      softwareSubtype: sw[2],
      softwareMajor: sw[3],
      softwareMinor: sw[4],
      softwareStorageSize: sw[5],
      softwareProtocol: sw[6],
      uid: tail.sublist(0, 7),
      batch: tail.sublist(7, 12),
      productionWeek: tail[12],
      productionYear: tail[13],
    );
  }

  /// Sends [capdu] (raw, no ISO7816 wrapping -- DESFire's native mode)
  /// and returns the decoded response bytes. Per ACS's ACR122U
  /// documentation, native-mode DESFire responses of 2+ bytes carry no
  /// appended PC/SC status word at all, unlike every other read in this
  /// plugin -- the full response already IS the data, with byte 0
  /// carrying DESFire's own continuation status (`0xAF` = more frames,
  /// `0x00` = last frame) instead of an ISO status word.
  Future<Uint8List> _desfireFrame(String capdu) async {
    final responseHex = await card.transceive(capdu);
    if (responseHex == null || responseHex.isEmpty) {
      throw Exception('No response to DESFire command $capdu');
    }
    return Uint8List.fromList(hex.decode(responseHex));
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/ccid_desfire_info_test.dart test/ccid_iso_dep_test.dart`
Expected: PASS (all tests)

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_desfire_info.dart lib/ccid_iso_dep.dart test/ccid_desfire_info_test.dart test/ccid_iso_dep_test.dart
git commit -m "feat: add DESFire GetVersion and generation decoding"
```

---

### Task 9: `TypeBTag` and `identifyTag()` fallback

**Files:**
- Create: `lib/ccid_iso_b.dart`
- Modify: `lib/ccid_tag_detection.dart`
- Modify: `lib/ccid.dart` (add export)
- Test: `test/ccid_iso_b_test.dart`, `test/ccid_tag_detection_test.dart`

**Interfaces:**
- Consumes: `pollTypeB` (Task 2), `TagDriver`/`UnrecognizedTagException` (existing).
- Produces: `class TypeBTag extends TagDriver { atqb; Future<String?> transceive(String capdu); }`. Task 10's `TypeBTag.readTagInfo()` depends on this.

- [ ] **Step 1: Write the failing tests**

Create `test/ccid_iso_b_test.dart`:

```dart
import 'dart:typed_data';

import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async =>
      responses[capdu];

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}

void main() {
  tearDown(() {
    CcidPlatform.instance = null;
  });

  test('transceive() passes the APDU straight through to the card',
      () async {
    CcidPlatform.instance = _FakeCcidPlatform({'00B0000000': 'AABB9000'});
    final tag = TypeBTag(CcidCard('fake-reader'), Uint8List(12));

    final response = await tag.transceive('00B0000000');

    expect(response, equals('AABB9000'));
  });

  test('stores the ATQB it was constructed with', () {
    final atqb = Uint8List.fromList(List.filled(12, 0x11));
    final tag = TypeBTag(CcidCard('fake-reader'), atqb);

    expect(tag.atqb, equals(atqb));
  });
}
```

Add to `test/ccid_tag_detection_test.dart`, inside the `'identifyTag() probing fallback (no ATR)'` group:

```dart
test('recognizes a Type B card via the PN532 poll when nothing else '
    'matches', () async {
  CcidPlatform.instance = _FakeCcidPlatform({
    'FFCA000000': null,
    'FF00000004D44A0103':
        'D54B' '01' '01' '${'11' * 12}' '00' '9000',
  });
  final card = CcidCard('fake-reader');

  final driver = await identifyTag(card);

  expect(driver, isA<TypeBTag>());
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/ccid_iso_b_test.dart test/ccid_tag_detection_test.dart`
Expected: FAIL — `package:ccid/ccid_iso_b.dart` doesn't exist / `TypeBTag` isn't defined

- [ ] **Step 3: Implement**

Create `lib/ccid_iso_b.dart`:

```dart
import 'dart:typed_data';

import 'ccid_tag_driver.dart';

/// Thin driver for an ISO14443-B card, found via a raw PN532 poll
/// ([pollTypeB] in `src/pn532.dart`) rather than the ATR/capability-probing
/// path the other families use (Type B isn't reachable through either of
/// those). Exposes the card's ATQB plus raw ISO7816 APDU passthrough,
/// mirroring [IsoDepTag]'s shape.
class TypeBTag extends TagDriver {
  final Uint8List atqb;

  TypeBTag(super.card, this.atqb);

  Future<String?> transceive(String capdu) => card.transceive(capdu);
}
```

In `lib/ccid_tag_detection.dart`, add the import and the new fallback step. Change the end of `_identifyByProbing` from:

```dart
  throw UnrecognizedTagException(
    'Card did not match any known tag family (Type 2, MIFARE Classic, '
    'FeliCa, or ISO-DEP). ${log.join('; ')}',
  );
}
```

to:

```dart
  try {
    final typeBTarget = await pollTypeB(card);
    if (typeBTarget != null) {
      log.add('Type B poll -> succeeded, atqb=${hex.encode(typeBTarget.atqb)}');
      return TypeBTag(card, typeBTarget.atqb);
    }
    log.add('Type B poll -> no target found');
  } catch (e) {
    log.add('Type B poll -> failed: $e');
  }

  throw UnrecognizedTagException(
    'Card did not match any known tag family (Type 2, MIFARE Classic, '
    'FeliCa, ISO-DEP, or ISO14443-B). ${log.join('; ')}',
  );
}
```

Add the import at the top of `lib/ccid_tag_detection.dart`:

```dart
import 'ccid_iso_b.dart';
import 'src/pn532.dart';
```

In `lib/ccid.dart`, add the export line:

```dart
export 'ccid_iso_b.dart' show TypeBTag;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/ccid_iso_b_test.dart test/ccid_tag_detection_test.dart`
Expected: PASS (all tests)

- [ ] **Step 5: Run the full suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_iso_b.dart lib/ccid_tag_detection.dart lib/ccid.dart test/ccid_iso_b_test.dart test/ccid_tag_detection_test.dart
git commit -m "feat: add TypeBTag and identifyTag() Type B fallback"
```

---

### Task 10: `TagInfo` and `readTagInfo()` on every driver

**Files:**
- Modify: `lib/ccid_tag_driver.dart` (add `TagInfo`)
- Modify: `lib/ccid_type2.dart` (add `Type2TagInfo`, `readTagInfo()`)
- Modify: `lib/ccid_mifare_classic.dart` (add `MifareClassicInfo`, `readTagInfo()`)
- Modify: `lib/ccid_felica.dart` (add `FelicaInfo`, `readTagInfo()`)
- Modify: `lib/ccid_iso_dep.dart` (add `IsoDepInfo`, `readTagInfo()`)
- Modify: `lib/ccid_iso_b.dart` (add `TypeBInfo`, `readTagInfo()`)
- Modify: `lib/ccid.dart` (export the 5 new `*Info` classes)
- Test: one new test per driver file (`test/ccid_type2_test.dart` new, others added to existing files)

**Interfaces:**
- Consumes: everything from Tasks 2-9.
- Produces: `readTagInfo()` on all 5 drivers, each returning a `TagInfo` subclass. Task 11 (example app) depends on this.

- [ ] **Step 1: Add the `TagInfo` base class**

In `lib/ccid_tag_driver.dart`, add below `TagDriver`:

```dart
/// A generic identification summary common to every tag family, returned
/// by each driver's `readTagInfo()`. Concrete subclasses (`Type2TagInfo`,
/// `MifareClassicInfo`, `FelicaInfo`, `IsoDepInfo`, `TypeBInfo`) add
/// family-specific fields.
abstract class TagInfo {
  String get technology;
  Uint8List get uid;
  Uint8List? get atr;
}
```

Add `import 'dart:typed_data';` at the top of `lib/ccid_tag_driver.dart` if not already present.

- [ ] **Step 2: `Type2TagInfo` + `Type2Tag.readTagInfo()`**

In `lib/ccid_type2.dart`, add:

```dart
class Type2TagInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid;
  @override
  final Uint8List? atr;
  final CapabilityContainer? capabilityContainer;

  const Type2TagInfo({
    required this.technology,
    required this.uid,
    required this.atr,
    required this.capabilityContainer,
  });
}
```

and, on `Type2Tag`:

```dart
  /// A generic identification summary: UID, ATR, and the Capability
  /// Container if the tag has one (best-effort -- a read failure here
  /// doesn't prevent returning the rest of the info).
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
      atr: card.atr,
      capabilityContainer: cc,
    );
  }
```

- [ ] **Step 3: `MifareClassicInfo` + `MifareClassicTag.readTagInfo()`**

In `lib/ccid_mifare_classic.dart`, add the imports:

```dart
import 'ccid_mifare_info.dart';
import 'src/pn532.dart';
```

Add:

```dart
class MifareClassicInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid;
  @override
  final Uint8List? atr;
  final int sak;
  final Uint8List atqa;

  const MifareClassicInfo({
    required this.technology,
    required this.uid,
    required this.atr,
    required this.sak,
    required this.atqa,
  });
}
```

and, on `MifareClassicTag`:

```dart
  /// A generic identification summary using the real SAK/ATQA read
  /// directly from the card via a PN532 poll, independent of the ATR.
  Future<MifareClassicInfo> readTagInfo() async {
    final target = await pollTypeA(card);
    if (target == null) {
      throw Exception('No Type A target found while reading tag info');
    }
    final family = mifareFamilyFromSak(target.sak);
    return MifareClassicInfo(
      technology: mifareFamilyLabel(family),
      uid: target.uid,
      atr: card.atr,
      sak: target.sak,
      atqa: target.atqa,
    );
  }
```

- [ ] **Step 4: `FelicaInfo` + `FelicaTag.readTagInfo()`**

In `lib/ccid_felica.dart`, add the import:

```dart
import 'ccid_felica_info.dart';
```

Add:

```dart
class FelicaInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid; // IDm
  @override
  final Uint8List? atr;
  final Uint8List pmm;
  final String? modelName;
  final List<int> systemCodes;

  const FelicaInfo({
    required this.technology,
    required this.uid,
    required this.atr,
    required this.pmm,
    required this.modelName,
    required this.systemCodes,
  });
}
```

and, on `FelicaTag`:

```dart
  /// A generic identification summary: IDm, PMm-derived chip model
  /// (community-sourced -- see [felicaModelName]), and every System Code
  /// on the card (best-effort -- a failure here doesn't prevent returning
  /// the rest of the info).
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
      atr: card.atr,
      pmm: cardPmm,
      modelName: model,
      systemCodes: systemCodes,
    );
  }
```

- [ ] **Step 5: `IsoDepInfo` + `IsoDepTag.readTagInfo()`**

In `lib/ccid_iso_dep.dart`, add the import:

```dart
import 'src/pn532.dart';
```

Add:

```dart
class IsoDepInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid;
  @override
  final Uint8List? atr;
  final DesfireVersion? desfireVersion;

  const IsoDepInfo({
    required this.technology,
    required this.uid,
    required this.atr,
    required this.desfireVersion,
  });
}
```

and, on `IsoDepTag`:

```dart
  /// A generic identification summary. Attempts a DESFire `GetVersion`
  /// (best-effort -- most non-DESFire ISO14443-4 cards will fail this,
  /// which is expected and doesn't prevent returning the rest of the info).
  Future<IsoDepInfo> readTagInfo() async {
    final target = await pollTypeA(card);
    final tagUid = target?.uid ?? Uint8List(0);
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
      atr: card.atr,
      desfireVersion: version,
    );
  }
```

- [ ] **Step 6: `TypeBInfo` + `TypeBTag.readTagInfo()`**

In `lib/ccid_iso_b.dart`, add:

```dart
class TypeBInfo implements TagInfo {
  @override
  final String technology = 'ISO14443-B';
  @override
  final Uint8List uid; // PUPI, 4 bytes
  @override
  final Uint8List? atr;
  final Uint8List atqb;

  TypeBInfo({required this.uid, required this.atr, required this.atqb});
}
```

and, on `TypeBTag`:

```dart
  /// A generic identification summary. UID is the PUPI (bytes 1-4 of
  /// ATQB, per ISO14443-3's ATQB structure: `'50' | PUPI(4) | ...`).
  Future<TypeBInfo> readTagInfo() async {
    return TypeBInfo(
      uid: Uint8List.sublistView(atqb, 1, 5),
      atr: card.atr,
      atqb: atqb,
    );
  }
```

- [ ] **Step 7: Export the new `*Info` classes**

In `lib/ccid.dart`, update the existing export lines to include the new classes (alphabetical order preserved):

```dart
export 'ccid_felica.dart' show FelicaInfo, FelicaTag, FelicaReadResult;
export 'ccid_iso_b.dart' show TypeBInfo, TypeBTag;
export 'ccid_iso_dep.dart' show IsoDepInfo, IsoDepTag;
export 'ccid_mifare_classic.dart'
    show MifareClassicInfo, MifareClassicTag, MifareKeyType, MifareAuthException;
export 'ccid_tag_driver.dart' show TagDriver, TagInfo, UnrecognizedTagException;
export 'ccid_type2.dart' show Type2Tag, Type2TagInfo;
```

- [ ] **Step 8: Write tests**

Create `test/ccid_type2_test.dart` (new file — `Type2Tag`'s only prior test coverage was incidental via `readNdef()` in `test/ccid_test.dart`):

```dart
import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async =>
      responses[capdu];

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}

void main() {
  tearDown(() {
    CcidPlatform.instance = null;
  });

  test('readTagInfo() returns UID and the parsed Capability Container',
      () async {
    CcidPlatform.instance = _FakeCcidPlatform({
      'FFCA000000': '${hex.encode([0x04, 0x01, 0x02, 0x03])}9000',
      'FFB0000304': 'E11006009000',
    });
    final tag = Type2Tag(CcidCard('fake-reader'));

    final info = await tag.readTagInfo();

    expect(info.uid, equals([0x04, 0x01, 0x02, 0x03]));
    expect(info.capabilityContainer, isNotNull);
    expect(info.capabilityContainer!.isNdefFormatted, isTrue);
  });
}
```

Add to `test/ccid_mifare_classic_test.dart`:

```dart
test('readTagInfo() resolves the family from a real PN532 poll', () async {
  final fake = _FakeCcidPlatform({
    'FF00000004D44A0100': 'D54B01010044080704010203040506' '9000',
  });
  CcidPlatform.instance = fake;
  final tag = MifareClassicTag(CcidCard('fake-reader'));

  final info = await tag.readTagInfo();

  expect(info.technology, equals('MIFARE Classic 1K'));
  expect(info.sak, equals(0x08));
  expect(info.uid, equals([0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]));
});
```

Add to `test/ccid_felica_test.dart`:

```dart
test('readTagInfo() combines idm, pmm-derived model, and system codes',
    () async {
  const pollCapdu = 'FF00000009D440010600FFFF0000';
  const pmmHex = '0135428282468CFF';
  const pollResponse = 'D541001201$idmHex${pmmHex}9000';
  const requestCapdu = 'FF0000000DD440010A0CAABBCCDDEE001122';
  // 1 system code (90E3): len=0D (13 bytes: len+respCode+idm(8)+
  // numSystems+1 system code).
  const requestResponse = 'D541000D' '0D' idmHex '01' '90E3' '9000';
  final fake = _FakeCcidPlatform({
    pollCapdu: pollResponse,
    requestCapdu: requestResponse,
  });
  CcidPlatform.instance = fake;
  final tag = FelicaTag(CcidCard('fake-reader'));

  final info = await tag.readTagInfo();

  expect(info.technology, equals('FeliCa (RC-SA01/2)'));
  expect(info.systemCodes, equals([0x90E3]));
});
```

Add to `test/ccid_iso_b_test.dart`:

```dart
test('readTagInfo() extracts the PUPI from ATQB', () async {
  final atqb = Uint8List.fromList(
      [0x50, 0x11, 0x22, 0x33, 0x44, 0, 0, 0, 0, 0, 0, 0]);
  final tag = TypeBTag(CcidCard('fake-reader'), atqb);

  final info = await tag.readTagInfo();

  expect(info.uid, equals([0x11, 0x22, 0x33, 0x44]));
  expect(info.technology, equals('ISO14443-B'));
});
```

(No `IsoDepTag.readTagInfo()` test is required in this task — it composes `pollTypeA` and `readDesfireVersion`, both already tested independently in Tasks 2 and 8; a dedicated integration test would just re-assert their already-covered behavior.)

- [ ] **Step 9: Run tests to verify they pass**

Run: `flutter test`
Expected: PASS (all tests, including all new ones from this task)

- [ ] **Step 10: Run the analyzer**

Run: `flutter analyze lib example/lib test`
Expected: `No issues found!`

- [ ] **Step 11: Commit**

```bash
git add lib/ccid_tag_driver.dart lib/ccid_type2.dart lib/ccid_mifare_classic.dart lib/ccid_felica.dart lib/ccid_iso_dep.dart lib/ccid_iso_b.dart lib/ccid.dart test/ccid_type2_test.dart test/ccid_mifare_classic_test.dart test/ccid_felica_test.dart test/ccid_iso_b_test.dart
git commit -m "feat: add TagInfo and readTagInfo() on every driver"
```

---

### Task 11: Example app — "Tag Info" section

**Files:**
- Modify: `example/lib/tag_details_page.dart`

**Interfaces:**
- Consumes: `readTagInfo()` on all 5 drivers (Task 10).

- [ ] **Step 1: Add a "Tag Info" section shown for every driver type**

In `example/lib/tag_details_page.dart`, add a new private method and wire it into `_loadAll` (called first, before the family-specific branch) and `_sectionTitlesFor` (prepend `'Tag Info'` to every branch's list):

```dart
  Future<void> _loadTagInfo(TagDriver driver) async {
    await _load('Tag Info', () async {
      final TagInfo info;
      if (driver is Type2Tag) {
        info = await driver.readTagInfo();
      } else if (driver is MifareClassicTag) {
        info = await driver.readTagInfo();
      } else if (driver is FelicaTag) {
        info = await driver.readTagInfo();
      } else if (driver is IsoDepTag) {
        info = await driver.readTagInfo();
      } else if (driver is TypeBTag) {
        info = await driver.readTagInfo();
      } else {
        return 'Unsupported driver type';
      }
      final lines = [
        'Technology: ${info.technology}',
        'UID: ${_hex(info.uid)}',
        'ATR: ${info.atr == null ? '(none)' : _hex(info.atr!)}',
      ];
      if (info is FelicaInfo && info.systemCodes.isNotEmpty) {
        lines.add('System codes: ${info.systemCodes.map((c) => '0x${c.toRadixString(16).padLeft(4, '0').toUpperCase()}').join(', ')}');
      }
      if (info is IsoDepInfo && info.desfireVersion != null) {
        lines.add('DESFire UID: ${_hex(info.desfireVersion!.uid)}');
      }
      return lines.join('\n');
    });
  }
```

Update `_loadAll` to call this first:

```dart
  Future<void> _loadAll() async {
    final driver = widget.driver;
    await _loadTagInfo(driver);
    if (driver is Type2Tag) {
```

(leave the rest of the existing `if`/`else if` chain in `_loadAll` unchanged).

Update `_sectionTitlesFor` to prepend `'Tag Info'` to every branch's returned list — e.g. `return ['Tag Info', 'UID', 'Capability Container', ...]` for the `Type2Tag` branch, `return ['Tag Info', 'Sector 0']` for `MifareClassicTag`, `return ['Tag Info', 'IDm', 'Transactions']` for `FelicaTag`, `return ['Tag Info', 'SELECT (empty AID)']` for `IsoDepTag`, and add a new final branch:

```dart
    } else if (driver is TypeBTag) {
      return ['Tag Info'];
    }
```

- [ ] **Step 2: Verify the example app compiles and analyzes cleanly**

Run: `cd example && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add example/lib/tag_details_page.dart
git commit -m "feat: show a Tag Info section for every driver type in the example app"
```

---

### Task 12: CHANGELOG and version bump

**Files:**
- Modify: `pubspec.yaml`
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Bump the version**

In `pubspec.yaml`, change the version line to `0.3.0` (minor bump for new public API surface: `TagInfo`, `readTagInfo()` on every driver, `TypeBTag`, `DesfireVersion`, `PassiveTargetTypeA`/`PassiveTargetTypeB` — no breaking changes this time).

- [ ] **Step 2: Add a CHANGELOG entry**

Insert at the top of `CHANGELOG.md`, before the `## 0.2.0` entry:

```markdown
## 0.3.0

* Add `readTagInfo()` to every tag driver (`Type2Tag`, `MifareClassicTag`, `FelicaTag`, `IsoDepTag`, `TypeBTag`), returning a common `TagInfo` (technology, UID, ATR) plus family-specific details (SAK/ATQA, FeliCa PMm-derived chip model and system codes, DESFire generation).
* Add real SAK/ATQA identification via a new PN532 `InListPassiveTarget` poll (`pollTypeA`/`pollTypeB` in `src/pn532.dart`), independent of the ATR.
* Add `FelicaTag.pmm` and `FelicaTag.requestSystemCodes()`.
* Add `IsoDepTag.readDesfireVersion()`, decoding DESFire's 3-frame `GetVersion` exchange into `DesfireVersion` and resolving the exact generation (EV1/EV2/EV3/EV2 XL/DUOX/Light) via `desfireGenerationLabel()`.
* Add `TypeBTag`, a new ISO14443-B driver, and a matching `identifyTag()` fallback step.
* FeliCa chip-model and System Code labels are sourced from community reverse-engineering projects, not an official Sony publication — see the doc comments on `felicaModelName`/`felicaSystemCodeLabel`.
```

- [ ] **Step 3: Verify the package still resolves**

Run: `flutter pub get`
Expected: exits successfully, no version-resolution errors

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: bump version to 0.3.0"
```
