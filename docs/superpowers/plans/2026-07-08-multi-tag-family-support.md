# Multi Tag Family Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the `ccid` plugin so `CcidCard` is a raw transport and card reads live on auto-detected, per-family drivers (`Type2Tag`, `MifareClassicTag`, `FelicaTag`, `IsoDepTag`), so the library can read more tag families than NFC Forum Type 2.

**Architecture:** `CcidCard` keeps `transceive`/`disconnect` and gains an `atr` field. A new `identifyTag(card)` inspects the ATR (Android only this pass) or falls back to ordered capability probing, returning the right typed driver. Today's Type 2 Tag methods move onto `Type2Tag` unchanged in behavior. `MifareClassicTag` and `FelicaTag` are new. `IsoDepTag` is a thin generic ISO14443-4 passthrough (no DESFire-specific commands).

**Tech Stack:** Flutter/Dart plugin (`package:ccid`), `flutter_test` for unit tests, Kotlin for the Android native layer, `package:convert`'s `hex` codec for byte/hex conversions.

## Global Constraints

- Dart SDK `>=3.5.0 <4.0.0`, Flutter `>=3.24.0` (from `pubspec.yaml`) — don't use newer language features than that floor allows.
- This is a breaking change to the public API (`CcidCard` loses its Type 2-specific methods) — acceptable pre-1.0; bump `pubspec.yaml` version to `0.2.0` and document the migration in `CHANGELOG.md` (Task 11).
- Native ATR plumbing and hardware validation are scoped to **Android only** this pass. Do not modify `darwin/ccid/Sources/ccid/CcidPlugin.swift` or `lib/ccid_pcsc.dart` — iOS/macOS/Linux/Windows keep working via the capability-probing fallback in `identifyTag()`, with `CcidCard.atr` staying `null` there.
- No DESFire native command set (auth, file read) — `IsoDepTag` only provides `selectApplication` + raw `transceive`.
- Every new/changed Dart file needs unit tests using the existing fake-`CcidPlatform` pattern from `test/ccid_test.dart` (mock `CcidPlatform.instance`, assert on exact APDU hex strings sent and responses parsed) — no real hardware needed for these.
- Design reference: `docs/superpowers/specs/2026-07-08-multi-tag-family-support-design.md`.

---

### Task 1: Shared APDU response-parsing utility

**Files:**
- Create: `lib/src/apdu.dart`
- Test: `test/src/apdu_test.dart`

**Interfaces:**
- Consumes: `CcidCard.transceive(String) -> Future<String?>` (existing, `lib/ccid.dart`).
- Produces: `Uint8List? stripAndCheckSw(String? responseHex)`, `Future<Uint8List> transceiveChecked(CcidCard card, String capdu)` — every later driver task (3, 6, 7, 9) calls these instead of reimplementing status-word handling.

- [ ] **Step 1: Write the failing test**

Create `test/src/apdu_test.dart`:

```dart
import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:ccid/src/apdu.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
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

  group('stripAndCheckSw', () {
    test('strips a trailing 9000 status word', () {
      final result = stripAndCheckSw('${hex.encode([0xAA, 0xBB])}9000');
      expect(result, equals([0xAA, 0xBB]));
    });

    test('returns null for a non-9000 status word', () {
      expect(stripAndCheckSw('${hex.encode([0xAA])}6A82'), isNull);
    });

    test('returns null for a null response', () {
      expect(stripAndCheckSw(null), isNull);
    });

    test('returns null for a response shorter than the status word', () {
      expect(stripAndCheckSw('90'), isNull);
    });
  });

  group('transceiveChecked', () {
    test('returns the data bytes on a 9000 response', () async {
      CcidPlatform.instance =
          _FakeCcidPlatform({'00A4': '${hex.encode([0x01, 0x02])}9000'});
      final card = CcidCard('fake-reader');

      final data = await transceiveChecked(card, '00A4');

      expect(data, equals([0x01, 0x02]));
    });

    test('throws when the response has a non-9000 status word', () async {
      CcidPlatform.instance =
          _FakeCcidPlatform({'00A4': '${hex.encode([0x01])}6A82'});
      final card = CcidCard('fake-reader');

      expect(() => transceiveChecked(card, '00A4'), throwsException);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/src/apdu_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:ccid/src/apdu.dart'`

- [ ] **Step 3: Write the implementation**

Create `lib/src/apdu.dart`:

```dart
import 'dart:typed_data';

import 'package:convert/convert.dart';

import '../ccid.dart';

/// Strips the trailing 2-byte status word from [responseHex] and returns the
/// data bytes, or null if the response is missing, too short, or the status
/// word isn't the success code `9000`.
Uint8List? stripAndCheckSw(String? responseHex) {
  if (responseHex == null || responseHex.length < 4) return null;
  final sw = responseHex.substring(responseHex.length - 4);
  if (sw.toUpperCase() != '9000') return null;
  final dataHex = responseHex.substring(0, responseHex.length - 4);
  return Uint8List.fromList(hex.decode(dataHex));
}

/// Sends [capdu] through [card] and returns the response data, throwing if
/// the response is missing or its status word isn't `9000`.
Future<Uint8List> transceiveChecked(CcidCard card, String capdu) async {
  final data = stripAndCheckSw(await card.transceive(capdu));
  if (data == null) {
    throw Exception('Failed to read tag (bad response to $capdu)');
  }
  return data;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/src/apdu_test.dart`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/src/apdu.dart test/src/apdu_test.dart
git commit -m "feat: add shared APDU response-parsing utility"
```

---

### Task 2: `TagDriver` base class and `UnrecognizedTagException`

**Files:**
- Create: `lib/ccid_tag_driver.dart`
- Test: `test/ccid_tag_driver_test.dart`

**Interfaces:**
- Consumes: `CcidCard` (`lib/ccid.dart`, existing).
- Produces: `abstract class TagDriver { final CcidCard card; }`, `class UnrecognizedTagException implements Exception { final String message; }` — every driver task (3, 6, 7, 8) extends `TagDriver`; Task 9's `identifyTag` throws `UnrecognizedTagException`.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_tag_driver_test.dart`:

```dart
import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_tag_driver.dart';
import 'package:flutter_test/flutter_test.dart';

class _TestDriver extends TagDriver {
  _TestDriver(super.card);
}

void main() {
  test('TagDriver stores the CcidCard it was constructed with', () {
    final card = CcidCard('fake-reader');

    final driver = _TestDriver(card);

    expect(driver.card, same(card));
  });

  test('UnrecognizedTagException.toString() includes the message', () {
    const exception = UnrecognizedTagException('no matching tag family');

    expect(exception.toString(), contains('no matching tag family'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_tag_driver_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:ccid/ccid_tag_driver.dart'`

- [ ] **Step 3: Write the implementation**

Create `lib/ccid_tag_driver.dart`:

```dart
import 'ccid.dart';

/// Base class for tag-family-specific drivers returned by [identifyTag]
/// (see `ccid_tag_detection.dart`).
///
/// Each driver wraps a connected [CcidCard] and exposes only the read
/// operations that make sense for that tag family.
abstract class TagDriver {
  final CcidCard card;

  const TagDriver(this.card);
}

/// Thrown by `identifyTag` when a connected card doesn't match any known
/// tag family, whether via ATR matching or capability probing.
class UnrecognizedTagException implements Exception {
  final String message;

  const UnrecognizedTagException(this.message);

  @override
  String toString() => 'UnrecognizedTagException: $message';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_tag_driver_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Commit**

```bash
git add lib/ccid_tag_driver.dart test/ccid_tag_driver_test.dart
git commit -m "feat: add TagDriver base class and UnrecognizedTagException"
```

---

### Task 3: `Type2Tag` driver and trimmed `CcidCard`

**Files:**
- Create: `lib/ccid_type2.dart`
- Modify: `lib/ccid.dart` (whole file — trim `CcidCard`, add `atr` field, update exports)
- Modify: `test/ccid_test.dart:59-60`

**Interfaces:**
- Consumes: `TagDriver` (Task 2), `transceiveChecked`/`stripAndCheckSw` (Task 1), `NdefRecord`/`parseTlvForNdefMessage`/`parseNdefRecords` (`lib/ccid_ndef.dart`, unchanged), `CapabilityContainer`/`ChipVersion` (`lib/ccid_tag_info.dart`, unchanged).
- Produces: `class Type2Tag extends TagDriver` with `readUid()`, `readCapabilityContainer()`, `readMemoryDump()`, `readChipVersion()`, `readNdef()` (same signatures/behavior as today's `CcidCard` methods). `CcidCard(String reader, {Uint8List? atr})` — Task 5 relies on this constructor's `atr` parameter, Task 9 relies on `card.atr`.

**Note:** This task intentionally breaks `example/lib/tag_details_page.dart` (it calls the now-removed `CcidCard` methods directly) — that's fixed in Task 10. The example app is a separate package from the plugin's `flutter test` run, so it doesn't block this task's test cycle.

- [ ] **Step 1: Update the existing test to use `Type2Tag`**

In `test/ccid_test.dart`, change lines 59-60 from:

```dart
    final card = CcidCard('fake-reader');
    final records = await card.readNdef();
```

to:

```dart
    final card = CcidCard('fake-reader');
    final records = await Type2Tag(card).readNdef();
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_test.dart`
Expected: FAIL — compile error, `Type2Tag` isn't defined (and/or `CcidCard.readNdef` no longer exists once Step 3 below is done — at this point it's `Type2Tag` not being defined yet)

- [ ] **Step 3: Create `Type2Tag`**

Create `lib/ccid_type2.dart`:

```dart
import 'dart:typed_data';

import 'ccid_ndef.dart';
import 'ccid_tag_driver.dart';
import 'ccid_tag_info.dart';
import 'src/apdu.dart';

/// Driver for an NFC Forum Type 2 Tag (e.g. NTAG213/215/216, Mifare
/// Ultralight) connected through a contactless PC/SC reader.
class Type2Tag extends TagDriver {
  Type2Tag(super.card);

  /// Reads the NDEF message from the tag.
  ///
  /// Throws an [Exception] if the tag has no NDEF capability container or
  /// no NDEF message is found on it.
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

  /// Reads the tag's UID via the standard PC/SC "Get Data" pseudo-APDU.
  Future<Uint8List> readUid() {
    return transceiveChecked(card, 'FFCA000000');
  }

  /// Reads and parses the tag's Capability Container (CC), normally found
  /// at page 3 of the tag's memory.
  Future<CapabilityContainer> readCapabilityContainer() async {
    final bytes = await transceiveChecked(card, 'FFB0000304');
    if (bytes.length != 4) {
      throw Exception('Failed to read Capability Container (expected 4 '
          'bytes, got ${bytes.length})');
    }
    return CapabilityContainer.parse(bytes);
  }

  /// Reads the tag's full raw memory, starting at page 0, until a page
  /// read fails or the page number would no longer fit in one byte.
  Future<Uint8List> readMemoryDump() {
    return _readPagesFrom(0);
  }

  /// Attempts to read the tag's chip identification via the NXP
  /// `GET_VERSION` (0x60) command.
  ///
  /// Returns `null` if the reader doesn't support this, the command fails,
  /// or the response isn't the expected 8 bytes, rather than throwing.
  Future<ChipVersion?> readChipVersion() async {
    try {
      final responseHex = await card.transceive('FF0000000160');
      final data = stripAndCheckSw(responseHex);
      if (data == null || data.length != 8) {
        return null;
      }
      return ChipVersion.parse(data);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _readPagesFrom(int startPage, {int? maxBytes}) async {
    final buffer = BytesBuilder();
    var page = startPage;
    while ((maxBytes == null || buffer.length < maxBytes) && page <= 0xFF) {
      final pageHex = page.toRadixString(16).padLeft(2, '0');
      String? chunkHex;
      try {
        chunkHex = await card.transceive('FFB000${pageHex}10');
      } catch (_) {
        break;
      }
      final chunk = stripAndCheckSw(chunkHex);
      if (chunk == null) break;
      buffer.add(chunk);
      page += 4;
    }
    return buffer.toBytes();
  }
}
```

- [ ] **Step 4: Trim `CcidCard` and update exports**

Replace the full contents of `lib/ccid.dart` with:

```dart
import 'dart:typed_data';

import 'ccid_platform_interface.dart';

export 'ccid_ndef.dart' show NdefRecord;
export 'ccid_tag_driver.dart' show TagDriver, UnrecognizedTagException;
export 'ccid_tag_info.dart' show CapabilityContainer, ChipVersion;
export 'ccid_type2.dart' show Type2Tag;

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

  /// The card's answer-to-reset, captured at connect time where the
  /// platform supports it (Android only, currently). Null on platforms/
  /// paths that don't surface it — `identifyTag` falls back to capability
  /// probing in that case.
  final Uint8List? atr;

  CcidCard(this.reader, {this.atr});

  /// Send APDU command [capdu]
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

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/ccid_test.dart test/ccid_tag_info_test.dart test/ccid_ndef_test.dart test/src/apdu_test.dart test/ccid_tag_driver_test.dart`
Expected: PASS (all tests across these five files)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid.dart lib/ccid_type2.dart test/ccid_test.dart
git commit -m "refactor: move Type 2 Tag reads from CcidCard onto Type2Tag"
```

---

### Task 4: Android — return the card's ATR from `connect()`

**Files:**
- Modify: `android/src/main/kotlin/im/nfc/ccid/CcidPlugin.kt:182-252`

**Interfaces:**
- Consumes: `Ccid.iccPowerOn(): ByteArray` (`android/src/main/kotlin/im/nfc/ccid/Ccid.kt:13`, unchanged, already returns the ATR).
- Produces: the `"connect"` method channel call now resolves with a hex-encoded ATR string instead of `null` on success. Task 5 depends on this.

**Note:** No automated test — this is native Android code with no test harness in this repo. Verified by a debug build (Step 2) and covered by Task 12's manual hardware pass.

- [ ] **Step 1: Change `connectToInterface` to return the ATR alongside the `Ccid` instance**

In `android/src/main/kotlin/im/nfc/ccid/CcidPlugin.kt`, replace the `connectToInterface` function (lines 225-252):

```kotlin
    @OptIn(ExperimentalStdlibApi::class)
    private fun connectToInterface(device: UsbDevice, interfaceIdx: Int): Pair<Ccid, ByteArray>? {
        val usbInterface = device.getInterface(interfaceIdx)
        val usbConnection = usbManager.openDevice(device)
        if (usbConnection == null) {
            Log.e(TAG, "Failed to open device")
            return null
        }
        return try {
            val endpoints = getEndpoints(usbInterface)
            val ccid = Ccid(usbConnection, endpoints.first, endpoints.second)
            val descriptor = ccid.getDescriptor(interfaceIdx)
            if (descriptor?.supportsProtocol(Protocol.T1) != true) {
                Log.d(TAG, "Unsupported protocol")
                return null
            }
            if (!usbConnection.claimInterface(usbInterface, true)) {
                Log.e(TAG, "Failed to claim interface")
                return null
            }
            val atr = ccid.iccPowerOn()
            Log.d(TAG, "ATR: ${atr.toHexString()}")
            Pair(ccid, atr)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to connect to interface: ${e.message}")
            null
        }
    }
```

- [ ] **Step 2: Update both call sites to return the ATR hex string as the method result**

Replace the `usbReceiver`'s permission-granted branch (lines 33-49):

```kotlin
                    val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        device?.apply {
                            val reader = readers[intent.getStringExtra("name")]
                            if (reader == null) {
                                Log.e(TAG, "Reader not found")
                                return
                            }
                            val connected = connectToInterface(device, reader.interfaceIdx)
                            if (connected != null) {
                                val (ccid, atr) = connected
                                readers[reader.name] = reader.copy(ccid = ccid, result = null)
                                reader.result!!.success(atr.toHexString())
                            } else {
                                reader.result!!.error(
                                    "CCID_READER_CONNECT_ERROR",
                                    "Failed to connect",
                                    null
                                )
                            }
                        }
                    } else {
```

And add `@OptIn(ExperimentalStdlibApi::class)` right before `override fun onReceive(context: Context, intent: Intent) {` (the `usbReceiver` object's method) since it now calls `atr.toHexString()`.

Then replace the `connect` function's already-has-permission branch (lines 214-222):

```kotlin
        } else {
            val connected = connectToInterface(device, reader.interfaceIdx)
            if (connected != null) {
                val (ccid, atr) = connected
                readers[name] = reader.copy(ccid = ccid)
                result.success(atr.toHexString())
            } else {
                result.error("CCID_READER_CONNECT_ERROR", "Failed to connect", null)
            }
        }
    }
```

And add `@OptIn(ExperimentalStdlibApi::class)` right before `private fun connect(name: String, result: Result) {`.

- [ ] **Step 3: Verify the native code compiles**

Run: `cd example && flutter build apk --debug`
Expected: `✓ Built build/app/outputs/flutter-apk/app-debug.apk` (no Kotlin compile errors)

- [ ] **Step 4: Commit**

```bash
git add android/src/main/kotlin/im/nfc/ccid/CcidPlugin.kt
git commit -m "feat(android): return the card's ATR from connect()"
```

---

### Task 5: Dart — thread the ATR from `connect()` into `CcidCard`

**Files:**
- Modify: `lib/ccid_method_channel.dart:19-24`
- Test: `test/ccid_method_channel_test.dart`

**Interfaces:**
- Consumes: Task 4's native change (Android `"connect"` method channel call now resolves with an ATR hex string).
- Produces: on Android, `Ccid().connect(reader)` returns a `CcidCard` with `atr` populated. Task 9 relies on `card.atr` being non-null on Android.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_method_channel_test.dart`:

```dart
import 'package:ccid/ccid_method_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('connect() decodes the hex ATR string returned by the platform',
      () async {
    final channel = MethodChannelCcid();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, (call) async {
      expect(call.method, equals('connect'));
      return 'AABBCC';
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.methodChannel, null);
    });

    final card = await channel.connect('fake-reader');

    expect(card.atr, equals([0xAA, 0xBB, 0xCC]));
  });

  test('connect() leaves atr null when the platform returns null', () async {
    final channel = MethodChannelCcid();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel.methodChannel, (call) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel.methodChannel, null);
    });

    final card = await channel.connect('fake-reader');

    expect(card.atr, isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_method_channel_test.dart`
Expected: FAIL — `card.atr` is always `null` (the first test's expectation `equals([0xAA, 0xBB, 0xCC])` fails)

- [ ] **Step 3: Update `MethodChannelCcid.connect()`**

In `lib/ccid_method_channel.dart`, add imports at the top:

```dart
import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'ccid.dart';
import 'ccid_platform_interface.dart';
```

Then replace the `connect` method (lines 19-24):

```dart
  @override
  Future<CcidCard> connect(String reader) async {
    final atrHex = await methodChannel.invokeMethod<String>('connect', reader);
    final atr =
        atrHex != null ? Uint8List.fromList(hex.decode(atrHex)) : null;
    return CcidCard(reader, atr: atr);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_method_channel_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Run the full test suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_method_channel.dart test/ccid_method_channel_test.dart
git commit -m "feat: decode the ATR returned by connect() into CcidCard.atr"
```

---

### Task 6: `MifareClassicTag` driver

**Files:**
- Create: `lib/ccid_mifare_classic.dart`
- Modify: `lib/ccid.dart` (add one export line)
- Test: `test/ccid_mifare_classic_test.dart`

**Interfaces:**
- Consumes: `TagDriver` (Task 2), `transceiveChecked`/`stripAndCheckSw` (Task 1).
- Produces: `enum MifareKeyType { a, b }`, `class MifareAuthException implements Exception { final String message; }`, `class MifareClassicTag extends TagDriver` with `authenticate(int sector, MifareKeyType keyType, Uint8List key)`, `authenticateWithDefaultKeys(int sector)`, `readBlock(int block) -> Future<Uint8List>`, `readSector(int sector) -> Future<List<Uint8List>>`. Task 9 constructs `MifareClassicTag(card)` and calls `authenticateWithDefaultKeys`.

**Note:** Authentication uses the PC/SC Part 3 "Load Keys" (`FF 82`) and "General Authenticate" (`FF 86`) pseudo-APDUs — the reader performs the MIFARE crypto itself. The exact opcodes are the documented standard, but reader firmware compliance varies; Task 12's hardware pass is where this gets confirmed/adjusted against the user's actual reader.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_mifare_classic_test.dart`:

```dart
import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;
  final List<String> requestedCapdus = [];

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    requestedCapdus.add(capdu);
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

  test('authenticateWithDefaultKeys() succeeds on the first working default key',
      () async {
    final fake = _FakeCcidPlatform({
      'FF82000006FFFFFFFFFFFF': '9000',
      'FF860000050100006000': '9000',
    });
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    await tag.authenticateWithDefaultKeys(0);

    expect(fake.requestedCapdus, contains('FF82000006FFFFFFFFFFFF'));
    expect(fake.requestedCapdus, contains('FF860000050100006000'));
  });

  test('authenticateWithDefaultKeys() throws MifareAuthException when every '
      'default key fails', () async {
    final fake = _FakeCcidPlatform({
      'FF82000006FFFFFFFFFFFF': '6300',
      'FF82000006A0A1A2A3A4A5': '6300',
      'FF82000006D3F7D3F7D3F7': '6300',
      'FF82000006000000000000': '6300',
    });
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    expect(
      () => tag.authenticateWithDefaultKeys(0),
      throwsA(isA<MifareAuthException>()),
    );
  });

  test('readBlock() sends a READ BINARY APDU with the block number in P2 '
      'and returns the decoded data', () async {
    final fake = _FakeCcidPlatform({'FFB0000110': '${'AA' * 16}9000'});
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    final data = await tag.readBlock(1);

    expect(data, equals(List.filled(16, 0xAA)));
  });

  test('readSector() reads all 4 blocks of the sector', () async {
    final fake = _FakeCcidPlatform({
      'FFB0000410': '${'00' * 16}9000',
      'FFB0000510': '${'01' * 16}9000',
      'FFB0000610': '${'02' * 16}9000',
      'FFB0000710': '${'03' * 16}9000',
    });
    CcidPlatform.instance = fake;
    final tag = MifareClassicTag(CcidCard('fake-reader'));

    final blocks = await tag.readSector(1);

    expect(blocks, hasLength(4));
    expect(blocks[0], equals(List.filled(16, 0x00)));
    expect(blocks[3], equals(List.filled(16, 0x03)));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_mifare_classic_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:ccid/ccid.dart'` doesn't export `MifareClassicTag` (compile error)

- [ ] **Step 3: Write the implementation**

Create `lib/ccid_mifare_classic.dart`:

```dart
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'ccid_tag_driver.dart';
import 'src/apdu.dart';

/// Which MIFARE Classic key slot (A or B) to authenticate with.
enum MifareKeyType { a, b }

/// Thrown by [MifareClassicTag] authentication methods when a key is
/// rejected by the card. This is an expected, catchable outcome (wrong key
/// or wrong sector), not a bug.
class MifareAuthException implements Exception {
  final String message;

  const MifareAuthException(this.message);

  @override
  String toString() => 'MifareAuthException: $message';
}

/// Driver for a MIFARE Classic 1K/4K tag connected through a contactless
/// PC/SC reader.
///
/// Reads require authenticating the target sector first, via [authenticate]
/// or [authenticateWithDefaultKeys]. The reader performs the MIFARE stream
/// cipher itself; this driver only sends the PC/SC "Load Keys" and "General
/// Authenticate" pseudo-APDUs (PC/SC Part 3).
class MifareClassicTag extends TagDriver {
  MifareClassicTag(super.card);

  static const List<String> _defaultKeysHex = [
    'FFFFFFFFFFFF',
    'A0A1A2A3A4A5',
    'D3F7D3F7D3F7',
    '000000000000',
  ];

  static const int _keySlot = 0x00;

  /// Loads [key] (6 bytes) into the reader and authenticates [sector] with
  /// it as key [keyType].
  ///
  /// Throws [MifareAuthException] if the key is rejected.
  Future<void> authenticate(
    int sector,
    MifareKeyType keyType,
    Uint8List key,
  ) async {
    if (key.length != 6) {
      throw ArgumentError(
          'MIFARE Classic keys are 6 bytes, got ${key.length}');
    }
    await _loadKey(key);
    await _generalAuthenticate(_blockForSector(sector), keyType);
  }

  /// Tries each of a short list of well-known default MIFARE Classic keys
  /// (as key A) against [sector], succeeding on the first that works.
  ///
  /// Throws [MifareAuthException] if none of them work.
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

  /// Reads one 16-byte block. The block's sector must already be
  /// authenticated via [authenticate] or [authenticateWithDefaultKeys].
  Future<Uint8List> readBlock(int block) {
    final blockHex = block.toRadixString(16).padLeft(2, '0');
    return transceiveChecked(card, 'FFB000${blockHex}10');
  }

  /// Reads every block in [sector] (4 blocks on a 1K/4K tag). The sector
  /// must already be authenticated.
  Future<List<Uint8List>> readSector(int sector) async {
    final firstBlock = _blockForSector(sector);
    final blocks = <Uint8List>[];
    for (var block = firstBlock; block < firstBlock + 4; block++) {
      blocks.add(await readBlock(block));
    }
    return blocks;
  }

  int _blockForSector(int sector) => sector * 4;

  Future<void> _loadKey(Uint8List key) async {
    final keyHex = hex.encode(key);
    final slotHex = _keySlot.toRadixString(16).padLeft(2, '0');
    final capdu = 'FF8200${slotHex}06$keyHex';
    final response = await card.transceive(capdu);
    if (stripAndCheckSw(response) == null) {
      throw MifareAuthException('Failed to load key into reader');
    }
  }

  Future<void> _generalAuthenticate(int block, MifareKeyType keyType) async {
    final blockHex = block.toRadixString(16).padLeft(2, '0');
    final keyTypeHex = keyType == MifareKeyType.a ? '60' : '61';
    final slotHex = _keySlot.toRadixString(16).padLeft(2, '0');
    final capdu = 'FF860000050100$blockHex$keyTypeHex$slotHex';
    final response = await card.transceive(capdu);
    if (stripAndCheckSw(response) == null) {
      throw MifareAuthException('Authentication failed for block $block');
    }
  }
}
```

Then in `lib/ccid.dart`, add this export line alongside the existing ones:

```dart
export 'ccid_mifare_classic.dart'
    show MifareClassicTag, MifareKeyType, MifareAuthException;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_mifare_classic_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Run the full test suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_mifare_classic.dart lib/ccid.dart test/ccid_mifare_classic_test.dart
git commit -m "feat: add MifareClassicTag driver"
```

---

### Task 7: `FelicaTag` driver

**Files:**
- Create: `lib/ccid_felica.dart`
- Modify: `lib/ccid.dart` (add one export line)
- Test: `test/ccid_felica_test.dart`

**Interfaces:**
- Consumes: `TagDriver` (Task 2), `transceiveChecked` (Task 1).
- Produces: `class FelicaReadResult { final int statusFlag1; final int statusFlag2; final List<Uint8List> blocks; bool get isSuccess; }`, `class FelicaTag extends TagDriver` with `Future<Uint8List> get idm`, `readWithoutEncryption(int serviceCode, List<int> blockList) -> Future<FelicaReadResult>`. Task 9 constructs `FelicaTag(card)` and calls `.idm`.

**Note:** FeliCa command framing is genuinely unverified until tested against real hardware (flagged in the design spec's Open Questions) — the escape/direct-transmit wrapper here follows the same `FF 00 00 00 <Lc> <data>` convention `Type2Tag.readChipVersion()` already uses, as a first attempt. Task 12 is where this gets confirmed/adjusted.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_felica_test.dart`:

```dart
import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;
  final List<String> requestedCapdus = [];

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    requestedCapdus.add(capdu);
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

  // Polling frame (6 bytes): cmd=00, sysCode=FFFF, requestCode=00,
  // timeSlot=00. Wrapped as FF 00 00 00 <Lc=06> <length-prefixed frame>
  // where the frame's own length byte (06) counts itself + the 5 bytes
  // after it.
  const pollCapdu = 'FF000000060600FFFF0000';
  const idmHex = 'AABBCCDDEE001122';
  // Response frame (10 bytes): len=0A, respCode=01, idm(8 bytes).
  const pollResponse = '0A01${idmHex}9000';

  test('idm polls the card and caches the result', () async {
    final fake = _FakeCcidPlatform({pollCapdu: pollResponse});
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    final idm = await tag.idm;
    final idmAgain = await tag.idm;

    expect(idm, equals([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x00, 0x11, 0x22]));
    expect(idmAgain, equals(idm));
    expect(
      fake.requestedCapdus.where((c) => c == pollCapdu),
      hasLength(1),
      reason: 'the second idm access should use the cached value, not poll '
          'again',
    );
  });

  test('readWithoutEncryption() builds the FeliCa Read Without Encryption '
      'frame and parses a successful response', () async {
    // Read command frame (15 bytes): cmd=06, idm(8), numServices=01,
    // serviceCode LE (0F22 for 0x220F), numBlocks=01,
    // blockListElement(80,00). Wrapped as FF 00 00 00 <Lc=10>
    // <length-prefixed frame> (frame's own length byte = 10 = 15+1).
    const readCapdu =
        'FF000000101006AABBCCDDEE001122010F22018000';
    // Response frame (29 bytes): len=1D, respCode=07, idm(8), SF1=00,
    // SF2=00, numBlocks=01, block(16 bytes of 0xAA).
    const readResponse = '1D07AABBCCDDEE001122000001'
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'
        '9000';
    final fake = _FakeCcidPlatform({
      pollCapdu: pollResponse,
      readCapdu: readResponse,
    });
    CcidPlatform.instance = fake;
    final tag = FelicaTag(CcidCard('fake-reader'));

    final result = await tag.readWithoutEncryption(0x220F, [0]);

    expect(result.isSuccess, isTrue);
    expect(result.blocks, hasLength(1));
    expect(result.blocks[0], equals(List.filled(16, 0xAA)));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_felica_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:ccid/ccid.dart'` doesn't export `FelicaTag` (compile error)

- [ ] **Step 3: Write the implementation**

Create `lib/ccid_felica.dart`:

```dart
import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'ccid_tag_driver.dart';
import 'src/apdu.dart';

/// The parsed result of a FeliCa "Read Without Encryption" command.
class FelicaReadResult {
  final int statusFlag1;
  final int statusFlag2;
  final List<Uint8List> blocks;

  const FelicaReadResult({
    required this.statusFlag1,
    required this.statusFlag2,
    required this.blocks,
  });

  /// Whether the card reported success (both status flags zero).
  bool get isSuccess => statusFlag1 == 0x00 && statusFlag2 == 0x00;
}

/// Driver for a FeliCa (NFC-F / JIS X 6319-4) tag connected through a
/// contactless PC/SC reader, sent via the reader's direct-transmit/escape
/// pseudo-APDU (`FF 00 00 00 <Lc> <data>`) since FeliCa's command framing
/// isn't ISO 7816 APDUs.
///
/// This escape command framing is a first attempt based on the same
/// convention `Type2Tag.readChipVersion()` uses; it may need adjusting for
/// readers that expect a different "direct transmit" byte layout.
class FelicaTag extends TagDriver {
  FelicaTag(super.card);

  Uint8List? _idm;

  /// The card's 8-byte IDm, polled once (via a FeliCa Polling / SENSF_REQ
  /// command) and cached for the lifetime of this driver.
  Future<Uint8List> get idm async {
    final cached = _idm;
    if (cached != null) return cached;
    final polled = await _poll();
    _idm = polled;
    return polled;
  }

  /// Sends a FeliCa "Read Without Encryption" (command code 0x06) for
  /// [serviceCode], reading each block number in [blockList].
  ///
  /// Each block list entry must be 0-255 (2-byte block list element form).
  Future<FelicaReadResult> readWithoutEncryption(
    int serviceCode,
    List<int> blockList,
  ) async {
    final cardIdm = await idm;
    final frame = BytesBuilder();
    frame.addByte(0x06); // command code
    frame.add(cardIdm);
    frame.addByte(0x01); // number of service codes
    frame.addByte(serviceCode & 0xFF); // service code, little-endian
    frame.addByte((serviceCode >> 8) & 0xFF);
    frame.addByte(blockList.length);
    for (final block in blockList) {
      frame.addByte(0x80); // 2-byte block list element
      frame.addByte(block & 0xFF);
    }
    final response = await _transceiveFelicaFrame(frame.toBytes());

    // Response frame: length(1) | responseCode(1)=0x07 | idm(8) | SF1(1) |
    // SF2(1) | numBlocks(1) | blocks(16 bytes each).
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

  Future<Uint8List> _poll() async {
    final command = Uint8List.fromList([
      0x00, // Polling command code
      0xFF, 0xFF, // System Code: wildcard
      0x00, // Request Code: none
      0x00, // Time Slot
    ]);
    final response = await _transceiveFelicaFrame(command);
    // Response frame: length(1) | responseCode(1)=0x01 | idm(8) | pmm(8) | ...
    if (response.length < 10) {
      throw Exception(
          'FeliCa polling response too short (${response.length} bytes)');
    }
    return Uint8List.sublistView(response, 2, 10);
  }

  /// Wraps [felicaCommand] in the reader's length-prefix byte and sends it
  /// via the direct-transmit escape pseudo-APDU, returning the raw FeliCa
  /// response frame (length byte included).
  Future<Uint8List> _transceiveFelicaFrame(Uint8List felicaCommand) async {
    final framed =
        Uint8List.fromList([felicaCommand.length + 1, ...felicaCommand]);
    final lcHex = framed.length.toRadixString(16).padLeft(2, '0');
    final dataHex = hex.encode(framed);
    final capdu = 'FF000000$lcHex$dataHex'.toUpperCase();
    return transceiveChecked(card, capdu);
  }
}
```

Then in `lib/ccid.dart`, add this export line alongside the existing ones:

```dart
export 'ccid_felica.dart' show FelicaTag, FelicaReadResult;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_felica_test.dart`
Expected: PASS (2 tests). The expected `pollCapdu`/`readCapdu` hex strings were hand-computed from the frame layout in the doc comments above them — if they don't match what `_transceiveFelicaFrame` actually builds, print `fake.requestedCapdus` to see what was sent, re-derive the expected string byte-by-byte from the frame layout, and fix whichever side (test or implementation) doesn't match the documented layout.

- [ ] **Step 5: Run the full test suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_felica.dart lib/ccid.dart test/ccid_felica_test.dart
git commit -m "feat: add FelicaTag driver"
```

---

### Task 8: `IsoDepTag` driver

**Files:**
- Create: `lib/ccid_iso_dep.dart`
- Modify: `lib/ccid.dart` (add one export line)
- Test: `test/ccid_iso_dep_test.dart`

**Interfaces:**
- Consumes: `TagDriver` (Task 2).
- Produces: `class IsoDepTag extends TagDriver` with `selectApplication(String aidHex) -> Future<String?>`, `transceive(String capdu) -> Future<String?>`. Task 9 constructs `IsoDepTag(card)`.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_iso_dep_test.dart`:

```dart
import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String?> responses;
  final List<String> requestedCapdus = [];

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    requestedCapdus.add(capdu);
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

  test('selectApplication() sends a SELECT-by-name APDU with the AID as Lc/data',
      () async {
    // AID 'D2760000850101' is 7 bytes (14 hex chars), so Lc = 07.
    final fake = _FakeCcidPlatform({'00A4040007D2760000850101': '9000'});
    CcidPlatform.instance = fake;
    final tag = IsoDepTag(CcidCard('fake-reader'));

    final response = await tag.selectApplication('D2760000850101');

    expect(response, equals('9000'));
    expect(
      fake.requestedCapdus,
      contains('00A4040007D2760000850101'),
    );
  });

  test('transceive() passes the APDU straight through to the card', () async {
    final fake = _FakeCcidPlatform({'00B0000000': 'AABB9000'});
    CcidPlatform.instance = fake;
    final tag = IsoDepTag(CcidCard('fake-reader'));

    final response = await tag.transceive('00B0000000');

    expect(response, equals('AABB9000'));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_iso_dep_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:ccid/ccid.dart'` doesn't export `IsoDepTag` (compile error)

- [ ] **Step 3: Write the implementation**

Create `lib/ccid_iso_dep.dart`:

```dart
import 'ccid_tag_driver.dart';

/// Thin driver for a generic ISO14443-4 ("ISO-DEP") processor card (e.g.
/// DESFire or another applet-based smart card) connected through a
/// contactless PC/SC reader.
///
/// This driver only provides raw ISO 7816-4 SELECT + APDU transport; it has
/// no knowledge of any particular card's application/file model.
class IsoDepTag extends TagDriver {
  IsoDepTag(super.card);

  /// Sends a SELECT (by name/AID) command for [aidHex] (hex-encoded
  /// Application Identifier), returning the response APDU.
  Future<String?> selectApplication(String aidHex) {
    final lcHex = (aidHex.length ~/ 2).toRadixString(16).padLeft(2, '0');
    return card.transceive('00A40400$lcHex$aidHex');
  }

  /// Sends a raw APDU [capdu] (hex-encoded) and returns the response APDU
  /// (hex-encoded), unchanged from [CcidCard.transceive].
  Future<String?> transceive(String capdu) => card.transceive(capdu);
}
```

Then in `lib/ccid.dart`, add this export line alongside the existing ones:

```dart
export 'ccid_iso_dep.dart' show IsoDepTag;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_iso_dep_test.dart`
Expected: PASS (2 tests)

- [ ] **Step 5: Run the full test suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_iso_dep.dart lib/ccid.dart test/ccid_iso_dep_test.dart
git commit -m "feat: add IsoDepTag driver"
```

---

### Task 9: `identifyTag()` detection (ATR matching + probing fallback)

**Files:**
- Create: `lib/ccid_tag_detection.dart`
- Modify: `lib/ccid.dart` (add one export line)
- Test: `test/ccid_tag_detection_test.dart`

**Interfaces:**
- Consumes: `CcidCard.atr` (Task 5), `stripAndCheckSw` (Task 1), `Type2Tag` (Task 3), `MifareClassicTag`/`MifareAuthException` (Task 6), `FelicaTag` (Task 7), `IsoDepTag` (Task 8), `UnrecognizedTagException` (Task 2).
- Produces: `Future<TagDriver> identifyTag(CcidCard card)`. Task 10 (example app) calls this directly.

**Note:** The ATR historical-byte matching here uses a loose "marker byte(s) appear anywhere in the historical bytes" check rather than an exact positional field parse, since PC/SC Part 3's full historical-bytes TLV layout varies by card. This is a deliberate simplification, flagged in the design spec's Open Questions — Task 12's hardware pass, which captures real ATRs from real cards, is where to tighten this to an exact offset check if the loose match proves ambiguous in practice.

- [ ] **Step 1: Write the failing test**

Create `test/ccid_tag_detection_test.dart`:

```dart
import 'dart:typed_data';

import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
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

  group('identifyTag() via ATR', () {
    test('recognizes a Type 2 Tag ATR', () async {
      final atr = Uint8List.fromList(
          [0x3B, 0x8F, 0x80, 0x01, 0x80, 0x4F, 0x0C, 0x03, 0x00, 0x00]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
    });

    test('recognizes a MIFARE Classic ATR by its RID marker', () async {
      final atr = Uint8List.fromList([
        0x3B, 0x8F, 0x80, 0x01, //
        0x80, 0x4F, 0x0C, 0xA0, 0x00, 0x00, 0x03, 0x06, 0x03, 0x00, 0x01,
      ]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<MifareClassicTag>());
    });

    test('recognizes a FeliCa ATR', () async {
      final atr = Uint8List.fromList(
          [0x3B, 0x8F, 0x80, 0x01, 0x80, 0x4F, 0x0C, 0x11, 0x00, 0x00]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<FelicaTag>());
    });

    test('treats an unmarked ATR as a generic ISO-DEP card', () async {
      final atr = Uint8List.fromList(
          [0x3B, 0x8A, 0x80, 0x01, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00]);
      final card = CcidCard('fake-reader', atr: atr);

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });
  });

  group('identifyTag() probing fallback (no ATR)', () {
    test('recognizes a Type 2 Tag by its Capability Container', () async {
      CcidPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '00019000',
        'FFB0000304': 'E11006009000',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<Type2Tag>());
    });

    test('recognizes an ISO-DEP card via a SELECT response', () async {
      CcidPlatform.instance = _FakeCcidPlatform({
        'FFCA000000': '00019000',
        'FFB0000304': '6A82',
        '00A4040000': '6A82',
      });
      final card = CcidCard('fake-reader');

      final driver = await identifyTag(card);

      expect(driver, isA<IsoDepTag>());
    });

    test('throws UnrecognizedTagException when nothing responds', () async {
      CcidPlatform.instance = _FakeCcidPlatform({'FFCA000000': null});
      final card = CcidCard('fake-reader');

      expect(
        () => identifyTag(card),
        throwsA(isA<UnrecognizedTagException>()),
      );
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/ccid_tag_detection_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:ccid/ccid.dart'` doesn't export `identifyTag` (compile error)

- [ ] **Step 3: Write the implementation**

Create `lib/ccid_tag_detection.dart`:

```dart
import 'dart:typed_data';

import 'ccid.dart' show CcidCard;
import 'ccid_felica.dart';
import 'ccid_iso_dep.dart';
import 'ccid_mifare_classic.dart';
import 'ccid_tag_driver.dart';
import 'ccid_type2.dart';
import 'src/apdu.dart';

/// Identifies the tag family of the card connected through [card] and
/// returns the matching typed driver.
///
/// Uses [CcidCard.atr] where available (see PC/SC Part 3's historical-byte
/// markers for contactless storage cards). Where [CcidCard.atr] is null or
/// doesn't match a known pattern, falls back to ordered capability probing.
///
/// Throws [UnrecognizedTagException] if no known tag family matches.
Future<TagDriver> identifyTag(CcidCard card) async {
  final atr = card.atr;
  if (atr != null) {
    final fromAtr = _identifyFromAtr(card, atr);
    if (fromAtr != null) return fromAtr;
  }
  return _identifyByProbing(card);
}

TagDriver? _identifyFromAtr(CcidCard card, Uint8List atr) {
  if (atr.length < 5) return null;
  final historicalBytes = atr.sublist(4);

  if (_contains(historicalBytes, [0xA0, 0x00, 0x00, 0x03, 0x06])) {
    return MifareClassicTag(card);
  }
  if (historicalBytes.contains(0x11)) {
    return FelicaTag(card);
  }
  if (historicalBytes.contains(0x03)) {
    return Type2Tag(card);
  }
  // A real ATS-derived ATR (not a PC/SC Part 3 synchronous-card pseudo-ATR)
  // with none of the above markers: treat as a generic processor card.
  return IsoDepTag(card);
}

bool _contains(Uint8List haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<String?> _tryTransceive(CcidCard card, String capdu) async {
  try {
    return await card.transceive(capdu);
  } catch (_) {
    return null;
  }
}

Future<TagDriver> _identifyByProbing(CcidCard card) async {
  final uidResponse = await _tryTransceive(card, 'FFCA000000');
  if (stripAndCheckSw(uidResponse) == null) {
    throw const UnrecognizedTagException('Card did not respond to Get UID');
  }

  final ccResponse = await _tryTransceive(card, 'FFB0000304');
  final ccData = stripAndCheckSw(ccResponse);
  if (ccData != null && ccData.length == 4 && ccData[0] == 0xE1) {
    return Type2Tag(card);
  }

  final selectResponse = await _tryTransceive(card, '00A4040000');
  if (selectResponse != null && selectResponse.length >= 4) {
    return IsoDepTag(card);
  }

  final mifare = MifareClassicTag(card);
  try {
    await mifare.authenticateWithDefaultKeys(0);
    return mifare;
  } on MifareAuthException {
    // fall through
  }

  final felica = FelicaTag(card);
  try {
    await felica.idm;
    return felica;
  } catch (_) {
    // fall through
  }

  throw const UnrecognizedTagException(
    'Card did not match any known tag family (Type 2, MIFARE Classic, '
    'FeliCa, or ISO-DEP)',
  );
}
```

Then in `lib/ccid.dart`, add this export line alongside the existing ones:

```dart
export 'ccid_tag_detection.dart' show identifyTag;
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/ccid_tag_detection_test.dart`
Expected: PASS (7 tests)

- [ ] **Step 5: Run the full test suite to check for regressions**

Run: `flutter test`
Expected: PASS (all tests)

- [ ] **Step 6: Commit**

```bash
git add lib/ccid_tag_detection.dart lib/ccid.dart test/ccid_tag_detection_test.dart
git commit -m "feat: add identifyTag() auto-detection"
```

---

### Task 10: Example app — identify the tag and dispatch per family

**Files:**
- Modify: `example/lib/main.dart:74-81` (the `_readTagDetails` method)
- Modify: `example/lib/tag_details_page.dart` (whole file)

**Interfaces:**
- Consumes: `identifyTag` (Task 9), `Type2Tag` (Task 3), `MifareClassicTag` (Task 6), `FelicaTag` (Task 7), `IsoDepTag` (Task 8).
- Produces: nothing consumed by later tasks — this is the UI leaf.

- [ ] **Step 1: Update `_readTagDetails` in `example/lib/main.dart`**

Replace the `_readTagDetails` method (lines 74-81):

```dart
  Future<void> _readTagDetails() async {
    if (_card == null) return;
    try {
      final driver = await identifyTag(_card!);
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => TagDetailsPage(driver: driver),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not identify tag: $e')),
      );
    }
  }
```

- [ ] **Step 2: Rewrite `example/lib/tag_details_page.dart`**

Replace the whole file:

```dart
import 'package:ccid/ccid.dart';
import 'package:flutter/material.dart';

class TagDetailsPage extends StatefulWidget {
  final TagDriver driver;

  const TagDetailsPage({super.key, required this.driver});

  @override
  State<TagDetailsPage> createState() => _TagDetailsPageState();
}

class _TagDetailsPageState extends State<TagDetailsPage> {
  final Map<String, String> _results = {};

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final driver = widget.driver;
    if (driver is Type2Tag) {
      await _load('UID', () async => _hex(await driver.readUid()));
      await _load('Capability Container',
          () async => (await driver.readCapabilityContainer()).toString());
      await _load('NDEF', () async {
        final records = await driver.readNdef();
        return records.isEmpty ? '(empty message)' : records.join('\n');
      });
      await _load('Memory Dump',
          () async => _formatPages(await driver.readMemoryDump()));
      await _load('Chip Version', () async {
        final version = await driver.readChipVersion();
        return version == null
            ? 'Unavailable (reader/tag does not support GET_VERSION)'
            : version.toString();
      });
    } else if (driver is MifareClassicTag) {
      await _load('Sector 0', () async {
        await driver.authenticateWithDefaultKeys(0);
        final blocks = await driver.readSector(0);
        return blocks.map(_hex).join('\n');
      });
    } else if (driver is FelicaTag) {
      await _load('IDm', () async => _hex(await driver.idm));
      await _load('Service 0x220F, blocks 0-3', () async {
        final result =
            await driver.readWithoutEncryption(0x220F, [0, 1, 2, 3]);
        if (!result.isSuccess) {
          return 'Card reported status '
              '${result.statusFlag1.toRadixString(16)}/'
              '${result.statusFlag2.toRadixString(16)}';
        }
        return result.blocks.map(_hex).join('\n');
      });
    } else if (driver is IsoDepTag) {
      await _load('SELECT (empty AID)',
          () async => await driver.selectApplication('') ?? '(no response)');
    }
  }

  Future<void> _load(String title, Future<String> Function() body) async {
    try {
      final value = await body();
      if (!mounted) return;
      setState(() => _results[title] = value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _results[title] = 'Failed: $e');
    }
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String _formatPages(List<int> bytes) {
    final lines = <String>[];
    for (var i = 0; i < bytes.length; i += 4) {
      final page = i ~/ 4;
      final end = i + 4 > bytes.length ? bytes.length : i + 4;
      final chunk = bytes.sublist(i, end);
      lines.add('Page $page: ${_hex(chunk)}');
    }
    return lines.isEmpty ? '(empty)' : lines.join('\n');
  }

  Widget _section(String title, String? content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(content ?? 'Loading...'),
        ],
      ),
    );
  }

  List<String> _sectionTitlesFor(TagDriver driver) {
    if (driver is Type2Tag) {
      return [
        'UID',
        'Capability Container',
        'NDEF',
        'Memory Dump',
        'Chip Version',
      ];
    } else if (driver is MifareClassicTag) {
      return ['Sector 0'];
    } else if (driver is FelicaTag) {
      return ['IDm', 'Service 0x220F, blocks 0-3'];
    } else if (driver is IsoDepTag) {
      return ['SELECT (empty AID)'];
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Tag Details (${widget.driver.runtimeType})')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final title in _sectionTitlesFor(widget.driver))
              _section(title, _results[title]),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 3: Verify the example app compiles and analyzes cleanly**

Run: `cd example && flutter analyze`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add example/lib/main.dart example/lib/tag_details_page.dart
git commit -m "feat: identify the connected tag and dispatch to per-family UI in the example app"
```

---

### Task 11: CHANGELOG and version bump

**Files:**
- Modify: `pubspec.yaml:5`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later tasks — this is metadata only.

- [ ] **Step 1: Bump the version**

In `pubspec.yaml`, change line 5 from:

```yaml
version: 0.1.10
```

to:

```yaml
version: 0.2.0
```

- [ ] **Step 2: Add a CHANGELOG entry**

In `CHANGELOG.md`, insert at the top (before the existing `## 0.1.10` entry):

```markdown
## 0.2.0

* **Breaking:** `CcidCard` is now a raw transport only (`transceive`, `disconnect`, `atr`). The Type 2 Tag reads previously on `CcidCard` (`readUid`, `readCapabilityContainer`, `readMemoryDump`, `readChipVersion`, `readNdef`) have moved to `Type2Tag`, obtained via `identifyTag(card)`.
* Add `identifyTag(CcidCard)`, which auto-detects the connected card's tag family (from its ATR where available, falling back to capability probing) and returns a typed driver: `Type2Tag`, `MifareClassicTag`, `FelicaTag`, or `IsoDepTag`.
* Add `MifareClassicTag` for MIFARE Classic 1K/4K cards: sector key authentication (`authenticate`, `authenticateWithDefaultKeys`) and block/sector reads.
* Add `FelicaTag` for FeliCa (NFC-F) cards: IDm polling and `readWithoutEncryption`.
* Add `IsoDepTag`, a thin generic ISO14443-4 driver (`selectApplication` + raw `transceive`) for DESFire and other applet-based cards — no DESFire-specific commands.
* Android: `connect()` now also returns the card's ATR, enabling ATR-based tag detection. Other platforms fall back to capability probing.
```

- [ ] **Step 3: Verify the package still resolves**

Run: `flutter pub get`
Expected: exits successfully, no version-resolution errors

- [ ] **Step 4: Commit**

```bash
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: bump version to 0.2.0"
```

---

### Task 12: Manual hardware validation (Android)

**Files:** none (no code changes — this is a verification pass; fix-forward commits land as needed per finding)

**Interfaces:** none.

This task has no automated steps — it's a checklist to run through with the example app (`cd example && flutter run`) on an Android device with a USB CCID reader, against the three cards used to scope this plan. For each finding that requires a code change, make the fix, re-run the affected unit tests, and commit separately (reference which checklist item the commit addresses).

- [ ] **Check 1: ATR plumbing.** Connect any card. Confirm `CcidCard.atr` is non-null (add a temporary `print(card.atr)` in `main.dart`'s `_connectCard` if needed, remove before committing). If null, the `connect()` method channel change (Task 4) isn't wiring through — check `CcidPlugin.kt`'s `connect` and `usbReceiver` success branches both call `result.success(atr.toHexString())` correctly.

- [ ] **Check 2: Type 2 Tag regression.** Tap an NTAG/Ultralight tag. Confirm `identifyTag()` returns a `Type2Tag` and all five sections in `TagDetailsPage` populate exactly as they did before this refactor (no behavior change expected here).

- [ ] **Check 3: MIFARE Classic detection + auth.** Tap the MIFARE Classic card. Confirm `identifyTag()` returns a `MifareClassicTag` (via ATR if Check 1 passed, otherwise verify the probing fallback path is reached). Confirm `authenticateWithDefaultKeys(0)` succeeds with one of the four built-in keys, and `readSector(0)` returns 4 blocks of plausible-looking data (not all zeros/all `FF` unless that's genuinely the card's content). If auth fails with every default key, the card uses a non-default key (expected for a real access-controlled card) — note this in the CHANGELOG or a follow-up spec rather than treating it as a bug; if auth fails due to a malformed APDU (reader returns an error unrelated to "wrong key", e.g. `6D00`), fix `_loadKey`/`_generalAuthenticate` in `lib/ccid_mifare_classic.dart` to match what this specific reader expects.

- [ ] **Check 4: FeliCa detection + read.** Tap the FeliCa/MRT-style card. Confirm `identifyTag()` returns a `FelicaTag`. Confirm `idm` returns a plausible 8-byte value (compare against the card's printed/known IDm if available). Confirm `readWithoutEncryption(0x220F, [0, 1, 2, 3])` either returns `isSuccess: true` with 4 blocks, or a clean non-success status (not a thrown parse exception) if `0x220F` isn't the right service code for this card. If the escape command gets no response or a malformed one, iterate on `_transceiveFelicaFrame`'s framing in `lib/ccid_felica.dart` — this is the piece flagged as most likely to need adjustment.

- [ ] **Check 5: ISO-DEP detection.** Tap the ISO14443-4/DESFire-class card. Confirm `identifyTag()` returns an `IsoDepTag` (via ATR or the SELECT-response probing step). Confirm `selectApplication('')` gets a response (even an error SW is fine — the point is confirming the reader forwards raw APDUs to this card correctly, not that the empty-AID SELECT itself succeeds).

- [ ] **Check 6: Unrecognized-card path.** If practical, connect a card/reader combination expected to fail every probe (or temporarily point at a reader with no card present) and confirm `identifyTag()` throws `UnrecognizedTagException` rather than hanging or throwing an unrelated error.

- [ ] **Final step: update the design spec.** In `docs/superpowers/specs/2026-07-08-multi-tag-family-support-design.md`'s "Open questions / risks" section, replace each now-resolved risk with what was actually confirmed (or note the fix that was needed), so the spec reflects reality rather than pre-hardware guesses. Commit this alongside the last fix-forward change.
