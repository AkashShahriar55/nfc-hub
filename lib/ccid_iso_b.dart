import 'dart:typed_data';

import 'ccid_tag_driver.dart';

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
/// ([pollTypeB] in `src/pn532.dart`) rather than the ATR/capability-probing
/// path the other families use (Type B isn't reachable through either of
/// those). Exposes the card's ATQB plus raw ISO7816 APDU passthrough,
/// mirroring [IsoDepTag]'s shape.
class TypeBTag extends TagDriver {
  final Uint8List atqb;

  TypeBTag(super.card, this.atqb);

  Future<String?> transceive(String capdu) => card.transceive(capdu);

  /// A generic identification summary. UID is the PUPI (bytes 1-4 of
  /// ATQB, per ISO14443-3's ATQB structure: `'50' | PUPI(4) | ...`).
  Future<TypeBInfo> readTagInfo() async {
    return TypeBInfo(
      uid: Uint8List.sublistView(atqb, 1, 5),
      atr: card.atr,
      atqb: atqb,
    );
  }
}
