# Full Tag Info: UID, Memory Dump, Capability Container, Chip Version

## Context

`readNdef()` (already shipped on this branch) reads only the NDEF message off a Type 2 Tag. The user now wants "all info" about the physical chip, not just its NDEF payload: the UID, the raw memory contents, the parsed Capability Container fields, and (best-effort) the chip's identification/version. This is being tested live against a physical ACR1122U reader connected to an Android phone over USB OTG.

## Goals

- Read the tag's UID via the standard PC/SC "Get Data" pseudo-APDU.
- Read and parse the Capability Container (CC) into named fields (magic byte, version, size, access conditions), not just the raw bytes `readNdef()` currently uses internally.
- Read the tag's full raw memory (every readable page, not just the NDEF data area).
- Attempt to read chip identification via the NXP `GET_VERSION` (0x60) command, best-effort, returning `null` if the reader doesn't support the escape command this requires.
- Expose all of the above as independently callable methods (per user's explicit preference), not one combined call.
- Refactor `readNdef()`'s internal CC parsing to reuse the new `readCapabilityContainer()` instead of duplicating it.
- Show the results in a dedicated details screen in the example app, not squeezed into the existing one-line history list.

## Non-goals

- Deriving a human-readable storage-size (in bytes) from the GET_VERSION `storageSize` byte — no verified-correct formula is available, so the raw byte is exposed as-is rather than guessing.
- Making `readChipVersion()` work across all reader vendors — it targets the ACS/PN532-family "direct transmit" pseudo-APDU convention (`FF0000000160`) as a first attempt; other reader chipsets may need a different escape command, to be discovered through hardware testing.
- NDEF writing, Type 4 tags — same non-goals as the original NDEF design, still apply.

## Design

### New file: `lib/ccid_tag_info.dart`

Two pure data classes (no I/O), parsed from raw bytes:

```dart
class CapabilityContainer {
  final int magicByte;
  final int version;
  final int size;
  final int accessByte;

  bool get isNdefFormatted => magicByte == 0xE1;
  int get dataAreaSize => size * 8;
  int get majorVersion => (version >> 4) & 0x0F;
  int get minorVersion => version & 0x0F;
  int get readAccess => (accessByte >> 4) & 0x0F;
  int get writeAccess => accessByte & 0x0F;

  static CapabilityContainer parse(Uint8List bytes); // expects 4 bytes
}

class ChipVersion {
  final int headerByte;
  final int vendorId;
  final int productType;
  final int productSubtype;
  final int majorVersion;
  final int minorVersion;
  final int storageSize;
  final int protocolType;

  static ChipVersion parse(Uint8List bytes); // expects 8 bytes
}
```

### `lib/ccid.dart` additions on `CcidCard`

- `Future<Uint8List> readUid()` — `transceive('FFCA000000')`, strip/check SW, return data.
- `Future<CapabilityContainer> readCapabilityContainer()` — `transceive('FFB0000304')`, strip/check SW, `CapabilityContainer.parse(bytes)`. `readNdef()` is refactored to call this instead of its current inline CC read+magic-byte check.
- `Future<Uint8List> readMemoryDump()` — same chunked-read loop shape as `readNdef()`'s page-reading loop, but starting at page 0 (not 4) and with no `dataAreaSize` upper bound — it just keeps reading 16-byte chunks until a `transceive` call throws or returns a bad SW, capped at page 255 (same ceiling `readNdef()` already enforces). Returns whatever was successfully read.
- `Future<ChipVersion?> readChipVersion()` — `transceive('FF0000000160')` wrapped in try/catch; on success with a good SW and exactly 8 bytes of data, returns `ChipVersion.parse(bytes)`; on any failure (bad SW, wrong length, thrown exception), returns `null` rather than throwing.

### Example app

Replace the "Read NFC Tag" button with "Read Tag Details", which pushes a new `TagDetailsPage` route. That page independently calls `readUid()`, `readCapabilityContainer()`, `readNdef()`, `readMemoryDump()`, and `readChipVersion()` and renders each result (or its own error) in its own labeled section, so one failing call doesn't blank the whole screen.

### Testing

- Unit tests for `CapabilityContainer.parse` and `ChipVersion.parse` with hand-crafted byte arrays (pure parsing, no hardware).
- Manual verification against the ACR1122U + a physical NTAG-family tag for all five methods, with `readChipVersion()` specifically flagged as needing iteration if the first attempt's pseudo-APDU doesn't match this reader's supported command set.

## Open questions / risks

- `readChipVersion()`'s exact escape command is unverified against the ACR1122U specifically; expect at least one round of "try it, see what comes back, adjust" during manual testing.
- `readMemoryDump()`'s upper bound (page 255) is the same practical ceiling already accepted for `readNdef()` — a tag with more than 1024 bytes of memory would be truncated, but no currently common Type 2 Tag is that large.
