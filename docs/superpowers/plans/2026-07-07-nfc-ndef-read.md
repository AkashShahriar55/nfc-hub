# NDEF Read Support for Type 2 NFC Tags Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let `ccid` read the NDEF message (Text/URI records) off an NFC Forum Type 2 Tag (NTAG213/215/216, Mifare Ultralight) through the existing PC/SC `transceive()` channel, and expose a "Read NFC Tag" button in the example app to verify this against a real ACR1122U reader.

**Architecture:** Pure-Dart NDEF parsing (`lib/ccid_ndef.dart`) is layered on top of the existing `CcidCard.transceive()` APDU channel via a new `CcidCard.readNdef()` method in `lib/ccid.dart`. No native/platform code changes — this works on every platform the plugin already supports.

**Tech Stack:** Dart, `package:convert` (hex codec, already a dependency), `flutter_test`.

## Global Constraints

- Type 2 Tags only (NTAG21x, Mifare Ultralight); Type 4 (ISO7816 NDEF applet) tags are out of scope.
- Read-only — no NDEF writing/formatting.
- Capability Container size byte is assumed to use the common single-byte encoding (`size * 8` bytes); the 3-byte extended CC size format is not handled.
- No hardware-in-the-loop automated tests. Only the pure TLV/record parsing logic (Task 1) gets automated unit tests; the APDU orchestration in `readNdef()` (Task 2) is verified manually against a real ACR1122U + tag (Task 3).
- No new dependencies — `convert: ^3.1.2` is already in `pubspec.yaml` and provides the `hex` codec used elsewhere in this package (see `lib/ccid_pcsc.dart`).

---

### Task 1: NDEF TLV/record parsing library

**Files:**
- Create: `lib/ccid_ndef.dart`
- Test: `test/ccid_ndef_test.dart`

**Interfaces:**
- Produces: `class NdefRecord { int tnf; Uint8List type; Uint8List id; Uint8List payload; String get typeString; String? get asText; String? get asUri; String toString(); }`
- Produces: `Uint8List? parseTlvForNdefMessage(Uint8List data)` — scans Type-2-Tag TLV blocks, returns the value of the first NDEF Message TLV (tag `0x03`), or `null` if none found.
- Produces: `List<NdefRecord> parseNdefRecords(Uint8List message)` — parses a raw NDEF message into records.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_ndef_test.dart`:

```dart
import 'dart:typed_data';

import 'package:ccid/ccid_ndef.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseTlvForNdefMessage', () {
    test('extracts the NDEF Message TLV value and stops at the terminator', () {
      final message = Uint8List.fromList([
        0xD1, 0x01, 0x08, 0x54, // flags, typeLength, payloadLength, type 'T'
        0x02, 0x65, 0x6E, // status byte (lang len 2, UTF-8), 'en'
        0x68, 0x65, 0x6C, 0x6C, 0x6F, // 'hello'
      ]);
      final tlv = Uint8List.fromList([
        0x03, message.length, // NDEF Message TLV tag + length
        ...message,
        0xFE, // Terminator TLV
      ]);

      final result = parseTlvForNdefMessage(tlv);

      expect(result, isNotNull);
      expect(result, equals(message));
    });

    test('returns null when there is no NDEF Message TLV', () {
      final tlv = Uint8List.fromList([0x00, 0x00, 0xFE]);

      expect(parseTlvForNdefMessage(tlv), isNull);
    });
  });

  group('parseNdefRecords', () {
    test('decodes a single well-known Text record', () {
      final message = Uint8List.fromList([
        0xD1, 0x01, 0x08, 0x54, // flags(MB,ME,SR,TNF=1), typeLength=1, payloadLength=8, type 'T'
        0x02, 0x65, 0x6E, // status byte (lang len 2, UTF-8), 'en'
        0x68, 0x65, 0x6C, 0x6C, 0x6F, // 'hello'
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(1));
      expect(records[0].tnf, equals(1));
      expect(records[0].typeString, equals('T'));
      expect(records[0].asText, equals('hello'));
      expect(records[0].asUri, isNull);
    });

    test('decodes a single well-known URI record', () {
      final message = Uint8List.fromList([
        0xD1, 0x01, 0x0C, 0x55, // flags(MB,ME,SR,TNF=1), typeLength=1, payloadLength=12, type 'U'
        0x01, // URI prefix code 0x01 -> 'http://www.'
        0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x2E, 0x63, 0x6F, 0x6D, // 'example.com'
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(1));
      expect(records[0].typeString, equals('U'));
      expect(records[0].asUri, equals('http://www.example.com'));
      expect(records[0].asText, isNull);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_ndef_test.dart`
Expected: FAIL — `Error: Error when reading 'lib/ccid_ndef.dart': No such file or directory` (or equivalent "package:ccid/ccid_ndef.dart" not found compile error).

- [ ] **Step 3: Write the implementation**

Create `lib/ccid_ndef.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';

/// A single NDEF record decoded from a tag's NDEF message.
class NdefRecord {
  /// Type Name Format, identifies how [type] should be interpreted.
  final int tnf;

  /// The record type (e.g. 'T' for Text, 'U' for URI).
  final Uint8List type;

  /// The record id, empty if not present.
  final Uint8List id;

  /// The raw record payload.
  final Uint8List payload;

  NdefRecord({
    required this.tnf,
    required this.type,
    required this.id,
    required this.payload,
  });

  static const int _tnfWellKnown = 0x01;

  static const List<String> _uriPrefixes = [
    '', // 0x00
    'http://www.', // 0x01
    'https://www.', // 0x02
    'http://', // 0x03
    'https://', // 0x04
    'tel:', // 0x05
    'mailto:', // 0x06
    'ftp://anonymous:anonymous@', // 0x07
    'ftp://ftp.', // 0x08
    'ftps://', // 0x09
    'sftp://', // 0x0A
    'smb://', // 0x0B
    'nfs://', // 0x0C
    'ftp://', // 0x0D
    'dav://', // 0x0E
    'news:', // 0x0F
    'telnet://', // 0x10
    'imap:', // 0x11
    'rtsp://', // 0x12
    'urn:', // 0x13
    'pop:', // 0x14
    'sip:', // 0x15
    'sips:', // 0x16
    'tftp:', // 0x17
    'btspp://', // 0x18
    'btl2cap://', // 0x19
    'btgoep://', // 0x1A
    'tcpobex://', // 0x1B
    'irdaobex://', // 0x1C
    'file://', // 0x1D
    'urn:epc:id:', // 0x1E
    'urn:epc:tag:', // 0x1F
    'urn:epc:pat:', // 0x20
    'urn:epc:raw:', // 0x21
    'urn:epc:', // 0x22
    'urn:nfc:', // 0x23
  ];

  /// The record [type] decoded as a UTF-8 string.
  String get typeString => utf8.decode(type, allowMalformed: true);

  /// Decodes this record as an NFC Forum well-known Text record ('T').
  ///
  /// Returns null if this is not a Text record.
  String? get asText {
    if (tnf != _tnfWellKnown || typeString != 'T' || payload.isEmpty) {
      return null;
    }
    final statusByte = payload[0];
    final isUtf16 = (statusByte & 0x80) != 0;
    final languageCodeLength = statusByte & 0x3F;
    final textStart = 1 + languageCodeLength;
    if (textStart > payload.length) return null;
    final textBytes = payload.sublist(textStart);
    return isUtf16
        ? String.fromCharCodes(textBytes)
        : utf8.decode(textBytes, allowMalformed: true);
  }

  /// Decodes this record as an NFC Forum well-known URI record ('U').
  ///
  /// Returns null if this is not a URI record.
  String? get asUri {
    if (tnf != _tnfWellKnown || typeString != 'U' || payload.isEmpty) {
      return null;
    }
    final prefixCode = payload[0];
    final prefix =
        prefixCode < _uriPrefixes.length ? _uriPrefixes[prefixCode] : '';
    final suffix = utf8.decode(payload.sublist(1), allowMalformed: true);
    return '$prefix$suffix';
  }

  String _hex() =>
      payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() {
    final text = asText;
    if (text != null) return 'Text: $text';
    final uri = asUri;
    if (uri != null) return 'URI: $uri';
    return 'NdefRecord(tnf: $tnf, type: $typeString, payload: ${_hex()})';
  }
}

/// Scans [data] for TLV blocks (as used by NFC Forum Type 2 Tags) and
/// returns the value of the first NDEF Message TLV (tag 0x03), or null
/// if none is found.
Uint8List? parseTlvForNdefMessage(Uint8List data) {
  var i = 0;
  while (i < data.length) {
    final tag = data[i];
    if (tag == 0x00) {
      // NULL TLV: no length/value, skip.
      i += 1;
      continue;
    }
    if (tag == 0xFE) {
      // Terminator TLV.
      break;
    }
    if (i + 1 >= data.length) break;
    var length = data[i + 1];
    var valueStart = i + 2;
    if (length == 0xFF) {
      if (i + 3 >= data.length) break;
      length = (data[i + 2] << 8) | data[i + 3];
      valueStart = i + 4;
    }
    final valueEnd = valueStart + length;
    if (valueEnd > data.length) break;
    if (tag == 0x03) {
      return data.sublist(valueStart, valueEnd);
    }
    i = valueEnd;
  }
  return null;
}

/// Parses a raw NDEF message (the value of an NDEF Message TLV) into a
/// list of [NdefRecord]s.
List<NdefRecord> parseNdefRecords(Uint8List message) {
  final records = <NdefRecord>[];
  var i = 0;
  while (i < message.length) {
    final flags = message[i];
    final sr = (flags & 0x10) != 0;
    final il = (flags & 0x08) != 0;
    final tnf = flags & 0x07;
    final me = (flags & 0x40) != 0;
    i += 1;

    if (i >= message.length) break;
    final typeLength = message[i];
    i += 1;

    int payloadLength;
    if (sr) {
      if (i >= message.length) break;
      payloadLength = message[i];
      i += 1;
    } else {
      if (i + 4 > message.length) break;
      payloadLength = (message[i] << 24) |
          (message[i + 1] << 16) |
          (message[i + 2] << 8) |
          message[i + 3];
      i += 4;
    }

    var idLength = 0;
    if (il) {
      if (i >= message.length) break;
      idLength = message[i];
      i += 1;
    }

    if (i + typeLength > message.length) break;
    final type = message.sublist(i, i + typeLength);
    i += typeLength;

    if (i + idLength > message.length) break;
    final id = message.sublist(i, i + idLength);
    i += idLength;

    if (i + payloadLength > message.length) break;
    final payload = message.sublist(i, i + payloadLength);
    i += payloadLength;

    records.add(NdefRecord(tnf: tnf, type: type, id: id, payload: payload));

    if (me) break;
  }
  return records;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_ndef_test.dart`
Expected: PASS — `00:00 +4: All tests passed!`

- [ ] **Step 5: Commit**

```bash
git add lib/ccid_ndef.dart test/ccid_ndef_test.dart
git commit -m "feat: add NDEF TLV and record parsing for Type 2 tags"
```

---

### Task 2: `CcidCard.readNdef()`

**Files:**
- Modify: `lib/ccid.dart`

**Interfaces:**
- Consumes (from Task 1): `NdefRecord`, `Uint8List? parseTlvForNdefMessage(Uint8List)`, `List<NdefRecord> parseNdefRecords(Uint8List)`.
- Consumes (existing): `Future<String?> CcidCard.transceive(String capdu)` (`lib/ccid.dart:27-29`).
- Produces: `Future<List<NdefRecord>> CcidCard.readNdef()`, and re-exports `NdefRecord` from `package:ccid/ccid.dart`.

This task has no automated test (per Global Constraints) — `readNdef()` only composes the already-tested parsing functions from Task 1 with the existing `transceive()` API, and needs a real contactless reader + tag to exercise meaningfully. It's verified manually in Task 3.

- [ ] **Step 1: Modify `lib/ccid.dart`**

Current content (for reference):

```dart
import 'ccid_platform_interface.dart';

class Ccid {
  /// List available readers
  ///
  /// Returns a list of reader names
  Future<List<String>> listReaders() {
    return CcidPlatform.instance.listReaders();
  }

  /// Connect to a reader by its name [reader]
  ///
  /// Returns a [CcidCard] object
  Future<CcidCard> connect(String reader) {
    return CcidPlatform.instance.connect(reader);
  }
}

class CcidCard {
  final String reader;

  CcidCard(this.reader);

  /// Send APDU command [cpadu]
  ///
  /// Returns the response APDU
  Future<String?> transceive(String capdu) {
    return CcidPlatform.instance.transceive(reader, capdu);
  }

  /// Disconnect from the card
  Future<void> disconnect() {
    return CcidPlatform.instance.disconnect(reader);
  }
}
```

Replace it with:

```dart
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'ccid_ndef.dart';
import 'ccid_platform_interface.dart';

export 'ccid_ndef.dart' show NdefRecord;

class Ccid {
  /// List available readers
  ///
  /// Returns a list of reader names
  Future<List<String>> listReaders() {
    return CcidPlatform.instance.listReaders();
  }

  /// Connect to a reader by its name [reader]
  ///
  /// Returns a [CcidCard] object
  Future<CcidCard> connect(String reader) {
    return CcidPlatform.instance.connect(reader);
  }
}

class CcidCard {
  final String reader;

  CcidCard(this.reader);

  /// Send APDU command [cpadu]
  ///
  /// Returns the response APDU
  Future<String?> transceive(String capdu) {
    return CcidPlatform.instance.transceive(reader, capdu);
  }

  /// Disconnect from the card
  Future<void> disconnect() {
    return CcidPlatform.instance.disconnect(reader);
  }

  /// Reads the NDEF message from an NFC Forum Type 2 Tag (e.g. NTAG213/215/216,
  /// Mifare Ultralight) connected through a contactless PC/SC reader.
  ///
  /// Throws an [Exception] if the tag has no NDEF capability container or
  /// no NDEF message is found on it.
  Future<List<NdefRecord>> readNdef() async {
    final cc = await _transceiveChecked('FFB0000304');
    if (cc.isEmpty || cc[0] != 0xE1) {
      throw Exception(
          'Tag does not contain NDEF data (no capability container found)');
    }
    final dataAreaSize = cc[2] * 8;

    final buffer = BytesBuilder();
    var page = 4;
    while (buffer.length < dataAreaSize) {
      final pageHex = page.toRadixString(16).padLeft(2, '0');
      String? chunkHex;
      try {
        chunkHex = await transceive('FFB00000${pageHex}10');
      } catch (_) {
        break;
      }
      final chunk = _stripAndCheckSw(chunkHex);
      if (chunk == null) break;
      buffer.add(chunk);
      page += 4;
    }

    final message = parseTlvForNdefMessage(buffer.toBytes());
    if (message == null) {
      throw Exception('No NDEF message found on tag');
    }
    return parseNdefRecords(message);
  }

  Future<Uint8List> _transceiveChecked(String capdu) async {
    final data = _stripAndCheckSw(await transceive(capdu));
    if (data == null) {
      throw Exception('Failed to read tag (bad response to $capdu)');
    }
    return data;
  }

  Uint8List? _stripAndCheckSw(String? responseHex) {
    if (responseHex == null || responseHex.length < 4) return null;
    final sw = responseHex.substring(responseHex.length - 4);
    if (sw.toUpperCase() != '9000') return null;
    final dataHex = responseHex.substring(0, responseHex.length - 4);
    return Uint8List.fromList(hex.decode(dataHex));
  }
}
```

- [ ] **Step 2: Statically verify the change**

Run: `dart analyze lib/ccid.dart lib/ccid_ndef.dart`
Expected: `No issues found!`

- [ ] **Step 3: Commit**

```bash
git add lib/ccid.dart
git commit -m "feat: add CcidCard.readNdef() to read Type 2 tag NDEF messages"
```

---

### Task 3: Example app "Read NFC Tag" button

**Files:**
- Modify: `example/lib/main.dart`

**Interfaces:**
- Consumes (from Task 2): `Future<List<NdefRecord>> CcidCard.readNdef()`.

- [ ] **Step 1: Add the handler method**

In `example/lib/main.dart`, the existing `_sendApdu` method (lines 62-70) reads:

```dart
  Future<void> _sendApdu() async {
    if (_card != null) {
      final rapdu = await _card!.transceive(_capduController.text);
      setState(() {
        _rapduController.text = rapdu ?? '';
        _history.insert(0, 'C-APDU: ${_capduController.text}, R-APDU: $rapdu');
      });
    }
  }
```

Add a new method directly after it:

```dart

  Future<void> _readNfcTag() async {
    if (_card == null) return;
    try {
      final records = await _card!.readNdef();
      setState(() {
        _history.insert(
          0,
          records.isEmpty
              ? 'NDEF: (empty message)'
              : 'NDEF: ${records.join(', ')}',
        );
      });
    } catch (e) {
      setState(() {
        _history.insert(0, 'NDEF read failed: $e');
      });
    }
  }
```

- [ ] **Step 2: Add the button**

The existing button row (lines 101-113) reads:

```dart
            Row(
              children: [
                ElevatedButton(
                  onPressed: _refreshReaders,
                  child: const Text('Refresh'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _connectCard,
                  child: const Text('Connect'),
                ),
              ],
            ),
```

Replace it with:

```dart
            Row(
              children: [
                ElevatedButton(
                  onPressed: _refreshReaders,
                  child: const Text('Refresh'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _connectCard,
                  child: const Text('Connect'),
                ),
                const SizedBox(width: 16),
                ElevatedButton(
                  onPressed: _readNfcTag,
                  child: const Text('Read NFC Tag'),
                ),
              ],
            ),
```

- [ ] **Step 3: Statically verify the change**

Run: `cd example && flutter analyze lib/main.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add example/lib/main.dart
git commit -m "feat: add Read NFC Tag button to example app"
```

- [ ] **Step 5: Manually verify against real hardware**

1. Run: `cd example && flutter run -d macos` (or the desktop target you use with the ACR1122U).
2. In the running app: select the ACR1122U reader from the dropdown, tap **Refresh** if it's not listed, then tap **Connect** while an NDEF-formatted NFC tag (e.g. an NTAG213/215/216 tag written to via a phone NFC-writing app such as "NFC Tools") is on the reader.
3. Tap **Read NFC Tag**.
4. Expected: a new line appears at the top of the History list, either `NDEF: Text: <your text>` / `NDEF: URI: <your url>` matching what you wrote to the tag, or a `NDEF read failed: ...` message if the tag isn't NDEF-formatted or isn't present on the reader — confirming the reader can talk to contactless tags end-to-end.

---

## Self-Review Notes

- **Spec coverage:** `NdefRecord` (typeString/asText/asUri/toString) → Task 1. TLV scan + record parsing → Task 1. `readNdef()` orchestration (CC read, chunked page reads, SW check, throw on missing NDEF) → Task 2. Export of `NdefRecord` from `ccid.dart` → Task 2. Example app button/history wiring → Task 3. Unit test for parsing + manual hardware verification → Tasks 1 and 3 respectively. All spec sections are covered.
- **Placeholder scan:** no TBD/TODO markers; every step has complete, runnable code.
- **Type consistency:** `NdefRecord`, `parseTlvForNdefMessage`, `parseNdefRecords` signatures are identical across Task 1 (definition + test) and Task 2 (consumption). `readNdef()` return type `Future<List<NdefRecord>>` matches its use in Task 3 (`records.isEmpty`, `records.join`).
