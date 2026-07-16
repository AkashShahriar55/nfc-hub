# Multi Tag Family Support: Auto-Detection and Per-Family Drivers

## Context

Today `CcidCard` mixes two concerns on one class: the raw transport (`transceive`, `disconnect`) and a set of NFC Forum Type 2 Tag-specific reads (`readUid`, `readCapabilityContainer`, `readMemoryDump`, `readChipVersion`, `readNdef`) added in the tag-info work. Every one of those reads assumes an ISO14443-A / Type 2 storage tag; there is no support for other contactless families (MIFARE Classic's sector-key auth, FeliCa's non-APDU command framing, or generic ISO14443-4/processor cards), and no way for a caller to ask "what kind of card is this" before deciding which reads to attempt.

The motivating case is porting MRT/RapidPass transit card reading (a FeliCa/NFC-F card, see the `mrt-buddy` reference app) onto this library, but the user wants the library itself made robust to multiple tag families generally, not a one-off FeliCa bolt-on. This spec covers restructuring the card API around auto-detected, per-family drivers, plus building out MIFARE Classic and FeliCa support and a thin generic ISO14443-4 driver. Hardware is available to validate all three new families (MIFARE Classic, FeliCa, and an ISO14443-4/DESFire-class card) during implementation.

## Goals

- Split `CcidCard` into a raw transport (`transceive`, `disconnect`, plus the card's ATR where available) and a set of typed, per-family drivers holding the family-specific reads.
- Add `identifyTag(card)`, which inspects the connected card and returns the right typed driver automatically — no caller-supplied tag type.
- Detect primarily from the card's ATR (PC/SC Part 3 historical-byte markers), falling back to ordered capability probing on platforms/paths where ATR isn't available.
- Preserve today's Type 2 Tag functionality unchanged in behavior, moved onto a `Type2Tag` driver.
- Add `MifareClassicTag` (sector key auth + block read, using the reader's PC/SC key-load/general-authenticate pseudo-APDUs rather than raw crypto).
- Add `FelicaTag` (IDm polling + `readWithoutEncryption`, using a reader escape/direct-transmit pseudo-APDU), enough to support MRT-style transaction reads.
- Add a thin `IsoDepTag` (SELECT application + raw APDU transceive) as the fallback driver for any processor card that isn't a recognized storage-card family.
- Update the example app to identify the connected tag and dispatch to the right driver's UI.

## Non-goals

- DESFire's native command set (proprietary auth handshake, session-key derivation, file-system model). `IsoDepTag` gives raw APDU access to DESFire and other applet cards, but no DESFire-specific typed methods. This was explicitly descoped after discussion — it's a substantial, separate crypto implementation, not an incremental add-on.
- Native ATR plumbing on any platform other than Android. `CcidPlugin.swift` (iOS/macOS) is not touched this pass, and fixing `dart_pcsc`'s lack of an `SCardStatus`/ATR API (Linux/Windows) is out of scope entirely. All three rely on capability-probing detection for now; ATR-based detection there is a future improvement.
- Hardware validation on any platform other than Android — this pass's manual testing (MIFARE Classic, FeliCa, ISO-DEP) is against an Android device + USB CCID reader only.
- MIFARE Classic key management beyond a short built-in list of well-known default keys — no key-derivation, no per-deployment key storage.
- Card-type-specific writing (NDEF write, MIFARE block write, FeliCa write-with-encryption). This spec is read-side only, matching the scope of the existing tag-info work.

## Design

### `CcidCard` (trimmed to raw transport)

`lib/ccid.dart`'s `CcidCard` loses its Type 2-specific methods (`readUid`, `readCapabilityContainer`, `readMemoryDump`, `readChipVersion`, `readNdef`) and the private helpers used only by them (`_readPagesFrom`, `_transceiveChecked`, `_stripAndCheckSw`). It keeps `transceive`, `disconnect`, and gains:

```dart
class CcidCard {
  final String reader;
  final Uint8List? atr; // null where the platform doesn't yet surface it

  CcidCard(this.reader, {this.atr});

  Future<String?> transceive(String capdu);
  Future<void> disconnect();
}
```

This is a breaking change to the public API — version bumps to 0.2.0, CHANGELOG calls out the migration (old flat methods now live on `Type2Tag`, obtained via `identifyTag()`).

### ATR plumbing

This pass is scoped to **Android only**. `Ccid.kt`'s `iccPowerOn()` already returns the ATR bytes (`CcidPlugin.kt:245` currently just logs them); `CcidPlugin.kt`'s `connect` handler is changed to return the ATR as a hex string in its method result instead of a bare success, and `MethodChannelCcid.connect()` reads it and threads it into the returned `CcidCard`.

`MethodChannelCcid` also backs iOS and macOS (see `ccid_platform_interface.dart`'s platform selection), but `CcidPlugin.swift` is not touched in this pass — iOS/macOS `connect()` keeps returning `nil`, so `atr` stays `null` there, same as Linux/Windows via `dart_pcsc` (which has no `SCardStatus` wrapper at all). `identifyTag()` falls back to capability probing whenever `atr` is null, so every platform still works — Android is just the only one with ATR-based detection until a later pass extends the same native change to `CcidPlugin.swift` and `dart_pcsc`.

### Tag driver hierarchy

New file `lib/ccid_tag_driver.dart` (or one file per driver — see file layout below) defines a common base and four drivers, all constructed with the `CcidCard` they operate through:

```dart
sealed class TagDriver {
  final CcidCard card;
  TagDriver(this.card);
}

class Type2Tag extends TagDriver { ... } // today's methods, moved here verbatim
class MifareClassicTag extends TagDriver { ... }
class FelicaTag extends TagDriver { ... }
class IsoDepTag extends TagDriver { ... }
```

Shared response-parsing (strip trailing SW, check `9000`, hex-decode) moves from `CcidCard`'s private methods into a small internal utility (e.g. a top-level function or mixin in `lib/src/apdu.dart`) so each driver reuses it instead of reimplementing it.

#### `Type2Tag` (`lib/ccid_type2.dart`)

Direct move of the current `CcidCard` methods: `readUid()`, `readCapabilityContainer()`, `readMemoryDump()`, `readChipVersion()`, `readNdef()`, plus the `_readPagesFrom` helper. No behavior change.

#### `MifareClassicTag` (`lib/ccid_mifare_classic.dart`)

```dart
enum MifareKeyType { a, b }

class MifareClassicTag extends TagDriver {
  Future<void> authenticate(int sector, MifareKeyType keyType, Uint8List key); // FF82 load key, FF88 general authenticate
  Future<void> authenticateWithDefaultKeys(int sector); // tries FFFFFFFFFFFF, A0A1A2A3A4A5, D3F7D3F7D3F7, 000000000000
  Future<Uint8List> readBlock(int block); // FFB0 read binary, requires prior authenticate() on that block's sector
  Future<Uint8List> readSector(int sector); // reads all blocks in the sector
}

class MifareAuthException implements Exception {
  final String message;
}
```

Authentication uses the reader's PC/SC pseudo-APDUs (`FF 82 00 <keySlot> 06 <key>` to load a key into reader memory, `FF 88 00 <block> <keyType 0x60|0x61> <keySlot>` to run the reader's own authenticate routine) rather than implementing MIFARE's stream cipher — the reader does the crypto. `authenticateWithDefaultKeys` throws `MifareAuthException` (distinct from a generic `Exception`, since a wrong/unknown key is an expected, catchable outcome, not a bug) if every default key fails.

#### `FelicaTag` (`lib/ccid_felica.dart`)

```dart
class FelicaTag extends TagDriver {
  Future<Uint8List> get idm; // polls via reader escape command, caches the result
  Future<FelicaReadResult> readWithoutEncryption(int serviceCode, List<int> blockList);
}

class FelicaReadResult {
  final int statusFlag1;
  final int statusFlag2;
  final List<Uint8List> blocks; // 16 bytes each
}
```

`readWithoutEncryption` builds the FeliCa "Read Without Encryption" command frame (command code `0x06`, IDm, service code count + code, block count + block list) exactly as `mrt-buddy`'s `NfcCommandGenerator` does, then wraps it in a reader direct-transmit/escape pseudo-APDU (first attempt follows the same `FF 00 00 00 <Lc> <data>` convention already used by `readChipVersion()`). This byte framing is the one part of this spec genuinely unverified until tested against real hardware — flagged in Open Questions.

MRT-specific transaction parsing (16-byte block → timestamp/station/balance decoding, matching `mrt-buddy`'s `TransactionParser`) is **not** part of `FelicaTag` itself — `readWithoutEncryption` returns raw blocks; a follow-on piece (either in this library as an optional helper module, or in the consuming app) decodes MRT-specific fields on top. Keeping `FelicaTag` generic (any FeliCa service/block read) rather than MRT-specific matches the "different tags" framing of this request.

#### `IsoDepTag` (`lib/ccid_iso_dep.dart`)

```dart
class IsoDepTag extends TagDriver {
  Future<void> selectApplication(String aidHex); // 00 A4 04 00 <Lc> <aid> 00
  Future<String?> transceive(String apdu); // passthrough to card.transceive
}
```

No DESFire-specific commands (see Non-goals).

### Detection: `identifyTag()`

New file `lib/ccid_tag_detection.dart`:

```dart
Future<TagDriver> identifyTag(CcidCard card);
```

1. If `card.atr` is non-null, match it against known historical-byte patterns (PC/SC Part 3): `0x03` → `Type2Tag`, MIFARE's RID `A0 00 00 03 06` (with sub-byte distinguishing 1K/4K) → `MifareClassicTag`, `0x11` → `FelicaTag`. A real ATS-derived ATR carrying none of these markers → `IsoDepTag`.
2. If `atr` is null, or doesn't match any known pattern, fall back to ordered probing, cheapest/safest first:
   - `FFCA000000` (Get UID) — establishes the reader can see *something*.
   - `FFB0000304` (Type 2 CC read) — success with a plausible CC (magic byte `0xE1`) → `Type2Tag`.
   - ISO SELECT with a reserved/probe AID — a structured ISO7816 response (even an error SW like `6A82`) indicates a processor card → `IsoDepTag`.
   - MIFARE default-key auth on sector 0, tried last since it's the one probe with a card-side side effect (failed auth attempts) — success → `MifareClassicTag`.
   - FeliCa polling escape command — success → `FelicaTag`.
3. If nothing matches, returns/throws an `UnrecognizedTagException` rather than guessing a driver.

### Example app

`example/lib/tag_details_page.dart` is generalized: instead of calling the five Type 2-specific methods directly, it calls `Ccid.connect()` → `identifyTag()`, then renders a driver-specific section based on the returned type (`Type2Tag` renders today's five-section view; `MifareClassicTag` shows UID + a sector read with default-key auth; `FelicaTag` shows IDm + a sample block read; `IsoDepTag` shows UID + raw SELECT/transceive fields for manual APDU entry).

### Testing

- Unit tests per driver (`test/ccid_mifare_classic_test.dart`, `test/ccid_felica_test.dart`, `test/ccid_iso_dep_test.dart`, existing `test/ccid_tag_info_test.dart`/`ccid_ndef_test.dart` content moves under a `Type2Tag`-focused test file), mocking `CcidPlatform.instance` as `test/ccid_test.dart` already does, to verify exact command bytes sent and correct parsing of canned responses — no hardware required.
- `identifyTag()` tests: synthetic ATR byte arrays for each known pattern, plus a null-ATR case exercising the probing fallback (mocked `transceive` responses simulating each family and an unrecognized card).
- Manual hardware validation pass, tracked as its own checklist in the implementation plan: MIFARE Classic auth + block read, FeliCa IDm poll + block read, and IsoDep SELECT + transceive, each against the user's available card/reader. `FelicaTag`'s escape command framing and `MifareClassicTag`'s exact key-load opcodes are the two pieces most likely to need iteration once real hardware is in the loop.

## Open questions / risks

- `FelicaTag`'s escape/direct-transmit command framing is a first guess based on the existing `readChipVersion()` convention; the reader in hand may expect a different byte layout (e.g. a vendor-specific "switch RF protocol" command before FeliCa polling works at all). Expect iteration during hardware testing.
- `MifareClassicTag`'s key-load/general-authenticate opcodes (`FF82`/`FF88`) are the standard PC/SC Part 3 convention, but reader firmware compliance varies; needs confirmation against the user's specific reader.
- ATR-based detection is only wired on Android this pass; iOS/macOS/Linux/Windows always use the probing fallback until later work extends ATR plumbing to `CcidPlugin.swift` and `dart_pcsc`. This is a functional gap, not a correctness one — probing still detects correctly, just with more round-trips.
- Moving today's Type 2 methods off `CcidCard` onto `Type2Tag` is a breaking change for any existing consumer of this library; needs a clear CHANGELOG migration note and a minor version bump (0.2.0).
