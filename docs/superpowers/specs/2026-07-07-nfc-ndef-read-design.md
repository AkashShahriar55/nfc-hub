# NDEF Read Support for Contactless (NFC) Tags

## Context

The `ccid` plugin wraps PC/SC-style APDU transceive over CCID readers (contact and contactless). Contactless readers like the ACR1122U expose NFC Forum tags (e.g. NTAG213/215/216, Mifare Ultralight — "Type 2 Tags") as ordinary PC/SC cards. Right now the example app can only send raw hex APDUs by hand. We want a way to actually read the NDEF message (text/URL) stored on a Type 2 tag, to confirm end-to-end NFC read capability with the ACR1122U.

## Goals

- Read the full NDEF message from an NFC Forum Type 2 Tag connected through the existing PC/SC transceive channel.
- Decode the common well-known record types (Text, URI) into human-readable strings; fall back to raw hex for anything else.
- Expose this as a reusable library method, not just a one-off example hack.
- Prove it works via the example app against a real ACR1122U + physical tag.

## Non-goals

- NDEF Type 4 tags (ISO7816 NDEF application / access-card style tags).
- Writing/formatting NDEF data.
- Automated hardware-in-the-loop tests (no CI hardware available) — verification is manual, plus a pure-parsing unit test with hand-crafted bytes.

## Design

### New file: `lib/ccid_ndef.dart`

`NdefRecord` class:
- Fields: `tnf` (int), `type` (`Uint8List`), `id` (`Uint8List`), `payload` (`Uint8List`).
- `typeString` getter: UTF-8 decode of `type`.
- `asText` getter: if this is a well-known ("T") record, decode the text payload (status byte → language-code length + UTF-8/UTF-16 flag, then language code, then text). Returns `null` otherwise.
- `asUri` getter: if this is a well-known ("U") record, expand the URI Identifier Code prefix (NFC Forum standard prefix table) and append the URI suffix. Returns `null` otherwise.
- `toString()`: `asText ?? asUri ?? 'NdefRecord(tnf: $tnf, type: $typeString, payload: <hex>)'`.

A private TLV/record parser (top-level functions in the same file):
- `_parseTlvForNdefMessage(Uint8List data) -> Uint8List?` — scans TLVs (skip `0x00`, stop at `0xFE`), returns the value of the first NDEF Message TLV (`0x03`), or `null` if none found.
- `_parseNdefRecords(Uint8List message) -> List<NdefRecord>` — walks NDEF record headers (MB/ME/CF/SR/IL/TNF flags, type length, payload length (1 or 4 bytes), id length) until the record with the ME flag set or the buffer is exhausted.

### `CcidCard.readNdef()` in `lib/ccid.dart`

```dart
Future<List<NdefRecord>> readNdef() async
```

Steps:
1. `transceive('FFB0000304')` to read page 3 (Capability Container). Strip trailing 2-byte SW, verify `9000`. Verify byte 0 is `0xE1` (NDEF magic); if not, throw `Exception('Tag does not contain NDEF data (no capability container found)')`.
2. Compute `dataAreaSize = cc[2] * 8` bytes.
3. Loop reading 16-byte (4-page) chunks starting at page 4 (`FFB000<page><10>`) until `dataAreaSize` bytes have been read or a chunk's SW isn't `9000` (stop early, keep what was read so far).
4. Concatenate chunks into one buffer, pass to `_parseTlvForNdefMessage`. If `null`, throw `Exception('No NDEF message found on tag')`.
5. Pass the message bytes to `_parseNdefRecords`, return the resulting list.

`ccid.dart` adds `export 'ccid_ndef.dart';` so `NdefRecord` is available to consumers importing `package:ccid/ccid.dart`.

### Example app (`example/lib/main.dart`)

- Add a "Read NFC Tag" `ElevatedButton` next to Connect/Send APDU.
- Handler: if `_card != null`, call `await _card!.readNdef()` in a try/catch.
  - On success: insert `'NDEF: ${records.join(', ')}'` (or one line per record) into `_history`.
  - On failure: insert `'NDEF read failed: $e'` into `_history`.

### Testing

- Unit test in `test/ccid_ndef_test.dart`: hand-construct a byte buffer representing a CC + TLV + NDEF Text record, feed it through the parsing functions directly (not through `transceive`), assert the decoded text matches. This exercises the parsing logic without needing hardware.
- Manual verification: run the example app against the ACR1122U with a real NTAG-family tag (e.g. written via a phone NFC-writing app) and confirm the decoded text/URI shows up in the history list.

## Open questions / risks

- Some older/larger tags encode CC size differently (size byte `0xFF` meaning "read an extra 2-byte size field"); out of scope for this pass — only the common single-byte size encoding is handled. If it comes up in manual testing we'll revisit.
- Multi-chunk SR=false (long record, 4-byte length) records are supported by the parser even though most simple test tags will use short records.
