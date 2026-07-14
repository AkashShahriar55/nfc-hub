import 'dart:typed_data';

import 'package:nfc_hub/nfc_hub.dart';
import 'package:nfc_hub/src/transport/transport.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeType2Transport implements Type2Transport {
  _FakeType2Transport({this.uid, this.cc});

  final Uint8List? uid;
  final Uint8List? cc;

  @override
  Future<Uint8List> readUid() async =>
      uid ?? (throw Exception('no uid scripted'));

  @override
  Future<Uint8List> readCapabilityContainer() async =>
      cc ?? (throw Exception('no CC scripted'));

  @override
  Future<Uint8List> readPages(int startPage) async =>
      throw Exception('page $startPage not scripted');

  @override
  Future<Uint8List?> getVersion() async => null;
}

void main() {
  test('readTagInfo() returns UID and the parsed Capability Container',
      () async {
    final tag = Type2Tag(_FakeType2Transport(
      uid: Uint8List.fromList([0x04, 0x01, 0x02, 0x03]),
      cc: Uint8List.fromList([0xE1, 0x10, 0x06, 0x00]),
    ));

    final info = await tag.readTagInfo();

    expect(info.uid, equals([0x04, 0x01, 0x02, 0x03]));
    expect(info.capabilityContainer, isNotNull);
    expect(info.capabilityContainer!.isNdefFormatted, isTrue);
  });
}
