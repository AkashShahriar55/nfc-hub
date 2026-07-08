import 'ccid_tag_driver.dart';

/// Thin driver for a generic ISO14443-4 ("ISO-DEP") processor card (e.g.
/// DESFire or another applet-based smart card) connected through a
/// contactless PC/SC reader.
///
/// This driver only provides raw ISO 7816-4 SELECT + APDU transport; it has
/// no knowledge of any particular card's application/file model.
class IsoDepTag extends TagDriver {
  IsoDepTag(super.card);

  /// Sends a SELECT (by name/AID) command for [aidHex] (hex-encoded
  /// Application Identifier), returning the response APDU.
  Future<String?> selectApplication(String aidHex) {
    final lcHex = (aidHex.length ~/ 2).toRadixString(16).padLeft(2, '0');
    return card.transceive('00A40400$lcHex$aidHex');
  }

  /// Sends a raw APDU [capdu] (hex-encoded) and returns the response APDU
  /// (hex-encoded), unchanged from [CcidCard.transceive].
  Future<String?> transceive(String capdu) => card.transceive(capdu);
}
