import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'ccid_ndef.dart';
import 'ccid_platform_interface.dart';
import 'ccid_tag_info.dart';

export 'ccid_ndef.dart' show NdefRecord;
export 'ccid_tag_info.dart' show CapabilityContainer, ChipVersion;

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
    final cc = await readCapabilityContainer();
    if (!cc.isNdefFormatted) {
      throw Exception(
          'Tag does not contain NDEF data (no capability container found)');
    }
    final data = await _readPagesFrom(4, maxBytes: cc.dataAreaSize);
    final message = parseTlvForNdefMessage(data);
    if (message == null) {
      throw Exception('No NDEF message found on tag');
    }
    return parseNdefRecords(message);
  }

  /// Reads the tag's UID via the standard PC/SC "Get Data" pseudo-APDU.
  Future<Uint8List> readUid() {
    return _transceiveChecked('FFCA000000');
  }

  /// Reads and parses the tag's Capability Container (CC), normally found
  /// at page 3 of an NFC Forum Type 2 Tag's memory.
  Future<CapabilityContainer> readCapabilityContainer() async {
    final bytes = await _transceiveChecked('FFB0000304');
    if (bytes.length != 4) {
      throw Exception(
          'Failed to read Capability Container (expected 4 bytes, got ${bytes.length})');
    }
    return CapabilityContainer.parse(bytes);
  }

  /// Reads the tag's full raw memory, starting at page 0, until a page
  /// read fails or the page number would no longer fit in one byte.
  ///
  /// This includes the UID pages, lock bytes, Capability Container, NDEF
  /// data area, and any further manufacturer-specific pages (e.g.
  /// configuration/counter pages) the tag exposes.
  Future<Uint8List> readMemoryDump() {
    return _readPagesFrom(0);
  }

  /// Attempts to read the tag's chip identification via the NXP
  /// `GET_VERSION` (0x60) command.
  ///
  /// This is not part of the standard NFC Forum Type 2 Tag operation set —
  /// it requires the reader to support a "direct transmit" style escape
  /// command. Returns `null` if the reader doesn't support this, the
  /// command fails, or the response isn't the expected 8 bytes, rather
  /// than throwing.
  Future<ChipVersion?> readChipVersion() async {
    try {
      final responseHex = await transceive('FF0000000160');
      final data = _stripAndCheckSw(responseHex);
      if (data == null || data.length != 8) {
        return null;
      }
      return ChipVersion.parse(data);
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List> _readPagesFrom(int startPage, {int? maxBytes}) async {
    final buffer = BytesBuilder();
    var page = startPage;
    while ((maxBytes == null || buffer.length < maxBytes) && page <= 0xFF) {
      final pageHex = page.toRadixString(16).padLeft(2, '0');
      String? chunkHex;
      try {
        chunkHex = await transceive('FFB000${pageHex}10');
      } catch (_) {
        break;
      }
      final chunk = _stripAndCheckSw(chunkHex);
      if (chunk == null) break;
      buffer.add(chunk);
      page += 4;
    }
    return buffer.toBytes();
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
