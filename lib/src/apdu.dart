import 'dart:typed_data';

import 'package:convert/convert.dart';

import 'nfc_hub_base.dart';

/// Strips the trailing 2-byte status word from [responseHex] and returns the
/// data bytes, or null if the response is missing, too short, or the status
/// word isn't the success code `9000`.
Uint8List? stripAndCheckSw(String? responseHex) {
  if (responseHex == null || responseHex.length < 4) return null;
  final sw = responseHex.substring(responseHex.length - 4);
  if (sw.toUpperCase() != '9000') return null;
  final dataHex = responseHex.substring(0, responseHex.length - 4);
  return Uint8List.fromList(hex.decode(dataHex));
}

/// Sends [capdu] through [card] and returns the response data, throwing if
/// the response is missing or its status word isn't `9000`.
Future<Uint8List> transceiveChecked(ReaderCard card, String capdu) async {
  final data = stripAndCheckSw(await card.transceive(capdu));
  if (data == null) {
    throw Exception('Failed to read tag (bad response to $capdu)');
  }
  return data;
}

/// Wraps [payload] in the reader's direct-transmit escape pseudo-APDU
/// (`FF 00 00 00 <Lc> <data>`) and returns the checked response data
/// (status-word-stripped, requiring a `9000` success).
Future<Uint8List> transceiveEscape(ReaderCard card, Uint8List payload) {
  final lcHex = payload.length.toRadixString(16).padLeft(2, '0');
  final dataHex = hex.encode(payload);
  final capdu = 'FF000000$lcHex$dataHex'.toUpperCase();
  return transceiveChecked(card, capdu);
}
