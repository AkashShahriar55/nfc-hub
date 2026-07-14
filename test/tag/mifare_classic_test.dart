import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:nfc_hub/nfc_hub.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordedAuthenticate {
  final int sector;
  final MifareKeyType keyType;
  final Uint8List key;

  const _RecordedAuthenticate(this.sector, this.keyType, this.key);
}

/// Fake [MifareClassicTransport]: records every [authenticate] call, rejects
/// keys in [rejectedKeyHex] (case-insensitive hex), returns scripted
/// [blocks], and exposes fixed [uid]/[atqa]/[sak].
class _FakeMifareClassicTransport implements MifareClassicTransport {
  _FakeMifareClassicTransport({
    Uint8List? uid,
    Uint8List? atqa,
    this.sak = 0x08,
    this.blocks = const {},
    this.rejectedKeyHex = const {},
  })  : uid = uid ?? Uint8List(0),
        atqa = atqa ?? Uint8List(0);

  @override
  final Uint8List uid;

  @override
  final Uint8List atqa;

  @override
  final int sak;

  final Map<int, Uint8List> blocks;
  final Set<String> rejectedKeyHex;

  final List<_RecordedAuthenticate> authenticateCalls = [];

  @override
  Future<void> authenticate(
      int sector, MifareKeyType keyType, Uint8List key) async {
    authenticateCalls.add(_RecordedAuthenticate(sector, keyType, key));
    if (rejectedKeyHex.contains(hex.encode(key).toUpperCase())) {
      throw const MifareAuthException('Failed to load key into reader');
    }
  }

  @override
  Future<Uint8List> readBlock(int block) async =>
      blocks[block] ?? (throw Exception('block $block not scripted'));
}

void main() {
  test('authenticateWithDefaultKeys() succeeds on the first working default key',
      () async {
    final transport = _FakeMifareClassicTransport();
    final tag = MifareClassicTag(transport);

    await tag.authenticateWithDefaultKeys(0);

    expect(transport.authenticateCalls, hasLength(1));
    expect(transport.authenticateCalls.single.sector, equals(0));
    expect(transport.authenticateCalls.single.keyType, equals(MifareKeyType.a));
    expect(hex.encode(transport.authenticateCalls.single.key).toUpperCase(),
        equals('FFFFFFFFFFFF'));
  });

  test('authenticateWithDefaultKeys() throws MifareAuthException when every '
      'default key fails', () async {
    final transport = _FakeMifareClassicTransport(rejectedKeyHex: {
      'FFFFFFFFFFFF',
      'A0A1A2A3A4A5',
      'D3F7D3F7D3F7',
      '000000000000',
    });
    final tag = MifareClassicTag(transport);

    expect(
      () => tag.authenticateWithDefaultKeys(0),
      throwsA(isA<MifareAuthException>()),
    );
  });

  test('readBlock() returns the decoded data for the requested block',
      () async {
    final transport = _FakeMifareClassicTransport(
      blocks: {1: Uint8List.fromList(List.filled(16, 0xAA))},
    );
    final tag = MifareClassicTag(transport);

    final data = await tag.readBlock(1);

    expect(data, equals(List.filled(16, 0xAA)));
  });

  test('readSector() reads all 4 blocks of the sector', () async {
    final transport = _FakeMifareClassicTransport(blocks: {
      4: Uint8List.fromList(List.filled(16, 0x00)),
      5: Uint8List.fromList(List.filled(16, 0x01)),
      6: Uint8List.fromList(List.filled(16, 0x02)),
      7: Uint8List.fromList(List.filled(16, 0x03)),
    });
    final tag = MifareClassicTag(transport);

    final blocks = await tag.readSector(1);

    expect(blocks, hasLength(4));
    expect(blocks[0], equals(List.filled(16, 0x00)));
    expect(blocks[3], equals(List.filled(16, 0x03)));
  });

  test('readTagInfo() resolves the family from the transport\'s SAK/UID',
      () async {
    final transport = _FakeMifareClassicTransport(
      uid: Uint8List.fromList([0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]),
      atqa: Uint8List.fromList([0x00, 0x44]),
      sak: 0x08,
    );
    final tag = MifareClassicTag(transport);

    final info = await tag.readTagInfo();

    expect(info.technology, equals('MIFARE Classic 1K'));
    expect(info.sak, equals(0x08));
    expect(info.uid, equals([0x04, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06]));
  });
}
