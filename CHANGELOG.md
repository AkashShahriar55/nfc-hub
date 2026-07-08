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
