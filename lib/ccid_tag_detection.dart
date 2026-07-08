import 'dart:typed_data';

import 'ccid.dart' show CcidCard;
import 'ccid_felica.dart';
import 'ccid_iso_dep.dart';
import 'ccid_mifare_classic.dart';
import 'ccid_tag_driver.dart';
import 'ccid_type2.dart';
import 'src/apdu.dart';

/// Identifies the tag family of the card connected through [card] and
/// returns the matching typed driver.
///
/// Uses [CcidCard.atr] where available (see PC/SC Part 3's historical-byte
/// markers for contactless storage cards). Where [CcidCard.atr] is null or
/// doesn't match a known pattern, falls back to ordered capability probing.
///
/// Throws [UnrecognizedTagException] if no known tag family matches.
Future<TagDriver> identifyTag(CcidCard card) async {
  final atr = card.atr;
  if (atr != null) {
    final fromAtr = _identifyFromAtr(card, atr);
    if (fromAtr != null) return fromAtr;
  }
  return _identifyByProbing(card);
}

TagDriver? _identifyFromAtr(CcidCard card, Uint8List atr) {
  if (atr.length < 5) return null;
  final historicalBytes = atr.sublist(4);

  if (_contains(historicalBytes, [0xA0, 0x00, 0x00, 0x03, 0x06])) {
    return MifareClassicTag(card);
  }
  if (historicalBytes.contains(0x11)) {
    return FelicaTag(card);
  }
  if (historicalBytes.contains(0x03)) {
    return Type2Tag(card);
  }
  // A real ATS-derived ATR (not a PC/SC Part 3 synchronous-card pseudo-ATR)
  // with none of the above markers: treat as a generic processor card.
  return IsoDepTag(card);
}

bool _contains(Uint8List haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

Future<String?> _tryTransceive(CcidCard card, String capdu) async {
  try {
    return await card.transceive(capdu);
  } catch (_) {
    return null;
  }
}

Future<TagDriver> _identifyByProbing(CcidCard card) async {
  final uidResponse = await _tryTransceive(card, 'FFCA000000');
  if (stripAndCheckSw(uidResponse) == null) {
    throw const UnrecognizedTagException('Card did not respond to Get UID');
  }

  final ccResponse = await _tryTransceive(card, 'FFB0000304');
  final ccData = stripAndCheckSw(ccResponse);
  if (ccData != null && ccData.length == 4 && ccData[0] == 0xE1) {
    return Type2Tag(card);
  }

  final selectResponse = await _tryTransceive(card, '00A4040000');
  if (selectResponse != null && selectResponse.length >= 4) {
    return IsoDepTag(card);
  }

  final mifare = MifareClassicTag(card);
  try {
    await mifare.authenticateWithDefaultKeys(0);
    return mifare;
  } catch (_) {
    // fall through
  }

  final felica = FelicaTag(card);
  try {
    await felica.idm;
    return felica;
  } catch (_) {
    // fall through
  }

  throw const UnrecognizedTagException(
    'Card did not match any known tag family (Type 2, MIFARE Classic, '
    'FeliCa, or ISO-DEP)',
  );
}
