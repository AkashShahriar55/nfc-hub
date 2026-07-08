import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'ccid_tag_driver.dart';
import 'src/apdu.dart';

/// The parsed result of a FeliCa "Read Without Encryption" command.
class FelicaReadResult {
  final int statusFlag1;
  final int statusFlag2;
  final List<Uint8List> blocks;

  const FelicaReadResult({
    required this.statusFlag1,
    required this.statusFlag2,
    required this.blocks,
  });

  /// Whether the card reported success (both status flags zero).
  bool get isSuccess => statusFlag1 == 0x00 && statusFlag2 == 0x00;
}

/// Driver for a FeliCa (NFC-F / JIS X 6319-4) tag connected through a
/// contactless PC/SC reader, sent via the reader's direct-transmit/escape
/// pseudo-APDU (`FF 00 00 00 <Lc> <data>`) since FeliCa's command framing
/// isn't ISO 7816 APDUs.
///
/// This escape command framing is a first attempt based on the same
/// convention `Type2Tag.readChipVersion()` uses; it may need adjusting for
/// readers that expect a different "direct transmit" byte layout.
class FelicaTag extends TagDriver {
  FelicaTag(super.card);

  Uint8List? _idm;

  /// The card's 8-byte IDm, polled once (via a FeliCa Polling / SENSF_REQ
  /// command) and cached for the lifetime of this driver.
  Future<Uint8List> get idm async {
    final cached = _idm;
    if (cached != null) return cached;
    final polled = await _poll();
    _idm = polled;
    return polled;
  }

  /// Sends a FeliCa "Read Without Encryption" (command code 0x06) for
  /// [serviceCode], reading each block number in [blockList].
  ///
  /// Each block list entry must be 0-255 (2-byte block list element form).
  Future<FelicaReadResult> readWithoutEncryption(
    int serviceCode,
    List<int> blockList,
  ) async {
    final cardIdm = await idm;
    final frame = BytesBuilder();
    frame.addByte(0x06); // command code
    frame.add(cardIdm);
    frame.addByte(0x01); // number of service codes
    frame.addByte(serviceCode & 0xFF); // service code, little-endian
    frame.addByte((serviceCode >> 8) & 0xFF);
    frame.addByte(blockList.length);
    for (final block in blockList) {
      frame.addByte(0x80); // 2-byte block list element
      frame.addByte(block & 0xFF);
    }
    final response = await _transceiveFelicaFrame(frame.toBytes());

    // Response frame: length(1) | responseCode(1)=0x07 | idm(8) | SF1(1) |
    // SF2(1) | numBlocks(1) | blocks(16 bytes each).
    if (response.length < 12) {
      throw Exception(
          'FeliCa read response too short (${response.length} bytes)');
    }
    final statusFlag1 = response[10];
    final statusFlag2 = response[11];
    final blocks = <Uint8List>[];
    if (statusFlag1 == 0x00 && statusFlag2 == 0x00) {
      final numBlocks = response.length > 12 ? response[12] : 0;
      var offset = 13;
      for (var i = 0; i < numBlocks && offset + 16 <= response.length; i++) {
        blocks.add(Uint8List.sublistView(response, offset, offset + 16));
        offset += 16;
      }
    }
    return FelicaReadResult(
      statusFlag1: statusFlag1,
      statusFlag2: statusFlag2,
      blocks: blocks,
    );
  }

  Future<Uint8List> _poll() async {
    final command = Uint8List.fromList([
      0x00, // Polling command code
      0xFF, 0xFF, // System Code: wildcard
      0x00, // Request Code: none
      0x00, // Time Slot
    ]);
    final response = await _transceiveFelicaFrame(command);
    // Response frame: length(1) | responseCode(1)=0x01 | idm(8) | pmm(8) | ...
    if (response.length < 10) {
      throw Exception(
          'FeliCa polling response too short (${response.length} bytes)');
    }
    return Uint8List.sublistView(response, 2, 10);
  }

  /// Wraps [felicaCommand] in the reader's length-prefix byte and sends it
  /// via the direct-transmit escape pseudo-APDU, returning the raw FeliCa
  /// response frame (length byte included).
  Future<Uint8List> _transceiveFelicaFrame(Uint8List felicaCommand) async {
    final framed =
        Uint8List.fromList([felicaCommand.length + 1, ...felicaCommand]);
    final lcHex = framed.length.toRadixString(16).padLeft(2, '0');
    final dataHex = hex.encode(framed);
    final capdu = 'FF000000$lcHex$dataHex'.toUpperCase();
    return transceiveChecked(card, capdu);
  }
}
