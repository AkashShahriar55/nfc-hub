# Generic Tag Info: SAK/ATQA Identification, FeliCa Chip/System Info, DESFire Versioning, ISO14443-B

## Context

The plugin can already auto-detect and read Type 2/NTAG, MIFARE Classic, FeliCa, and generic ISO14443-4 tags (`identifyTag()`), and the FeliCa path was recently fixed and verified against real Dhaka MRT hardware (ACR122U reader, Sony FeliCa RC-SA01/2 chip). The user now wants a generic tag-identification tool in the spirit of the "NFC Tools" Android app: technology, UID, model number, ATR, and "all possible info" for whatever card is on the reader — not just the family-specific reads each driver already supports.

Three research passes (web search + primary-source document fetches: NXP's AN10833 "MIFARE Type Identification Procedure", NXP NTAG213/215/216 and MF0ULX1/MF0ICU2 datasheets, Sony's FeliCa Card User's Manual, the PN532 User Manual UM0701-02, ACS's ACR122U NFC Reader API, and the Proxmark3 project's field-validated `GET_VERSION`/DESFire lookup tables) grounded this design. Key findings that shape it:

- **SAK (not ATQA) is the authoritative MIFARE-family discriminator.** NXP's own AN10833 explicitly warns against branching logic on ATQA. We don't currently capture real SAK/ATQA at all — the ATR only encodes it indirectly, and only for the specific NXP card types ACR122U's firmware already recognizes.
- **MIFARE Classic has no `GET_VERSION`** — SAK + UID length is the documented ceiling of what's identifiable (Classic vs. Mini vs. 4K), confirmed as NXP's own limit, not a gap.
- **Our existing `readChipVersion()` already gets the right bytes for Ultralight/NTAG** — we're only missing the lookup table mapping the 8-byte response to a model name.
- **FeliCa's chip model comes from PMm** (which we don't currently read — `FelicaTag.idm` only reads IDm via the Get UID shortcut), looked up against a community-maintained IC-code table. This table is **not officially published by Sony** — confirmed unofficial/community-sourced, and must be labeled as such wherever displayed.
- **DESFire's `GetVersion` is a different, longer (28-byte, 3-frame) exchange** than the Ultralight/NTAG one, needed to tell EV1/EV2/EV3/DUOX apart.
- **ISO14443-B is real, reachable hardware capability on this PN532-based reader** (`InListPassiveTarget` `BrTy=0x03`, confirmed in NXP's UM0701-02) — a genuinely new tag family, not currently supported at all.
- **ISO15693 ("vicinity" tags) is a hard hardware wall** — confirmed absent from both the PN532 datasheet/user manual and ACR122U's own API. Not buildable on this reader class regardless of software effort. Out of scope entirely.
- **NFC Forum Type 1 (Jewel/Topaz)** is reachable (`BrTy=0x04`) but confirmed obsolete (removed from the NFC Forum's own 2021+ spec revisions, absent from mainstream distributors). Not worth a real driver.

Scope decisions already made with the user: build SAK/ATQA identification via a raw PN532 poll (not just ATR parsing), add DESFire `GetVersion` decoding, and add ISO14443-B as a new family — all "build it now" per explicit direction, even though DESFire and Type B have no confirmed physical test card on hand yet (flagged as a real risk in Open Questions).

## Goals

- Add a raw PN532 `InListPassiveTarget` primitive (Type A and Type B) that returns real ATQA/SAK/UID (Type A) or ATQB (Type B) directly from the card, independent of the ATR.
- Resolve a human-readable "Model" string for each supported family:
  - MIFARE family (Classic 1K/4K/Mini, Ultralight/NTAG, DESFire/Plus-SL3 flag) from SAK, per NXP's AN10833 table.
  - Ultralight/NTAG exact model (NTAG213/215/216/210/212, Ultralight EV1 variants, etc.) from the existing `GET_VERSION` response, via a new ~35-entry lookup table.
  - FeliCa chip model from a new `pmm` read, via a new community-sourced IC-code lookup table (explicitly labeled unofficial).
  - DESFire generation (EV1/EV2/EV3/EV2 XL/DUOX/Light) from a new 3-frame `GetVersion` exchange.
- Add FeliCa system-code enumeration (`Request System Code`, native command `0x0C`) so a card's full system list is visible, not just whichever system a specific service-code read happens to target.
- Add a new `TypeBTag` family (ATQB + raw ISO7816 passthrough, mirroring `IsoDepTag`).
- Surface all of the above in the example app as a "Tag Info" section common to every driver type (Technology, UID, ATR, Model, plus family-specific extras).

## Non-goals

- ISO15693 ("Type 5") support — confirmed hardware-impossible on this reader class (PN532/ACR122U). Not attempted.
- A full NFC Forum Type 1 (Jewel/Topaz) driver — confirmed obsolete. At most, detect-and-label via existing ATR card-name recognition (`F0 04`); no new read/write commands built for it.
- Writing/modifying card data of any kind (balance, memory, keys) — this spec is read/identification-only, consistent with every prior pass.
- A fully exhaustive MIFARE Plus security-level/virtual-card-selection identification path — AN10833 itself documents that some MIFARE Plus configurations deliberately present ambiguous SAKs for privacy reasons and require deeper protocol exchanges (`VirtualCardSelect`) to fully resolve; this spec surfaces the ambiguity (reports "MIFARE Classic 1K or MIFARE Plus SL1 (ambiguous)") rather than resolving it.
- Retrying/upgrading `identifyTag()`'s existing ATR-first-then-probing driver-selection logic. That logic is proven working (verified against real Type 2, MIFARE Classic, and FeliCa hardware) and is **not replaced** by the new PN532 poll primitive — the poll is additive, used for info-gathering and for detecting the new Type B family, not for re-deciding which driver class an already-working detection path already assigns.

## Design

### New primitive: `lib/src/pn532.dart`

A raw `InListPassiveTarget` (PN532 native command `0x4A`) helper, using the same escape-command convention (`FF 00 00 00 <Lc> <PN532 command bytes>`) already established for FeliCa's `InDataExchange` calls, but with its own response-prefix handling — `InListPassiveTarget`'s response code is `0xD5 0x4B` (a different PN532 command/response pair than FeliCa's `0xD4 0x40`/`0xD5 0x41`).

```dart
class PassiveTargetTypeA {
  final Uint8List atqa; // SENS_RES, 2 bytes
  final int sak;        // SEL_RES, 1 byte
  final Uint8List uid;
  const PassiveTargetTypeA({required this.atqa, required this.sak, required this.uid});
}

class PassiveTargetTypeB {
  final Uint8List atqb;           // 12 bytes
  final Uint8List attribResponse;
  const PassiveTargetTypeB({required this.atqb, required this.attribResponse});
}

/// Polls for a Type A target via `FF 00 00 00 04 D4 4A 01 00`. Returns null
/// if no tag answers (`D5 4B 00 90 00`).
Future<PassiveTargetTypeA?> pollTypeA(CcidCard card);

/// Polls for a Type B target via `FF 00 00 00 04 D4 4A 01 03`. Returns null
/// if no tag answers.
Future<PassiveTargetTypeB?> pollTypeB(CcidCard card);
```

Byte format confirmed against ACS's own worked example (`FF 00 00 00 04 D4 4A 01 00` → `D5 4B 01 01 00 44 08 07 04 01 02 03 04 05 06 90 00`, decoding as `NbTg=01 Tg=01 SENS_RES=[00,44] SEL_RES=08 UIDLen=07 UID=[04,01,02,03,04,05,06]`). A small shared helper (`transceiveEscape(CcidCard, Uint8List payload) -> Future<Uint8List>` in `lib/src/apdu.dart`, wrapping the `FF 00 00 00 <Lc> <hex>` framing and SW-stripping) is factored out and reused by both this new module and `FelicaTag`'s existing `_transceiveFelicaFrame`, removing the small duplication between the two escape-command call sites.

### MIFARE family: SAK/ATQA-based model resolution

New `lib/ccid_mifare_info.dart` (pure lookup, no I/O):

```dart
enum MifareFamily { classic1k, classic4k, mini, ultralightOrNtag, desfireOrPlusSl3, unknown }

MifareFamily mifareFamilyFromSak(int sak) { ... } // per AN10833 Table 6, masking sak & 0x24 for the coarse ISO14443-4 flag first
```

Table (from AN10833 Table 6, values confirmed against the actual document text): SAK `0x08`→Classic 1K, `0x18`→Classic 4K, `0x09`→Mini, `0x00`→Ultralight/NTAG family (needs `GET_VERSION` — see below — to go further), bit `0x20` set→DESFire/Plus-SL3 (ISO14443-4 compliant, needs DESFire `GetVersion` or a Plus-specific exchange to disambiguate further). ATQA is captured and displayed for reference but never used as a branch condition, per NXP's explicit guidance.

### Ultralight/NTAG: exact model from `GET_VERSION`

Extends the existing `ChipVersion` (`lib/ccid_tag_info.dart`) with a lookup function in the same file:

```dart
/// Resolves an exact NXP model name from a full ChipVersion tuple, falling
/// back to a coarse family label (`productType` byte: 0x03→"MIFARE
/// Ultralight family", 0x04→"NTAG family") if the exact tuple isn't in the
/// table, matching Proxmark3's own fallback strategy.
String? ultralightModelName(ChipVersion version);
```

Table has ~35 entries (NTAG210/210u/212/213/213F/213C/213TT/215/216/216F/223 DNA/224 DNA/I2C variants, MIFARE Ultralight original/EV1 variants/Nano/AES), sourced from the Proxmark3 project's field-validated `ul_family[]` table, cross-referenced against NXP's own NTAG213/215/216 and MF0ULX1 datasheets for the entries covered directly by NXP documentation. Storage-size byte is displayed as a coarse `2ⁿ`–`(2ⁿ, 2ⁿ⁺¹)` byte-range hint only (per NXP's own non-committal wording for the LSB-set case) — **not** run through the "1.5×" approximation formula, which the research confirmed doesn't match real NXP products (verified wrong against NTAG213/215/216's real datasheet values).

### FeliCa: PMm read, chip model, and system-code enumeration

Extends `FelicaTag` (`lib/ccid_felica.dart`):

```dart
class FelicaTag extends TagDriver {
  // existing: idm getter, readWithoutEncryption()

  /// The card's 8-byte PMm, read via a FeliCa Polling (SENSF_REQ) command
  /// sent through the existing InDataExchange wrapper — reusing the same
  /// escape-command plumbing `readWithoutEncryption` already uses, just
  /// with the raw Polling command bytes (00 FF FF 00 00) instead of Read
  /// Without Encryption. Cached alongside idm.
  Future<Uint8List> get pmm;

  /// Enumerates every System Code on the card via the native "Request
  /// System Code" command (0x0C), not just whichever System a specific
  /// service-code read happens to target.
  Future<List<int>> requestSystemCodes();
}

/// Resolves a chip model name (e.g. "RC-SA01/2") from PMm's IC Code bytes
/// (D8:D9 of PMm, i.e. pmm[0]/pmm[1] — "ROM Type"/"IC Type"). Explicitly
/// documented as community-sourced, not from an official Sony
/// publication — callers must not present this as authoritative.
String? felicaModelName(Uint8List pmm);

/// Best-effort label for a known System Code (e.g. 0x0003 -> "Japan
/// transit common area", 0x90E3 -> "MRT_PASS"). Also community-sourced.
String? felicaSystemCodeLabel(int systemCode);
```

`pmm` is obtained by sending the FeliCa Polling command frame (`00 FF FF 00 00`, i.e. cmd=0x00, wildcard system code, no request data, single time slot) through `_transceiveFelicaFrame` (already-proven-working plumbing from the recent fix). The response frame is `len | 0x01 | idm(8) | pmm(8) | ...`, so `pmm` is `response[10:18]`.

`requestSystemCodes()` sends `[0x0C, ...idm]` through the same wrapper; response is `len | 0x0D | idm(8) | numSystems(1) | systemCode(2) × numSystems`.

### DESFire: 3-frame `GetVersion` and generation table

New `lib/ccid_desfire_info.dart` (pure data classes) plus a new method on `IsoDepTag`:

```dart
class DesfireVersion {
  final int hardwareVendorId, hardwareType, hardwareSubtype, hardwareMajor, hardwareMinor, hardwareStorageSize, hardwareProtocol;
  final int softwareVendorId, softwareType, softwareSubtype, softwareMajor, softwareMinor, softwareStorageSize, softwareProtocol;
  final Uint8List uid;      // 7 bytes
  final Uint8List batch;    // 5 bytes
  final int productionWeek, productionYear;
  const DesfireVersion({...});
}

/// Resolves a generation label ("DESFire EV1", "DESFire EV2", "DESFire
/// EV3", "DESFire EV2 XL", "DUOX", "DESFire Light", ...) from
/// (hardwareType, hardwareMajor, hardwareMinor), per Proxmark3's
/// field-validated getCardType() table.
String desfireGenerationLabel(DesfireVersion version);
```

`IsoDepTag.readDesfireVersion()` sends the 3-frame native-mode exchange documented in ACS's own manual (Example 4): `transceive('60')` for the hardware-info frame, then `transceive('AF')` twice more for the software-info and UID/batch/date frames, continuing only while a frame's first response byte is `0xAF` (DESFire's native "additional frame" status byte) and stopping at `0x00` (native "operation OK", final frame). **Important implementation detail surfaced by this research**: unlike every other read in this plugin, these native-mode DESFire responses are *not* checked against `stripAndCheckSw`'s literal `9000` requirement — ACS's own documentation for this exact case states the PC/SC-layer trailing status word is a synthetic value that "can simply be ignored," since DESFire's real status lives in the first response byte instead. `readDesfireVersion()` therefore does its own frame-continuation parsing rather than reusing `transceiveChecked`.

### New family: `TypeBTag`

`lib/ccid_iso_b.dart`, mirroring `IsoDepTag`'s shape:

```dart
class TypeBTag extends TagDriver {
  final Uint8List atqb;
  TypeBTag(super.card, this.atqb);

  Future<String?> transceive(String capdu) => card.transceive(capdu);
}
```

`identifyTag()` gains a new step: if the existing ATR/probing flow doesn't resolve to a known family (i.e. would otherwise throw `UnrecognizedTagException`), try `pollTypeB()` before giving up — if it answers, return `TypeBTag(card, result.atqb)`. This is additive to the existing, proven detection flow rather than a replacement of it (see Non-goals).

### `TagInfo`: common identification summary

Each driver gains a `readTagInfo()` method returning a family-specific info object, all of which expose a shared minimal shape for the example app to render uniformly:

```dart
abstract class TagInfo {
  String get technology;   // "MIFARE Classic 1K", "NTAG213", "FeliCa (RC-SA01/2)", "ISO14443-B", ...
  Uint8List get uid;       // UID/IDm as applicable
  Uint8List? get atr;      // from CcidCard.atr, where available
}
```

Concrete subclasses (`Type2TagInfo`, `MifareClassicInfo`, `FelicaInfo`, `IsoDepInfo`/`DesfireInfo`, `TypeBInfo`) carry the family-specific extras (SAK/ATQA, PMm/system codes, DESFire generation, ATQB) alongside the shared fields.

### Example app

New "Tag Info" section (before the existing family-specific sections) on `TagDetailsPage`, calling `driver.readTagInfo()` and rendering the common fields plus a few key family-specific extras (Model, and for FeliCa the full system-code list). Community-sourced fields (FeliCa model/system-code labels) are visually marked as such (e.g. a trailing "(unofficial)" note), consistent with the design's own sourcing caveats.

### Testing

- Unit tests per new pure function (`mifareFamilyFromSak`, `ultralightModelName`, `felicaModelName`, `felicaSystemCodeLabel`, `desfireGenerationLabel`) against hand-picked table entries — no hardware needed.
- Unit tests per new I/O method (`pollTypeA`/`pollTypeB`, `FelicaTag.pmm`/`requestSystemCodes`, `IsoDepTag.readDesfireVersion`) using the existing fake-`CcidPlatform` pattern, with capdu/response hex strings computed the same careful, verified-by-hand way the FeliCa fix's tests were (given how easy it is to get PN532 frame math wrong, per this project's own prior experience).
- **Real-hardware validation is required before this can be considered done for DESFire and Type B specifically** — see Open Questions. Type A SAK/ATQA polling and FeliCa PMm/system-codes can be validated against hardware you already have confirmed working (the same MIFARE Classic and FeliCa MRT cards from the original multi-tag-family pass).

## Open questions / risks

- **No confirmed DESFire or ISO14443-B test card.** Both were explicitly requested "build it now" despite this. The byte-level protocol details (3-frame DESFire exchange, Type B `InListPassiveTarget` response parsing) are grounded in official/primary documentation this time (not guesswork), which is a materially different risk profile than the original FeliCa escape-command guess that turned out wrong — but "grounded in docs" is not the same as "verified against real silicon." Flag clearly to the user once implemented: these two paths need a real test card before being trusted.
- **FeliCa IC-code model table and System Code registry are community-sourced, not official Sony publications.** No amount of implementation care changes this — it must stay labeled as best-effort/unofficial in the UI permanently, not just during initial rollout.
- **MIFARE Plus ambiguity is inherent, not a bug to fix.** AN10833 itself documents that some Plus configurations deliberately present a SAK indistinguishable from Classic for privacy reasons. This design reports the ambiguity rather than resolving it (see Non-goals) — full resolution would require implementing Plus's `VirtualCardSelect`/AES authentication flow, out of scope.
- **DESFire native-mode responses don't carry a real PC/SC status word** — confirmed from ACS's own documentation ("can simply be ignored"). `readDesfireVersion()` must not reuse `transceiveChecked`'s strict 9000 check, or every real DESFire read will incorrectly throw.
