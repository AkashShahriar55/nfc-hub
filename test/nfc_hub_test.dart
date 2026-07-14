import 'dart:typed_data';

import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeType2Transport implements Type2Transport {
  _FakeType2Transport({this.cc, this.pages = const {}});

  final Uint8List? cc;
  final Map<int, Uint8List> pages;

  @override
  Future<Uint8List> readUid() async => throw Exception('no uid scripted');

  @override
  Future<Uint8List> readCapabilityContainer() async =>
      cc ?? (throw Exception('no CC scripted'));

  @override
  Future<Uint8List> readPages(int startPage) async =>
      pages[startPage] ?? (throw Exception('page $startPage not scripted'));

  @override
  Future<Uint8List?> getVersion() async => null;
}

void main() {
  test(
      'readNdef() sends a well-formed READ BINARY APDU (P2 = page number) '
      'for each data page and decodes the resulting NDEF message', () async {
    // CC: magic 0xE1, version 0x10, size 0x06 (48-byte data area), access 0x00.
    final ccData = Uint8List.fromList([0xE1, 0x10, 0x06, 0x00]);

    // NDEF Text record 'hello', wrapped in a Message TLV + Terminator.
    final record = [
      0xD1, 0x01, 0x08, 0x54, // flags, typeLength, payloadLength, type 'T'
      0x02, 0x65, 0x6E, // status byte (lang len 2, UTF-8), 'en'
      0x68, 0x65, 0x6C, 0x6C, 0x6F, // 'hello'
    ];
    final page4 =
        Uint8List.fromList([0x03, record.length, ...record, 0xFE, 0x00, 0x00]);

    final transport = _FakeType2Transport(cc: ccData, pages: {4: page4});
    final records = await Type2Tag(transport).readNdef();

    expect(records, hasLength(1));
    expect(records[0].asText, equals('hello'));
  });
}
