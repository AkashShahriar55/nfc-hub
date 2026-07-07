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

    test('extracts the value from an extended-length TLV (0xFF length)', () {
      final value = Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05]);
      final tlv = Uint8List.fromList([
        0x03, // NDEF Message TLV tag
        0xFF, // extended-length marker
        0x00, 0x05, // 2-byte big-endian length = 5
        ...value,
      ]);

      final result = parseTlvForNdefMessage(tlv);

      expect(result, isNotNull);
      expect(result, equals(value));
    });

    test('skips a NULL TLV and finds the following NDEF Message TLV', () {
      final message = Uint8List.fromList([0xAA, 0xBB, 0xCC]);
      final tlv = Uint8List.fromList([
        0x00, // NULL TLV (no length/value)
        0x03, message.length, // NDEF Message TLV tag + length
        ...message,
        0xFE, // Terminator TLV
      ]);

      final result = parseTlvForNdefMessage(tlv);

      expect(result, isNotNull);
      expect(result, equals(message));
    });

    test('returns null when input is truncated mid-TLV-length', () {
      // Tag byte present but the length byte is missing entirely.
      final tlv = Uint8List.fromList([0x03]);

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

    test('decodes a UTF-16 Text record without a BOM (defaults to big-endian)',
        () {
      final message = Uint8List.fromList([
        0xD1, 0x01, 0x07, 0x54, // flags(MB,ME,SR,TNF=1), typeLength=1, payloadLength=7, type 'T'
        0x82, 0x65, 0x6E, // status byte (UTF-16 bit set, lang len 2), 'en'
        0x00, 0x68, 0x00, 0x69, // UTF-16BE "hi" (U+0068, U+0069)
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(1));
      expect(records[0].asText, equals('hi'));
    });

    test('decodes a UTF-16 Text record with a big-endian BOM (BOM is skipped)',
        () {
      final message = Uint8List.fromList([
        0xD1, 0x01, 0x09, 0x54, // flags(MB,ME,SR,TNF=1), typeLength=1, payloadLength=9, type 'T'
        0x82, 0x65, 0x6E, // status byte (UTF-16 bit set, lang len 2), 'en'
        0xFE, 0xFF, // big-endian BOM
        0x00, 0x68, 0x00, 0x69, // UTF-16BE "hi" (U+0068, U+0069)
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(1));
      expect(records[0].asText, equals('hi'));
    });

    test('decodes a record with a non-short (4-byte) payload length', () {
      final message = Uint8List.fromList([
        0xC1, // flags(MB,ME,TNF=1), SR clear
        0x01, // typeLength=1
        0x00, 0x00, 0x00, 0x05, // 4-byte big-endian payloadLength=5
        0x54, // type 'T'
        0x01, 0x02, 0x03, 0x04, 0x05, // payload
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(1));
      expect(records[0].typeString, equals('T'));
      expect(
        records[0].payload,
        equals(Uint8List.fromList([0x01, 0x02, 0x03, 0x04, 0x05])),
      );
    });

    test('decodes a record with an IL (id length) field present', () {
      final message = Uint8List.fromList([
        0xD9, // flags(MB,ME,SR,IL,TNF=1)
        0x01, // typeLength=1
        0x03, // payloadLength=3
        0x02, // idLength=2
        0x54, // type 'T'
        0x69, 0x64, // id = "id"
        0x61, 0x62, 0x63, // payload = "abc"
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(1));
      expect(records[0].id, equals(Uint8List.fromList([0x69, 0x64])));
      expect(
        records[0].payload,
        equals(Uint8List.fromList([0x61, 0x62, 0x63])),
      );
    });

    test('decodes multiple records, stopping at the ME-flagged record', () {
      final message = Uint8List.fromList([
        // Record 1: MB set, ME clear, SR, TNF=1.
        0x91, 0x01, 0x01, 0x54, 0x41, // type 'T', payload 'A'
        // Record 2: MB clear, ME set, SR, TNF=1.
        0x51, 0x01, 0x01, 0x54, 0x42, // type 'T', payload 'B'
      ]);

      final records = parseNdefRecords(message);

      expect(records, hasLength(2));
      expect(records[0].payload, equals(Uint8List.fromList([0x41])));
      expect(records[1].payload, equals(Uint8List.fromList([0x42])));
    });

    test('returns a partial (empty) list when input is truncated mid-header',
        () {
      // Only the flags byte is present; typeLength and everything after it
      // is missing.
      final message = Uint8List.fromList([0xD1]);

      expect(parseNdefRecords(message), isEmpty);
    });
  });
}
