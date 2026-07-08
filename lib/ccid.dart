import 'dart:typed_data';

import 'ccid_platform_interface.dart';

export 'ccid_felica.dart' show FelicaTag, FelicaReadResult;
export 'ccid_iso_dep.dart' show IsoDepTag;
export 'ccid_mifare_classic.dart'
    show MifareClassicTag, MifareKeyType, MifareAuthException;
export 'ccid_ndef.dart' show NdefRecord;
export 'ccid_tag_detection.dart' show identifyTag;
export 'ccid_tag_driver.dart' show TagDriver, UnrecognizedTagException;
export 'ccid_tag_info.dart' show CapabilityContainer, ChipVersion;
export 'ccid_type2.dart' show Type2Tag;

class Ccid {
  /// List available readers
  ///
  /// Returns a list of reader names
  Future<List<String>> listReaders() {
    return CcidPlatform.instance.listReaders();
  }

  /// Connect to a reader by its name [reader]
  ///
  /// Returns a [CcidCard] object
  Future<CcidCard> connect(String reader) {
    return CcidPlatform.instance.connect(reader);
  }
}

class CcidCard {
  final String reader;

  /// The card's answer-to-reset, captured at connect time where the
  /// platform supports it (Android only, currently). Null on platforms/
  /// paths that don't surface it — `identifyTag` falls back to capability
  /// probing in that case.
  final Uint8List? atr;

  CcidCard(this.reader, {this.atr});

  /// Send APDU command [capdu]
  ///
  /// Returns the response APDU
  Future<String?> transceive(String capdu) {
    return CcidPlatform.instance.transceive(reader, capdu);
  }

  /// Disconnect from the card
  Future<void> disconnect() {
    return CcidPlatform.instance.disconnect(reader);
  }
}
