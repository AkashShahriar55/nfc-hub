import 'package:convert/convert.dart';
import 'package:dart_pcsc/dart_pcsc.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../nfc_hub_base.dart';
import 'platform_interface.dart';

/// An implementation of [NfcHubPlatform] that uses dart_pcsc.
class PcscNfcHub extends NfcHubPlatform {
  final context = Context(Scope.user);
  final readerCardMap = <String, Card>{};
  var _initialized = false;

  Future<void> _init() async {
    if (!_initialized) {
      _initialized = true;
      await context.establish();
    }
  }

  @override
  Future<List<String>> listReaders() async {
    await _init();
    return await context.listReaders();
  }

  @override
  Future<ReaderCard> connect(String reader) async {
    final card = await context.connect(reader, ShareMode.shared, Protocol.any);
    readerCardMap[reader] = card;
    return ReaderCard(reader);
  }

  @override
  Future<String?> transceive(String reader, String capdu) async {
    final card = readerCardMap[reader];
    if (card == null) {
      throw Exception('Card not connected');
    }
    final apdu = Uint8List.fromList(hex.decode(capdu));
    final rapdu = await card.transmit(apdu);
    return hex.encode(rapdu);
  }

  @override
  Future<void> disconnect(String reader) async {
    final card = readerCardMap.remove(reader);
    if (card != null) {
      await card
          .disconnect(Disposition.resetCard)
          .then((_) => context.release());
    }
    return Future.value();
  }
}
