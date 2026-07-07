import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'ccid_ndef.dart';
import 'ccid_platform_interface.dart';

export 'ccid_ndef.dart' show NdefRecord;

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

  CcidCard(this.reader);

  /// Send APDU command [cpadu]
  ///
  /// Returns the response APDU
  Future<String?> transceive(String capdu) {
    return CcidPlatform.instance.transceive(reader, capdu);
  }

  /// Disconnect from the card
  Future<void> disconnect() {
    return CcidPlatform.instance.disconnect(reader);
  }

  /// Reads the NDEF message from an NFC Forum Type 2 Tag (e.g. NTAG213/215/216,
  /// Mifare Ultralight) connected through a contactless PC/SC reader.
  ///
  /// Throws an [Exception] if the tag has no NDEF capability container or
  /// no NDEF message is found on it.
  Future<List<NdefRecord>> readNdef() async {
    final cc = await _transceiveChecked('FFB0000304');
    if (cc.isEmpty || cc[0] != 0xE1) {
      throw Exception(
          'Tag does not contain NDEF data (no capability container found)');
    }
    final dataAreaSize = cc[2] * 8;

    final buffer = BytesBuilder();
    var page = 4;
    while (buffer.length < dataAreaSize && page <= 0xFF) {
      final pageHex = page.toRadixString(16).padLeft(2, '0');
      String? chunkHex;
      try {
        chunkHex = await transceive('FFB00000${pageHex}10');
      } catch (_) {
        break;
      }
      final chunk = _stripAndCheckSw(chunkHex);
      if (chunk == null) break;
      buffer.add(chunk);
      page += 4;
    }

    final message = parseTlvForNdefMessage(buffer.toBytes());
    if (message == null) {
      throw Exception('No NDEF message found on tag');
    }
    return parseNdefRecords(message);
  }

  Future<Uint8List> _transceiveChecked(String capdu) async {
    final data = _stripAndCheckSw(await transceive(capdu));
    if (data == null) {
      throw Exception('Failed to read tag (bad response to $capdu)');
    }
    return data;
  }

  Uint8List? _stripAndCheckSw(String? responseHex) {
    if (responseHex == null || responseHex.length < 4) return null;
    final sw = responseHex.substring(responseHex.length - 4);
    if (sw.toUpperCase() != '9000') return null;
    final dataHex = responseHex.substring(0, responseHex.length - 4);
    return Uint8List.fromList(hex.decode(dataHex));
  }
}
