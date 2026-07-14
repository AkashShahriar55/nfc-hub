import 'dart:typed_data';

import '../tag/mifare_classic.dart' show MifareKeyType;

/// Thrown by a transport call after the tag has left the field or the card
/// was removed from the reader.
///
/// **This contract is not yet unified across backends.** Today it is
/// reserved for backends that can detect tag loss explicitly -- i.e. the
/// future Android backend, via its native `TagLostException`. The CCID
/// backend does NOT currently throw this: a failed transceive or a
/// rejected/empty PN532 poll surfaces as a generic `Exception` (see
/// `transceiveChecked` in `lib/src/apdu.dart`), and `CcidTransportBackend`
/// no longer throws `TagLostException` at all as of the MIFARE Classic
/// identity-poll fix (its identity poll degrades to an empty/zero identity
/// instead). An app that catches `TagLostException` to detect card removal
/// will therefore see it on Android but never on CCID. Unifying the two
/// backends' error contracts is future work, not done here.
class TagLostException implements Exception {
  final String message;

  const TagLostException(this.message);

  @override
  String toString() => 'TagLostException: $message';
}

/// Transport for an NFC Forum Type 2 tag (NTAG / MIFARE Ultralight).
///
/// Method-based, not raw-byte: the ACR122U exposes Type-2 reads only as
/// PC/SC pseudo-APDUs (`FFB0` Read Binary, `FFCA` Get Data) which the
/// reader itself translates, so only the *operation* is portable, not the
/// byte sequence. Android implements these directly as `NfcA.transceive`
/// with the Type-2 command set (`0x30` READ, `0x60` GET_VERSION).
abstract class Type2Transport {
  /// The tag's UID.
  Future<Uint8List> readUid();

  /// The 4-byte Capability Container (page 3).
  Future<Uint8List> readCapabilityContainer();

  /// 16 bytes (4 pages) starting at [startPage].
  Future<Uint8List> readPages(int startPage);

  /// The NXP `GET_VERSION` (0x60) response: **exactly 8 bytes, or null**.
  ///
  /// Implementations MUST NOT throw, and MUST NOT return a non-null array of
  /// any other length — `Type2Tag.readChipVersion()` parses the result without
  /// a length guard and is documented as never throwing, so it relies on this.
  Future<Uint8List?> getVersion();
}

/// Transport for a MIFARE Classic 1K/4K tag.
///
/// Method-based: Android's crypto1 handshake
/// (`MifareClassic.authenticateSectorWithKeyA/B`) is not a proxyable byte
/// stream, and on CCID the reader runs the cipher itself via the `FF82`
/// Load Key / `FF86` General Authenticate pseudo-APDUs.
abstract class MifareClassicTransport {
  Uint8List get uid;
  Uint8List get atqa;
  int get sak;

  /// Authenticates [sector] with [key] as key [type].
  /// Throws [MifareAuthException] if the key is rejected.
  ///
  /// KNOWN LIMITATION: sector-to-block arithmetic here assumes 4 blocks per
  /// sector (`block = sector * 4`), which is correct for every 1K sector
  /// and for 4K sectors 0-31, but WRONG for 4K sectors 32-39 (16 blocks
  /// each). Android's `MifareClassic.sectorToBlock()` gets this right, so
  /// implementations of this interface will silently disagree on high 4K
  /// sectors until this is fixed as dedicated, separate work.
  Future<void> authenticate(int sector, MifareKeyType type, Uint8List key);

  /// Reads one 16-byte block. Its sector must already be authenticated.
  Future<Uint8List> readBlock(int block);
}

/// Transport for a FeliCa (NFC-F / JIS X 6319-4) tag.
///
/// Raw-frame, but **the framing is asymmetric between request and
/// response** -- see [transceive] for the exact, hardware-validated
/// contract. Get this wrong in a new backend and FeliCa reads fail
/// silently against real hardware (this is the only raw-frame interface
/// with real hardware validation, against the Dhaka MRT card).
abstract class NfcFTransport {
  /// The 8-byte IDm.
  Future<Uint8List> get idm;

  /// The 8-byte PMm (Manufacturer Parameter).
  Future<Uint8List> get pmm;

  /// Sends a FeliCa command frame and returns the raw response frame.
  ///
  /// **The framing is asymmetric -- read this carefully before implementing
  /// a new backend:**
  /// * [felicaFrame] passed IN is **UNPREFIXED**: just `command code` then
  ///   `payload`, with NO leading length byte. (See
  ///   `FelicaTag.readWithoutEncryption` and `requestSystemCodes` in
  ///   `lib/src/tag/felica.dart` -- both build frames with no length byte.)
  /// * The frame returned OUT is **length-prefixed**: `length` then
  ///   `response code` then `idm` (8 bytes) then `payload`, length byte
  ///   included. (This is why the driver reads status flag 1 at index 10:
  ///   len(1) + code(1) + idm(8).)
  ///
  /// Android's `NfcF.transceive()` REQUIRES the caller to supply the
  /// leading length byte itself. An implementation MUST prepend
  /// `felicaFrame.length + 1` before calling it -- passing [felicaFrame]
  /// straight through un-prepended (as the request-side symmetry might
  /// suggest) sends a malformed frame: the card reads the command code
  /// byte as the length and the transceive fails. The CCID backend does
  /// exactly this prepend before wrapping the frame in the PN532
  /// InDataExchange command (`D4 40 01`); it strips the `D5 41 <status>`
  /// response header but deliberately leaves the response's own length
  /// byte in place.
  Future<Uint8List> transceive(Uint8List felicaFrame);
}

/// Transport for a generic ISO14443-4 ("ISO-DEP") processor card.
///
/// Raw-frame: ISO 7816-4 APDUs pass through unchanged on both sides.
abstract class IsoDepTransport {
  /// The tag's UID. Empty if the source cannot supply one.
  Future<Uint8List> get uid;

  /// The card's ATR (CCID) or ISO-DEP historical bytes (Android), where
  /// the source supplies one.
  Uint8List? get historicalBytes;

  /// Sends a raw APDU and returns the raw response, INCLUDING any trailing
  /// status word. Callers do their own status-word handling — DESFire's
  /// native mode returns no SW at all, so this transport must not assume one.
  Future<Uint8List> transceive(Uint8List apdu);
}

/// Transport for an ISO14443-B card.
abstract class NfcBTransport {
  /// The PUPI (bytes 1-4 of ATQB).
  Uint8List get pupi;

  /// The 12-byte ATQB: `'50' | PUPI(4) | AppData(4) | ProtocolInfo(3)`.
  Uint8List get atqb;

  Future<Uint8List> transceive(Uint8List apdu);
}
