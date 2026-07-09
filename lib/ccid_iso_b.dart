import 'dart:typed_data';

import 'ccid_tag_driver.dart';

/// Thin driver for an ISO14443-B card, found via a raw PN532 poll
/// ([pollTypeB] in `src/pn532.dart`) rather than the ATR/capability-probing
/// path the other families use (Type B isn't reachable through either of
/// those). Exposes the card's ATQB plus raw ISO7816 APDU passthrough,
/// mirroring [IsoDepTag]'s shape.
class TypeBTag extends TagDriver {
  final Uint8List atqb;

  TypeBTag(super.card, this.atqb);

  Future<String?> transceive(String capdu) => card.transceive(capdu);
}
