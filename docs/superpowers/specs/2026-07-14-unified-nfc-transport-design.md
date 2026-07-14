# nfc_hub — Unified NFC Transport: Built-in Android NFC + External CCID Readers

## Context

The `ccid` plugin currently reads NFC tags exclusively through external
USB CCID-class readers (Android `UsbManager` on mobile, PC/SC via
`dart_pcsc` on desktop). Every tag driver (`Type2Tag`, `MifareClassicTag`,
`FelicaTag`, `TypeBTag`, `IsoDepTag`) is built on ACS ACR122U/PN532-specific
PC/SC pseudo-APDUs (`FFCA` Get Data, `FFB0` Read Binary, `FF82`/`FF86`
Load Key/General Authenticate, `FF00`-escape-wrapped PN532 native
commands). There is no use of `android.nfc.*` anywhere.

We want the library to also read tags via the phone's built-in NFC
antenna, behind one API, so the app developer — and the end user — never
has to care which channel produced the tag.

**North star: seamlessness.** The minimal integration is a single stream
of `TagDriver`s; nothing in the default path requires branching on
source. Everything source-aware (per-reader filters, connection-state UI,
NFC-off prompts) is opt-in.

Scope is Android-only (built-in NFC exists only there among our targets;
the existing desktop PC/SC path keeps working through the CCID backend
but gains no built-in-NFC source).

## Goals

- One unified `tagStream()` emitting `TagDriver`s from either source:
  built-in NFC tap or card placed on an external CCID reader.
- One-shot `readTag()` (first tag from anywhere, optional source filter,
  optional timeout) built on the same stream.
- Auto-detection on the external path: no manual `connect()` call — a
  polling loop notices card insertion/removal on attached readers.
- A `connectionState()` stream reporting built-in NFC availability
  (present/enabled/why-not) and per-reader card presence, for apps that
  want richer status UI.
- `openNfcSettings()` deep-link so apps can prompt users to enable NFC.
- All five existing tag drivers work identically over both transports.

## Non-goals

- NDEF or tag **writing** / formatting.
- iOS/macOS/Linux/Windows built-in-NFC parity (pubspec still declares
  those platforms; the CCID/PC/SC path there is unchanged, but no new
  work targets them).
- Host card emulation.
- Library-owned UI (dialogs, snackbars) — the library exposes state and
  actions; the app owns all presentation.
- API backward compatibility. The package is pre-1.0 (v0.3.0); the
  `CcidCard`-centric public API is redesigned freely.

## Architecture

```
NfcHub().tagStream() / readTag() / connectionState()
   ├─ AndroidNfcSource  (NfcAdapter.enableReaderMode → Tag → typed transports)
   └─ CcidSource        (USB CCID readers → poll loop → typed transports,
                         PN532/PC-SC pseudo-APDU wrapped)
                    │
                    ▼
     identifyTag(transports, techHint?) → TagDriver
  (Type2Tag / MifareClassicTag / FelicaTag / TypeBTag / IsoDepTag)
```

### Layer 1: Per-technology transport interfaces (`lib/src/transport/`)

The single `CcidCard.transceive(hexApdu)` primitive is replaced by typed
interfaces per tag technology. Drivers depend only on their own family's
interface; the reader-dialect wrapping moves *down* into the CCID
backend instead of living inside each driver.

```dart
abstract class IsoDepTransport {
  /// ATR (CCID) or ISO-DEP historical bytes (Android), when available.
  Uint8List? get historicalBytes;
  Future<Uint8List> transceive(Uint8List apdu);
}

abstract class NfcATransport {
  Uint8List get atqa;
  int get sak;
  Uint8List get uid;
  Future<Uint8List> transceive(Uint8List cmd);
}

abstract class NfcFTransport {
  Future<Uint8List> transceive(Uint8List felicaCmd); // raw JIS X 6319-4 frame
}

abstract class NfcBTransport {
  Uint8List get atqb;
  Future<Uint8List> transceive(Uint8List cmd);
}

/// Real methods, not command bytes: Android's crypto1 handshake
/// (MifareClassic.authenticateSectorWithKeyA/B) is not a proxyable
/// byte stream, and on CCID the reader performs the cipher itself.
abstract class MifareClassicTransport {
  Uint8List get uid;
  Future<void> authenticate(int sector, MifareKeyType type, Uint8List key);
  Future<Uint8List> readBlock(int block);
}
```

A tag is delivered to `identifyTag` as a bundle of whichever transports
its source can offer (Android: derived from `Tag.getTechList()`; CCID:
all of them, since capability is unknown until probed).

### Layer 2: Backends

**CcidTransportBackend** — mechanical extraction of logic that already
exists. `NfcFTransport.transceive` = today's `D4 40 01` InDataExchange
escape wrapping from `ccid_felica.dart`; `MifareClassicTransport` =
today's `FF82`/`FF86` pseudo-APDUs; `NfcATransport`/`NfcBTransport`
identity fields come from the existing PN532 `InListPassiveTarget` poll
(`src/pn532.dart`); `IsoDepTransport.transceive` = plain APDU
passthrough with `historicalBytes` = ATR. No protocol changes.

**AndroidNfcTransportBackend** (new Kotlin + Dart) —
`NfcAdapter.enableReaderMode(activity, callback, FLAG_READER_NFC_A |
NFC_B | NFC_F | SKIP_NDEF_CHECK, extras)` wired into
`CcidPlugin`'s existing `ActivityAware` lifecycle. On
`onTagDiscovered(tag)`, the plugin assigns the tag a handle, sends a
discovery event to Dart with the tech list + identity fields
(UID/ATQA/SAK/ATQB/historical bytes), and services transceive calls by
handle: `IsoDep.transceive()`, `NfcA.transceive()`, `NfcF.transceive()`,
`NfcB.transceive()`, `MifareClassic.authenticateSectorWithKeyA/B` +
`readBlock` — all near 1:1, no PN532 framing. Tag-lost
(`TagLostException`) surfaces as a typed error and closes that tag's
session.

Channel shape: a single `nfc_hub` MethodChannel carries the methods
(`listReaders`/`connect`/`transceive`/`disconnect` from today, plus
`nfcStartReaderMode`, `nfcStopReaderMode`, `nfcTransceive`,
`nfcMifareAuth`, `nfcMifareReadBlock`, `getNfcState`,
`openNfcSettings`), plus one EventChannel (`nfc_hub/events`) for
discovery/removal/state-change events. One channel pair, not
per-tag channels.

### Layer 3: Tag identification

`identifyTag(transports, {TechHint? hint})`:

- **Android backend** always supplies a hint from `Tag.getTechList()`
  (deterministic — `MifareClassic` in the list → `MifareClassicTag`,
  `IsoDep` → `IsoDepTag`, `NfcF` → `FelicaTag`, `NfcB` without IsoDep →
  `TypeBTag`, `NfcA` + NDEF-capable/Ultralight → `Type2Tag`).
  `identifyTag` short-circuits straight to the matching driver.
- **CCID backend** supplies `hint: null` and falls through to the
  existing chain unchanged: ATR pattern match → ordered capability
  probing → `UnrecognizedTagException` with full probe log.

One function, one dispatch table, no duplicated per-backend logic.

### Package rename: `ccid` → `nfc_hub`

The plugin is renamed to reflect its new transport-neutral identity
(the name `ccid` describes only one of the two transports):

- pub.dev package name: `nfc_hub` (verified available).
- Android package: `com.cheqplease.nfchub` (Kotlin sources move from
  `im.nfc.ccid` to `com.cheqplease.nfchub`; plugin manifest, gradle
  namespace, and pubspec `pluginClass` entry updated to match).
- Dart entry point: `lib/nfc_hub.dart`; the primary class is `NfcHub`
  (replacing `Ccid`). Public types drop the `Ccid` prefix:
  `NfcHubConnectionState`, `NfcHubSourceFilter`, `TagSource`, etc.
  Method channel names become `nfc_hub` / `nfc_hub/events`.
- Repo homepage/repository fields in pubspec point at the new home.
  This codebase derives from nfcim's `ccid` plugin; its LICENSE and
  attribution are retained per its license terms.

### Layer 4: Public API (`lib/nfc_hub.dart`)

```dart
class NfcHub {
  /// Unified stream of identified tags from all sources.
  /// Listening starts reader-mode (built-in) and the CCID poll loop;
  /// cancelling the last listener stops both.
  Stream<TagDriver> tagStream({NfcHubSourceFilter? from});

  /// First tag from any (or the filtered) source.
  /// Sugar over tagStream(from: from).first with a timeout.
  Future<TagDriver> readTag({NfcHubSourceFilter? from, Duration? timeout});

  /// Connection/availability snapshots; fires on reader attach/detach,
  /// card insert/remove, and NFC radio toggle.
  Stream<NfcHubConnectionState> connectionState();

  /// Deep-link to the system NFC settings screen
  /// (Settings.ACTION_NFC_SETTINGS). Android only; no-op elsewhere.
  Future<void> openNfcSettings();
}

class NfcHubSourceFilter {
  const NfcHubSourceFilter.builtInNfc();
  const NfcHubSourceFilter.reader(String name);
}

enum NfcUnavailableReason { none, noHardware, disabled }

class NfcHubConnectionState {
  final bool builtInNfcAvailable;
  final NfcUnavailableReason builtInNfcReason; // .none when available
  final List<ExternalReaderState> externalReaders;
}

class ExternalReaderState {
  final String name;        // same names listReaders() produces today
  final bool cardPresent;
}
```

Each emitted `TagDriver` also carries a `source` descriptor
(`TagSource.builtInNfc` or `TagSource.reader(name)`) for apps that want
to display it — informational only, never required.

Minimal integration:

```dart
await for (final tag in NfcHub().tagStream()) {
  final info = await tag.readTagInfo();
  print(info.technology);
}
```

### Card presence detection (external readers)

Per attached CCID reader, a poll loop (default 500ms, configurable via
`NfcHub(pollInterval: ...)`):

- **No card seated:** attempt `iccPowerOn()` each tick. Success → card
  present; emit connection-state update and run `identifyTag` → emit
  `TagDriver` on `tagStream()`.
- **Card seated:** send a lightweight status probe each tick
  (`PC_to_RDR_GetSlotStatus` on the Android/USB path). Failure /
  ICC-absent status → card removed; emit state update, invalidate that
  tag's transports (subsequent calls throw a typed `TagLostException`),
  resume insertion polling.

The poll loop only runs while `tagStream()` or `connectionState()` has a
listener. Built-in NFC needs no polling — `onTagDiscovered` is already
event-driven, and reader-mode presence checks (`presence check` extra)
detect tag departure.

### NDEF reading

- **Android backend:** use `android.nfc.tech.Ndef.getNdefMessage()` —
  the OS parses CC/TLV itself and supports Type 2 *and* Type 4 tags.
  The plugin converts the platform `NdefMessage` into the existing
  `NdefRecord` shape. `Type2Tag.readNdef()` over this backend delegates
  to it.
- **CCID backend:** keep the current manual CC + page-walk + TLV parse
  (the NDEF parsing module is pure Dart and stays shared).

### Error handling

- `TagLostException` (new, typed): thrown by any transport call after
  the tag left the field / card was removed. Both backends map their
  native failure (Android `TagLostException`, CCID transceive/status
  failure) onto it.
- NFC off / no hardware: `tagStream()` does not error — it simply never
  emits from that source; `connectionState()` carries the reason so the
  app can prompt (`openNfcSettings()`).
- USB permission denied: surfaces on `connectionState()` as the reader
  disappearing from the list plus a one-time error event; the tag stream
  keeps serving other sources.
- Stream lifecycle errors (reader detached mid-read) map to
  `TagLostException` on in-flight calls, never a stream error, so one
  bad card never tears down the whole stream.

### Breaking changes

- `TagDriver` subclasses take typed transports instead of `CcidCard`.
- `CcidCard`, `listReaders()`, `connect()` are absorbed into the CCID
  backend as internals; `NfcHub().tagStream()` is the entry point.
- `identifyTag()` signature changes (transport bundle + hint).
- `CcidPlatform` (platform_interface) is reshaped around the new
  backend seam.
- All `test/ccid_*_test.dart` files are rewritten against fake transport
  implementations instead of a fake `CcidCard`.

### Android manifest / plugin changes

- Plugin manifest: `<uses-permission android:name="android.permission.NFC"/>`,
  `<uses-feature android:name="android.hardware.nfc" android:required="false"/>`
  (USB-reader-only devices must still install).
- Reader-mode enable/disable tied to `ActivityAware`
  `onAttachedToActivity`/`onDetachedFromActivity` *and* to whether any
  Dart listener is active (no battery drain while nobody listens).

## Testing

- **Dart unit tests:** each driver against fake per-technology
  transports (replaces the fake-`CcidCard` tests); `identifyTag`
  dispatch with and without hints; stream merge/filter/one-shot-timeout
  logic against fake sources; connection-state transitions from
  scripted event sequences.
- **CCID backend wrapping tests:** assert the exact pseudo-APDU bytes
  produced for each transport call (locks in today's PN532 dialect).
- **Manual hardware verification:** example app against (a) ACR122U +
  NTAG/MIFARE/FeliCa/DESFire cards — confirming no regression — and
  (b) a phone with built-in NFC reading the same physical tags,
  confirming identical `TagInfo`/NDEF output from both sources.
- Example app is rewritten around `tagStream()` + `connectionState()`,
  showing source badges and the NFC-off prompt flow.

## Risks / open questions

- **PC/SC desktop path**: `dart_pcsc` exposes its own reader/card model;
  the CCID poll loop there uses `SCardGetStatusChange` semantics instead
  of raw `iccPowerOn` polling. The backend seam covers it, but desktop
  is verify-only in this pass (no new desktop features).
- **Reader-mode vs. foreground dispatch**: reader mode requires a
  foreground Activity; background reads are out of scope (documented).
- **Type 2 vs. MIFARE Classic ambiguity on Android**: some devices
  (non-NXP NFC controllers) omit `MifareClassic` from the tech list even
  for Classic cards; those fall back to the SAK-based check in the hint
  mapper, and to `UnrecognizedTagException` at worst — same failure
  shape as CCID probing.
