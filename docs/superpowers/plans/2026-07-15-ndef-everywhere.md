# NDEF Everywhere + Richer Records Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make NDEF reading work across tag families and decode the record types people actually use. Add Type-4 NDEF read (over ISO-DEP, so it works on phone and reader), reassemble chunked records, and decode Smart Poster / WiFi / vCard / MIME / Android Application Record in addition to today's Text and URI.

**Architecture:** Mostly pure Dart, fully unit-testable — this plan barely touches native code. Type-4 NDEF read is a new `readNdef()` on `IsoDepTag` using the standard ISO 7816-4 NDEF-application procedure over the existing portable `IsoDepTransport.transceive` (works on both backends, no new Kotlin). The record decoding and chunk reassembly extend the existing `NdefRecord`/parser in `lib/src/ndef.dart`, which every family's `readNdef()` already shares — so improving it improves NDEF reads everywhere at once.

**Tech Stack:** Flutter 3.38.3 / Dart SDK `>=3.5.0 <4.0.0`, `flutter_test`. No native changes, no new dependencies.

## Global Constraints

- **NDEF read is Type-2-only today; this generalizes it.** `readNdef()` exists on `Type2Tag` (and, after Plan 5, `Type5Tag`). This plan adds it to `IsoDepTag` (Type 4). All three parse with the SAME shared functions in `lib/src/ndef.dart` — do NOT fork the parser.
- **The shared parser is the leverage point.** Chunk reassembly and the new record decoders go into `lib/src/ndef.dart`, so they benefit Type 2, Type 4, and Type 5 reads identically. Keep the parser transport-agnostic (it takes bytes, not a driver).
- **Type-4 NDEF read is portable — no new Kotlin.** It uses `IsoDepTransport.transceive` (ISO 7816-4 APDUs), which works identically on the CCID reader and the phone. This is a big part of why it's here and not in a native plan.
- **Additive only.** Existing `readNdef()` behavior on Type 2 (and Type 5) must not change — the parser changes must be backward-compatible (a non-chunked message parses exactly as before; the existing Text/URI getters keep working).
- **Test baseline: (Plan 5's total) library tests + 19 example tests, 0 failing.** Every task adds tests; counts only go up. This whole plan is unit-testable — there is no hardware gate for the record decoding or chunk reassembly, and Type-4 read is testable against a fake transport with scripted APDU responses (the only manual check is a real Type-4 tag, which is optional).
- `flutter analyze` clean (2 pre-existing example info-lints expected). `flutter pub publish --dry-run` 0 warnings, < 1 MB. Do NOT touch `LICENSE` or `android/`.

## Roadmap

- Plans 1-4 (done) → 0.6.0. Plan 5 (NFC-V/Type 5) → 0.7.0.
- **Plan 6 (this document):** Type-4 NDEF read + chunk reassembly + richer record decoders. → 0.8.0.

Assumes Plan 5 has landed (this plan builds on the same barrel/version). If run before Plan 5, adjust the version bump and baseline test count accordingly.

## File Structure

New:
```
lib/src/ndef_records.dart          # the richer record decoders (SmartPoster/WiFi/vCard/MIME/AAR)
test/ndef_records_test.dart
test/tag/iso_dep_ndef_test.dart    # Type-4 readNdef() against a fake transport
```
Changed:
```
lib/src/ndef.dart                  # chunk reassembly in parseNdefRecords; keep Text/URI getters
lib/src/tag/iso_dep.dart           # + readNdef() (Type-4 NDEF application procedure)
lib/nfc_hub.dart                   # export the new record decoders / helper types
example/lib/tag_detail_page.dart   # IsoDepTag "NDEF" action; render decoded record types nicely
CHANGELOG.md, pubspec.yaml         # 0.8.0
```

---

### Task 1: Chunked-record reassembly in the shared parser

`parseNdefRecords` today does not reassemble chunked records (the `CF` flag) — the doc comment at `lib/src/ndef.dart:170-172` says each physical record is returned separately. Chunking is used for large payloads. Reassemble them so a chunked message yields one logical `NdefRecord`. Pure parsing; fully testable.

**Files:**
- Modify: `lib/src/ndef.dart`, `test/ndef_test.dart` (or a new `test/ndef_chunk_test.dart`)

**Interfaces:**
- `parseNdefRecords(Uint8List message)` — same signature. New behavior: a record with the Chunk Flag (`CF`, `0x20`) begins a chunk sequence; the first chunk carries the TNF + type (its type length may be 0 for continuation chunks per NDEF spec — the continuation chunks have TNF 0x06 "unchanged" and typeLength 0), and subsequent records with `CF` set (and the final one with `CF` clear) are concatenated into one payload. Return one `NdefRecord` per logical record. A malformed chunk sequence (e.g. missing terminator) degrades gracefully — return what was assembled, don't throw.

- [ ] **Step 1: write failing tests:**
  - A single record split into 3 chunks (first: `MB=1,CF=1,SR,TNF=well-known,type='T'`; middle: `CF=1,TNF=0x06 unchanged,typeLen=0`; last: `CF=0,ME=1,TNF=0x06,typeLen=0`) reassembles to ONE `NdefRecord` whose payload is the concatenation, and whose `asText` decodes correctly.
  - A non-chunked message still parses EXACTLY as before (regression — reuse an existing `ndef_test.dart` fixture and assert identical output).
  - A truncated chunk sequence returns the partial record without throwing.
- [ ] **Step 2-4:** run→fail, implement (track an in-progress chunk buffer in the parse loop; on `CF` start/continue accumulating, on `CF` clear finalize), run→pass. Keep the existing non-chunked path byte-identical.
- [ ] **Step 5: commit** `"feat: reassemble chunked NDEF records in the shared parser"`.

---

### Task 2: Richer record decoders (Smart Poster, WiFi, vCard, MIME, AAR)

Add typed decoders alongside the existing `asText`/`asUri`. Pure functions over `NdefRecord`; fully testable with hand-built record bytes.

**Files:**
- Create: `lib/src/ndef_records.dart`, `test/ndef_records_test.dart`
- Modify: `lib/src/ndef.dart` (only if a getter is cleaner as a method on `NdefRecord`; prefer top-level/extension functions in the new file to keep `ndef.dart` focused), `lib/nfc_hub.dart` (exports)

**Interfaces:** an `extension NdefRecordDecoders on NdefRecord` (or top-level functions) providing:
- `String? get asMimeType` / `Uint8List? get mimePayload` — for `TNF == 0x02` (MIME media): `typeString` is the MIME type, payload is the content.
- `String? get androidApplicationRecord` (AAR) — external type `TNF == 0x04`, type `android.com:pkg`; payload is the package name (UTF-8).
- `SmartPoster? get asSmartPoster` — well-known type `'Sp'`: parse the nested NDEF message in the payload (recurse via `parseNdefRecords`), extract its URI record (the target) and any Text records (titles). `SmartPoster` value type: `{Uri? uri, Map<String,String> titles, ...}` (keep it minimal — uri + title text).
- `WifiCredential? get asWifi` — MIME type `application/vnd.wfa.wsc`: parse the WSC TLV for SSID (`0x1045`) and network key (`0x1027`). `WifiCredential`: `{String? ssid, String? networkKey, ...}`.
- `VCard? get asVCard` — MIME type `text/vcard` or `text/x-vcard`: return the raw vCard text (do NOT fully parse vCard; expose `String text` and, best-effort, a `name` line). `VCard`: `{String text, String? formattedName}`.

Each returns null when the record isn't that type — same pattern as `asText`/`asUri`.

- [ ] **Step 1: write failing tests** in `ndef_records_test.dart`, hand-constructing a record of each kind and asserting the decode:
  - MIME record (`TNF=0x02`, type `application/json`, payload bytes) → `asMimeType == 'application/json'`, `mimePayload` matches.
  - AAR (`TNF=0x04`, type `android.com:pkg`, payload `com.example.app`) → `androidApplicationRecord == 'com.example.app'`.
  - Smart Poster (`TNF=0x01`, type `Sp`, payload = a nested NDEF message containing a URI record `https://example.com` + a Text record "Example") → `asSmartPoster.uri`/`.title` correct.
  - WiFi WSC (MIME `application/vnd.wfa.wsc`, payload = WSC TLV with SSID + key) → `asWifi.ssid`/`.networkKey` correct.
  - vCard (MIME `text/vcard`, payload = a small vCard) → `asVCard.text` matches, `formattedName` extracted.
  - Each decoder returns null for a record of a different type.
- [ ] **Step 2-4:** run→fail, implement, run→pass.
- [ ] **Step 5: update `NdefRecord.toString()`** (in `ndef.dart`) to also surface Smart Poster / MIME / AAR in its human-readable fallback (currently it does Text → URI → raw). Keep it backward-compatible (Text and URI first, as now). Add a test for the new `toString` branches.
- [ ] **Step 6: export** the decoders + value types (`SmartPoster`, `WifiCredential`, `VCard`) from `lib/nfc_hub.dart`.
- [ ] **Step 7: commit** `"feat: decode Smart Poster / WiFi / vCard / MIME / AAR NDEF records"`.

---

### Task 3: Type-4 NDEF read on `IsoDepTag`

Add `readNdef()` to `IsoDepTag` using the NFC Forum Type 4 procedure over ISO 7816-4 APDUs. Portable (works on phone and reader). Tested against a fake transport with scripted APDU responses.

**Files:**
- Modify: `lib/src/tag/iso_dep.dart`, `test/tag/iso_dep_ndef_test.dart` (new)

**Interfaces:**
- `IsoDepTag.readNdef()` → `Future<List<NdefRecord>>`. The Type 4 procedure (standard ISO 7816-4 APDUs, all via `transport.transceive`):
  1. **SELECT the NDEF Tag Application** by AID `D2760000850101`: `00 A4 04 00 07 D2760000850101 00`. Expect `9000`. (Fall back to the older AID `D2760000850100` if the first fails, then throw "no NDEF application" if both fail.)
  2. **SELECT the CC file** (file id `E103`): `00 A4 00 0C 02 E103`. Expect `9000`.
  3. **READ BINARY the CC** (offset 0, length 15): `00 B0 00 00 0F`. Parse: the CC gives the NDEF file id (bytes 9-10) and max read size. Verify the NDEF File Control TLV (tag `04`).
  4. **SELECT the NDEF file** by the id from the CC.
  5. **READ BINARY the NLEN** (first 2 bytes, offset 0): `00 B0 00 00 02` → NLEN = big-endian length of the NDEF message.
  6. **READ BINARY the NDEF message** starting at offset 2, NLEN bytes (chunk the reads by the max read size from the CC if NLEN is large).
  7. `parseNdefRecords(message)` → records. (Note: Type 4's NDEF file is the raw message, NOT wrapped in the Type-2 TLV — so use `parseNdefRecords` directly, NOT `parseTlvForNdefMessage`.)
  Throw a clear exception at each step if the card doesn't respond `9000` (e.g. "Card has no NDEF application", "Failed to select NDEF file").

- [ ] **Step 1: write failing tests** in `iso_dep_ndef_test.dart` against a `_FakeIsoDepTransport` that maps the exact request APDUs above to scripted responses (a small NDEF Text message):
  - the happy path: SELECT app → SELECT CC → read CC → SELECT NDEF file → read NLEN → read message → decodes to the expected Text record. Assert the EXACT APDUs sent in order (`containsAllInOrder`) so the Type 4 procedure's wire bytes are pinned.
  - the AID-fallback path: first SELECT (`...0101`) returns `6A82`, second (`...0100`) succeeds.
  - "no NDEF application": both SELECTs fail → the documented exception.
  - a card that selects the app but has no NDEF file → the documented exception.
- [ ] **Step 2-4:** run→fail, implement, run→pass.
- [ ] **Step 5: verify** the existing `IsoDepTag` tests (SELECT, transceive, DESFire) still pass unchanged — `readNdef()` is purely additive.
- [ ] **Step 6: commit** `"feat: Type 4 NDEF read on IsoDepTag (ISO 7816-4 NDEF application)"`.

---

### Task 4: Harness support + release 0.8.0

**Files:**
- Modify: `example/lib/tag_detail_page.dart`, `CHANGELOG.md`, `pubspec.yaml`, `lib/nfc_hub.dart` (confirm exports)

- [ ] **Step 1: `IsoDepTag` "NDEF" action** — add a button in `_actionsFor`'s `IsoDepTag` branch: "NDEF (Type 4)" → `readNdef()` → records joined (or '(no NDEF)' / the error via `ResultTile`). It sits alongside the existing SELECT/DESFire buttons.
- [ ] **Step 2: render decoded record types** — where the harness shows NDEF records (Type 2, Type 4, Type 5), use the new decoders so a Smart Poster / WiFi / MIME / AAR record shows its decoded form, not just raw hex. A small `_describeNdef(NdefRecord r)` helper: try `asText`, `asUri`, `asSmartPoster`, `asWifi`, `asVCard`, `asMimeType`, `androidApplicationRecord`, then fall back to `r.toString()`. Use it in every place the harness lists records.
- [ ] **Step 3: CHANGELOG `## 0.8.0`** — Type 4 NDEF read on ISO-DEP cards (works on phone and reader); chunked-record reassembly; and decoding for Smart Poster, WiFi credentials, vCard, MIME, and Android Application Record. Note NDEF read now spans Type 2, Type 4, and Type 5. Set `version: 0.8.0`.
- [ ] **Step 4: verify** — `flutter analyze`; library `flutter test` (up); example `flutter test` (green); example APK builds; `flutter pub publish --dry-run` 0 warnings, < 1 MB. Update the README's NDEF note if it claims Type-2-only.
- [ ] **Step 5: commit** `"feat(example): Type-4 NDEF + decoded record types in the harness; release 0.8.0"`.

---

## Definition of Done

- `flutter analyze` clean; library tests up, 0 failing; example tests green; publish dry-run 0 warnings; APK builds.
- NDEF read works on Type 2, Type 4, and Type 5, all through the one shared parser.
- Chunked records reassemble; Smart Poster / WiFi / vCard / MIME / AAR decode; Text/URI unchanged.
- Existing Type-2 NDEF behavior is byte-identical (regression-tested); the existing `IsoDepTag` methods are unchanged (`readNdef` is additive).
- **No hardware gate is required for correctness** (all unit-tested against fakes). Optional real-tag check: read a phone-written Type-4 NDEF tag and a Smart Poster / WiFi tag to confirm end-to-end — but the wire bytes are already pinned by tests.
