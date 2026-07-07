import 'dart:typed_data';

import 'package:ccid/ccid_ndef.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseTlvForNdefMessage', () {
    test('extracts the NDEF Message TLV value and stops at the terminator', () {
      final message = Uint8List.fromList([
        0xD1, 0x01, 0x08, 0x54, // flags, typeLength, payloadLength, type 'T'
        0x02, 0x65, 0x6E, // status byte (lang len 2, UTF-8), 'en'
        0x68, 0x65, 0x6C, 0x6C, 0x6F, // 'hello'
      ]);
      final tlv = Uint8List.fromList([
        0x03, message.length, // NDEF Message TLV tag + length
        ...message,
        0xFE, // Terminator TLV
      ]);

      final result = parseTlvForNdefMessage(tlv);

      expect(result, isNotNull);
      expect(result, equals(message));
    });

    test('returns null when there is no NDEF Message TLV', () {
      final tlv = Uint8List.fromList([0x00, 0x00, 0xFE]);

      expect(parseTlvForNdefMessage(tlv), isNull);
    });
  });

  group('parseNdefRecords', () {
    test('decodes a single well-known Text record', () {
      final message = Uint8List.fromList([
        0xD1, 0x01, 0x08, 0x54, // flags(MB,ME,SR,TNF=1), typeLength=1, payloadLength=8, type 'T'
        0x02, 0x65, 0x6E, // status byte (lang len 2, UTF-8), 'en'
        0x68, 0x65, 0x6C, 0x6C, 0x6F, // 'hello'
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(1));
      expect(records[0].tnf, equals(1));
      expect(records[0].typeString, equals('T'));
      expect(records[0].asText, equals('hello'));
      expect(records[0].asUri, isNull);
    });

    test('decodes a single well-known URI record', () {
      final message = Uint8List.fromList([
        0xD1, 0x01, 0x0C, 0x55, // flags(MB,ME,SR,TNF=1), typeLength=1, payloadLength=12, type 'U'
        0x01, // URI prefix code 0x01 -> 'http://www.'
        0x65, 0x78, 0x61, 0x6D, 0x70, 0x6C, 0x65, 0x2E, 0x63, 0x6F, 0x6D, // 'example.com'
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(1));
      expect(records[0].typeString, equals('U'));
      expect(records[0].asUri, equals('http://www.example.com'));
      expect(records[0].asText, isNull);
    });
  });
}
