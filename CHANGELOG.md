## 0.8.0

First release on pub.dev.

- **Breaking:** `CcidSourceFilter` is now `NfcSource`, and
  `CcidSourceFilter.builtInNfc()` is now `NfcSource.builtIn()`.
- **Breaking:** `CcidConnectionState` is now `NfcConnectionState`.
- **Breaking:** `CcidCard` is now `ReaderCard`.
- **Breaking:** removed `NfcSource.toFilter()`; `NfcSource` is now the type the
  stream API takes directly.
- **Breaking:** the Android package is now `com.nsa.nfchub`, and the USB
  permission broadcast action is `com.nsa.nfchub.USB_PERMISSION`.
- Removed the unused Linux, Windows, and Darwin native directories. The package
  was already Android-only.
- CCID protocol identifiers (`CcidException`, `CcidSource`,
  `CcidTransportBackend`, the `CCID_*` error codes) are deliberately retained:
  they name the USB device class the plugin speaks.

## 0.7.0

Reliability release.

- **Fixed** the CCID poll loop freezing permanently when a USB permission
  dialog was denied, ignored, or the reader detached mid-request.
- **Fixed** duplicate tag deliveries: a seated card now emits exactly once
  per presentation (no replay on resubscribe/session restart); same-tag
  rediscoveries on the built-in antenna are debounced.
- **Fixed** built-in-NFC tag I/O blocking the main thread (jank, presence-
  check drops mid-read).
- **Fixed** reader mode not re-arming when NFC is enabled mid-session.
- **Fixed** MIFARE Classic cards being misidentified as ISO-DEP during
  capability probing; ISO-DEP `historicalBytes` now returns the ATR's
  historical bytes rather than the whole ATR.
- The CCID liveness probe no longer interleaves with in-flight reads
  (previously corrupted chained commands like DESFire GetVersion).
- Unreadable taps now surface on `onError` / as stream errors instead of
  being silently dropped.
- **Breaking:** package now declares Android support only.
- **Breaking:** removed the never-functional `AndroidNfcManager.tagLosses`.

## 0.6.0

Built-in Android NFC support: `NfcHub().tagStream()` now emits `TagDriver`s
from the device's own NFC antenna as well as from USB CCID readers, behind
one API. The same driver methods (`readNdef`, `readSector`,
`readWithoutEncryption`, etc.) work identically regardless of which source
found the tag.

* Add `NfcHub().tagStream({CcidSourceFilter? from})` -- a merged stream of
  `TagDriver`s from every source (built-in NFC and every attached CCID/PC-SC
  reader), or a single source when narrowed with `from`.
* Add `NfcHub().readTag({CcidSourceFilter? from, Duration? timeout})` -- a
  one-shot read: the first tag from any source (or a filtered source), with
  an optional timeout.
* Add `NfcHub().connectionState()` -- a stream of `CcidConnectionState`,
  combining built-in-NFC availability (`NfcUnavailableReason`: `none` /
  `noHardware` / `disabled`) with the live per-reader card presence
  (`ExternalReaderState`) of every attached CCID/PC-SC reader.
* Add `NfcHub().openNfcSettings()`, deep-linking to the system NFC settings
  screen.
* Add `CcidSourceFilter`, used with `tagStream`/`readTag` to restrict the
  merged stream to `CcidSourceFilter.builtInNfc()` or
  `CcidSourceFilter.reader(name)`.
* CCID readers now auto-detect card insertion/removal via a poll loop, so a
  reader feeds `tagStream()`/`connectionState()` on its own -- no manual
  `connect()` call needed to discover a tag.
* Add `identifyFromBackend(TransportBackend, {TagTechHint? hint})` and
  `TagTechHint`, for advanced callers implementing their own
  `TransportBackend` instead of going through a built-in source.
* Android: the plugin now declares the `android.permission.NFC` permission
  (with `android.hardware.nfc` as an optional `<uses-feature>`), needed for
  the built-in-NFC source.
* Unchanged: the CCID direct API (`listReaders()`, `connect()`,
  `identifyTag()`) behaves exactly as in 0.5.0.

## 0.5.0

**Internal:** tag drivers are now built on per-technology transport interfaces
(`Type2Transport`, `MifareClassicTransport`, `NfcFTransport`,
`IsoDepTransport`, `NfcBTransport`) rather than talking to a `CcidCard`
directly. The PC/SC and PN532 reader dialect now lives in exactly one place
(`CcidTransportBackend`, under `lib/src/transport/`). No behavior change:
reading a tag through a CCID reader works exactly as in 0.4.0.

This is the groundwork for built-in NFC support — a second backend can now
implement the same interfaces without touching a driver.

* Driver constructors now take a transport instead of a `CcidCard`. Use
  `identifyTag()` to obtain drivers; it is unchanged.
* `TagDriver` no longer exposes a `card` field.
* `TagLostException` is now exported from `package:nfc_hub/nfc_hub.dart`.
  `identifyTag()` can throw it (via `CcidTransportBackend.mifareClassic()`
  when no Type A target answers the poll); it was previously uncatchable by
  type outside the package.
* Fix: a rejected PN532 poll no longer makes ISO-DEP cards unusable on a
  generic (non-ACS) CCID reader. The `FF 00 00 00` escape that carries the
  poll is ACS-specific, and a reader that rejects it used to make
  `identifyTag()` hard-abort even though ISO 7816-4 APDUs need no reader
  dialect. The UID is now best-effort — `IsoDepTag` still works, just
  without a UID, if the poll fails.
* Fix: a failed Type A poll no longer hard-aborts ATR-path tag detection.
  When the ATR points at MIFARE Classic but the card doesn't answer the
  poll, `identifyTag()` now falls back to capability probing (as it always
  did for an unrecognized ATR) instead of propagating the raw
  `TagLostException`, and the resulting error reports every probe's
  outcome.
* Fix: a MIFARE Classic card is no longer silently misidentified as a
  generic ISO-DEP card when the PN532 identity poll is rejected. The ATR is
  now the stronger signal -- once it positively matches MIFARE Classic,
  `identifyTag()` returns `MifareClassicTag` directly rather than falling
  through to capability probing, whose loose SELECT-response heuristic
  could mistake an error status word for a real ISO-DEP SELECT. The
  driver's identity (uid/atqa/sak) degrades to empty/zero when the poll
  fails; MIFARE's actual operations (Load Key/General Authenticate/Read
  Binary) still work, since they need no PN532 dialect at all.
* `Type2Transport`, `MifareClassicTransport`, `NfcFTransport`,
  `IsoDepTransport`, and `NfcBTransport` are now exported from
  `package:nfc_hub/nfc_hub.dart`, so consumers can name a driver
  constructor's parameter type directly.
* Known limitations: `MifareClassicTransport.authenticate`'s and
  `MifareClassicTag.readSector`'s sector-to-block arithmetic assumes 4
  blocks per sector, which is wrong for MIFARE Classic 4K sectors 32-39 (16
  blocks each). Pre-existing; documented but not fixed in this release.

## 0.4.0

**Breaking:** the package is renamed from `ccid` to `nfc_hub`.

- Import path is now `package:nfc_hub/nfc_hub.dart`; `lib/` is restructured
  behind a single public entry point.
- `Ccid` is now `NfcHub`. `CcidPlatform`, `MethodChannelCcid`, and `PcscCcid`
  are now `NfcHubPlatform`, `MethodChannelNfcHub`, and `PcscNfcHub`.
  `CcidCard` keeps its name.
- The plugin class is now `NfcHubPlugin`, and the method channel is named
  `nfc_hub`.
- No functional changes: tag reading behaves exactly as in 0.3.0.
- `TagDriver` now declares `readTagInfo()`, so callers no longer need to type-check the concrete driver to call it. Every existing driver already implemented it; this only makes the contract explicit.

## 0.3.0

* Add `readTagInfo()` to every tag driver (`Type2Tag`, `MifareClassicTag`, `FelicaTag`, `IsoDepTag`, `TypeBTag`), returning a common `TagInfo` (technology, UID, ATR) plus family-specific details (SAK/ATQA, FeliCa PMm-derived chip model and system codes, DESFire generation).
* Add real SAK/ATQA identification via a new PN532 `InListPassiveTarget` poll (`pollTypeA`/`pollTypeB` in `src/pn532.dart`), independent of the ATR.
* Add `FelicaTag.pmm` and `FelicaTag.requestSystemCodes()`.
* Add `IsoDepTag.readDesfireVersion()`, decoding DESFire's 3-frame `GetVersion` exchange into `DesfireVersion` and resolving the exact generation (EV1/EV2/EV3/EV2 XL/DUOX/Light) via `desfireGenerationLabel()`.
* Add `TypeBTag`, a new ISO14443-B driver, and a matching `identifyTag()` fallback step.
* FeliCa chip-model and System Code labels are sourced from community reverse-engineering projects, not an official Sony publication — see the doc comments on `felicaModelName`/`felicaSystemCodeLabel`.

## 0.2.0

* **Breaking:** `CcidCard` is now a raw transport only (`transceive`, `disconnect`, `atr`). The Type 2 Tag reads previously on `CcidCard` (`readUid`, `readCapabilityContainer`, `readMemoryDump`, `readChipVersion`, `readNdef`) have moved to `Type2Tag`, obtained via `identifyTag(card)`.
* Add `identifyTag(CcidCard)`, which auto-detects the connected card's tag family (from its ATR where available, falling back to capability probing) and returns a typed driver: `Type2Tag`, `MifareClassicTag`, `FelicaTag`, or `IsoDepTag`.
* Add `MifareClassicTag` for MIFARE Classic 1K/4K cards: sector key authentication (`authenticate`, `authenticateWithDefaultKeys`) and block/sector reads.
* Add `FelicaTag` for FeliCa (NFC-F) cards: IDm polling and `readWithoutEncryption`.
* Add `IsoDepTag`, a thin generic ISO14443-4 driver (`selectApplication` + raw `transceive`) for DESFire and other applet-based cards — no DESFire-specific commands.
* Android: `connect()` now also returns the card's ATR, enabling ATR-based tag detection. Other platforms fall back to capability probing.

## 0.1.10

* Add `CcidCard.readUid()`, `readCapabilityContainer()`, `readMemoryDump()`, and best-effort `readChipVersion()` for Type 2 tags (NTAG213/215/216, Mifare Ultralight)
* Fix a malformed READ BINARY APDU that affected multi-page reads in `readNdef()` and `readMemoryDump()`

## 0.1.9

* Add NDEF read support for Type 2 tags (NTAG213/215/216, Mifare Ultralight) via `CcidCard.readNdef()`

## 0.1.8

* Improve compatibility

## 0.1.7

* Downgrade to Flutter 3.24

## 0.1.6

* No library functional changes
* Android: bump Kotlin to 2.1.0, lower JVM Target to 1.8
* iOS / macOS: add support for Swift Package Manager

## 0.1.5

* Use darwin shared library

## 0.1.4

* Fix state related issues on Android

## 0.1.3

* Use `RECEIVER_EXPORTED` for broadcast

## 0.1.2

* Fix Android 14's compatibility issue.

## 0.1.1

* Fix the pod name for iOS.

## 0.1.0

* Add basic support for Windows / Linux (via PCSC), macOS / iOS (via CryptoTokenKit), and Android (via USB operations).
