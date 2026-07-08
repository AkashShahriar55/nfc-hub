import 'package:ccid/ccid.dart';
import 'package:ccid/ccid_platform_interface.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeCcidPlatform extends CcidPlatform {
  final Map<String, String> responses;
  final List<String> requestedCapdus = [];

  _FakeCcidPlatform(this.responses);

  @override
  Future<String?> transceive(String reader, String capdu) async {
    requestedCapdus.add(capdu);
    final response = responses[capdu];
    if (response == null) {
      throw Exception('No fake response configured for capdu: $capdu');
    }
    return response;
  }

  @override
  Future<List<String>> listReaders() async => ['fake-reader'];

  @override
  Future<CcidCard> connect(String reader) async => CcidCard(reader);

  @override
  Future<void> disconnect(String reader) async {}
}

void main() {
  tearDown(() {
    CcidPlatform.instance = null;
  });

  test(
      'readNdef() sends a well-formed READ BINARY APDU (P2 = page number) '
      'for each data page and decodes the resulting NDEF message', () async {
    // CC: magic 0xE1, version 0x10, size 0x06 (48-byte data area), access 0x00.
    final ccData = [0xE1, 0x10, 0x06, 0x00];
    final ccResponse = '${hex.encode(ccData)}9000';

    // NDEF Text record 'hello', wrapped in a Message TLV + Terminator.
    final record = [
      0xD1, 0x01, 0x08, 0x54, // flags, typeLength, payloadLength, type 'T'
      0x02, 0x65, 0x6E, // status byte (lang len 2, UTF-8), 'en'
      0x68, 0x65, 0x6C, 0x6C, 0x6F, // 'hello'
    ];
    final page4 = [0x03, record.length, ...record, 0xFE, 0x00, 0x00];
    final page4Response = '${hex.encode(page4)}9000';

    final fake = _FakeCcidPlatform({
      'FFB0000304': ccResponse,
      'FFB0000410': page4Response,
    });
    CcidPlatform.instance = fake;

    final card = CcidCard('fake-reader');
    final records = await Type2Tag(card).readNdef();

    expect(records, hasLength(1));
    expect(records[0].asText, equals('hello'));
    expect(
      fake.requestedCapdus,
      contains('FFB0000410'),
      reason: 'expected a 5-byte READ BINARY APDU (FF B0 00 <page> <Le>) '
          'with the page number in P2, matching the same pattern the '
          'Capability Container read already uses',
    );
  });
}
