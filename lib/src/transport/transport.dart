import 'dart:typed_data';

import '../tag/mifare_classic.dart' show MifareKeyType;

/// Thrown by any transport call after the tag has left the field or the
/// card was removed from the reader. Both backends map their native
/// failure onto this: Android's `TagLostException`, and a CCID
/// transceive/slot-status failure.
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

  /// The NXP `GET_VERSION` (0x60) response, or null where the reader or
  /// tag doesn't support it. Must not throw for the unsupported case.
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
  Future<void> authenticate(int sector, MifareKeyType type, Uint8List key);

  /// Reads one 16-byte block. Its sector must already be authenticated.
  Future<Uint8List> readBlock(int block);
}

/// Transport for a FeliCa (NFC-F / JIS X 6319-4) tag.
///
/// Raw-frame: the same length-prefixed FeliCa frame is valid on both
/// sides. Android's `NfcF.transceive` takes exactly this; the CCID backend
/// wraps it in the PN532 InDataExchange command (`D4 40 01`) and strips
/// the `D5 41 <status>` response header.
abstract class NfcFTransport {
  /// The 8-byte IDm.
  Future<Uint8List> get idm;

  /// The 8-byte PMm (Manufacturer Parameter).
  Future<Uint8List> get pmm;

  /// Sends a length-prefixed FeliCa frame, returns the raw response frame
  /// (its own length byte included).
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
