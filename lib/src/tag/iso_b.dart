import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'tag_driver.dart';
import '../transport/transport.dart';

class TypeBInfo implements TagInfo {
  @override
  final String technology = 'ISO14443-B';
  @override
  final Uint8List uid; // PUPI, 4 bytes
  @override
  final Uint8List? atr;
  final Uint8List atqb;

  TypeBInfo({required this.uid, required this.atr, required this.atqb});
}

/// Thin driver for an ISO14443-B card, found via a raw PN532 poll
/// ([NfcBTransport], backed by `pollTypeB` in `src/pn532.dart` on CCID)
/// rather than the ATR/capability-probing path the other families use
/// (Type B isn't reachable through either of those). Exposes the card's
/// ATQB plus raw ISO7816 APDU passthrough, mirroring [IsoDepTag]'s shape.
class TypeBTag extends TagDriver {
  final NfcBTransport transport;

  /// The card's ATR, where the source supplies one. Null on sources that
  /// have no ATR concept (the device's built-in NFC antenna).
  final Uint8List? atr;

  const TypeBTag(this.transport, {this.atr});

  Uint8List get atqb => transport.atqb;

  Future<String?> transceive(String capdu) async {
    final response =
        await transport.transceive(Uint8List.fromList(hex.decode(capdu)));
    return hex.encode(response).toUpperCase();
  }

  /// A generic identification summary. UID is the PUPI (bytes 1-4 of
  /// ATQB, per ISO14443-3's ATQB structure: `'50' | PUPI(4) | ...`).
  @override
  Future<TypeBInfo> readTagInfo() async {
    return TypeBInfo(
      uid: transport.pupi,
      atr: atr,
      atqb: transport.atqb,
    );
  }
}
