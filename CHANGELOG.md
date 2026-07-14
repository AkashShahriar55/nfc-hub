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

## 0.4.0

**Breaking:** the package is renamed from `ccid` to `nfc_hub`.

- Import path is now `package:nfc_hub/nfc_hub.dart`; `lib/` is restructured
  behind a single public entry point.
- `Ccid` is now `NfcHub`. `CcidPlatform`, `MethodChannelCcid`, and `PcscCcid`
  are now `NfcHubPlatform`, `MethodChannelNfcHub`, and `PcscNfcHub`.
  `CcidCard` keeps its name.
- The Android package is now `com.cheqplease.nfchub` and the plugin class is
  `NfcHubPlugin`. The method channel is named `nfc_hub`; the USB permission
  broadcast action is `com.cheqplease.nfchub.USB_PERMISSION`.
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
