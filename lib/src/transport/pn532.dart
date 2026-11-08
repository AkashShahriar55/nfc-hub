import 'dart:typed_data';

import '../nfc_hub_base.dart' show ReaderCard;
import '../apdu.dart';

/// A Type A target found by [pollTypeA], with its real ATQA/SAK/UID read
/// directly from the card via the PN532's `InListPassiveTarget` command
/// (`D4 4A`), independent of the reader's ATR.
class PassiveTargetTypeA {
  final Uint8List atqa; // SENS_RES, 2 bytes
  final int sak; // SEL_RES, 1 byte
  final Uint8List uid;

  const PassiveTargetTypeA({
    required this.atqa,
    required this.sak,
    required this.uid,
  });
}

/// A Type B target found by [pollTypeB].
class PassiveTargetTypeB {
  final Uint8List
      atqb; // 12 bytes: '50' | PUPI(4) | AppData(4) | ProtocolInfo(3)
  final Uint8List attribResponse;

  const PassiveTargetTypeB({
    required this.atqb,
    required this.attribResponse,
  });
}

/// Polls for a Type A (ISO14443-A) target via the PN532's
/// `InListPassiveTarget` command, returning its real ATQA/SAK/UID.
/// Returns `null` if no tag answers.
Future<PassiveTargetTypeA?> pollTypeA(ReaderCard card) async {
  final response = await _inListPassiveTarget(card, brTy: 0x00);
  if (response == null) return null;
  final atqa = Uint8List.sublistView(response, 1, 3);
  final sak = response[3];
  final uidLength = response[4];
  final uid = Uint8List.sublistView(response, 5, 5 + uidLength);
  return PassiveTargetTypeA(atqa: atqa, sak: sak, uid: uid);
}

/// Polls for a Type B (ISO14443-B) target via the PN532's
/// `InListPassiveTarget` command. Returns `null` if no tag answers.
Future<PassiveTargetTypeB?> pollTypeB(ReaderCard card) async {
  final response = await _inListPassiveTarget(card, brTy: 0x03);
  if (response == null) return null;
  final atqb = Uint8List.sublistView(response, 1, 13);
  final attribLength = response[13];
  final attribResponse = Uint8List.sublistView(response, 14, 14 + attribLength);
  return PassiveTargetTypeB(atqb: atqb, attribResponse: attribResponse);
}

/// Sends `InListPassiveTarget` (max 1 target, the given [brTy] baud
/// rate/modulation) and returns the bytes after `NbTg`, i.e. starting at
/// `Tg`, or `null` if `NbTg` is 0 (no target found).
Future<Uint8List?> _inListPassiveTarget(ReaderCard card,
    {required int brTy}) async {
  final payload = Uint8List.fromList([0xD4, 0x4A, 0x01, brTy]);
  final response = await transceiveEscape(card, payload);
  if (response.length < 3 || response[0] != 0xD5 || response[1] != 0x4B) {
    throw Exception(
        'Unexpected InListPassiveTarget response header: $response');
  }
  final numTargets = response[2];
  if (numTargets == 0) return null;
  return Uint8List.sublistView(response, 3);
}
