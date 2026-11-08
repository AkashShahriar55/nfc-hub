import 'dart:typed_data';

import 'package:nfc_hub_example/mrt_stations.dart';
import 'package:nfc_hub_example/mrt_transaction.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _blockFromHex(String hex16Bytes) =>
    Uint8List.fromList(hex.decode(hex16Bytes));

void main() {
  group('decodeTimestamp', () {
    test('decodes a real card-recorded timestamp (hour/day/month/year)', () {
      // From a real Dhaka Metro transaction block: bytes 4-6 = 34 8A 90.
      final value = (0x34 << 16) | (0x8A << 8) | 0x90;

      final decoded = decodeTimestamp(value);

      final currentYear = DateTime.now().year;
      final expectedYear = (currentYear - (currentYear % 100)) + 26;
      expect(decoded.year, equals(expectedYear));
      expect(decoded.month, equals(4));
      expect(decoded.day, equals(10));
      expect(decoded.hour, equals(18));
    });

    test('falls back to month/day 1 for out-of-range values', () {
      // month field = 0 (invalid, must be 1-12), day field = 0 (invalid).
      const value = 0;

      final decoded = decodeTimestamp(value);

      expect(decoded.month, equals(1));
      expect(decoded.day, equals(1));
    });
  });

  group('stationName', () {
    test('resolves a known Dhaka Metro station code', () {
      expect(stationName(10), equals('Motijheel'));
      expect(stationName(55), equals('Shewrapara'));
    });

    test('resolves a known Hatirjheel Bus station code', () {
      expect(stationName(13), equals('Mohanagar (HJ)'));
    });

    test('falls back to "Unknown (code)" for an unrecognized code', () {
      expect(stationName(255), equals('Unknown (255)'));
    });
  });

  group('Transaction.typeLabel', () {
    Transaction transactionWithHeader(String fixedHeader) => Transaction(
          fixedHeader: fixedHeader,
          timestamp: DateTime(2026),
          transactionType: '',
          fromStation: '',
          toStation: '',
          balance: 0,
          trailing: '',
        );

    test('labels the Dhaka Metro header', () {
      expect(transactionWithHeader('08 52 10 00').typeLabel,
          equals('Dhaka Metro'));
    });

    test('labels both Balance Update headers', () {
      expect(transactionWithHeader('1D 60 02 01').typeLabel,
          equals('Balance Update'));
      expect(transactionWithHeader('42 60 02 00').typeLabel,
          equals('Balance Update'));
    });

    test('labels an unrecognized header as Unknown', () {
      expect(transactionWithHeader('FF FF FF FF').typeLabel, equals('Unknown'));
    });
  });

  group('parseTransactionBlocks', () {
    test('parses a real Dhaka Metro transaction block end to end', () {
      final block = _blockFromHex('08521000348a90010a01379800000087');

      final transactions = parseTransactionBlocks([block]);

      expect(transactions, hasLength(1));
      final t = transactions[0];
      expect(t.fixedHeader, equals('08 52 10 00'));
      expect(t.typeLabel, equals('Dhaka Metro'));
      expect(t.transactionType, equals('90 01'));
      expect(t.fromStation, equals('Motijheel'));
      expect(t.toStation, equals('Shewrapara'));
      expect(t.balance, equals(152));
      expect(t.trailing, equals('00 87'));
    });

    test(
        'drops blocks that decode to a pre-2020 timestamp (unused/padding '
        'blocks)', () {
      final blankBlock = Uint8List(16); // all zeros

      final transactions = parseTransactionBlocks([blankBlock]);

      expect(transactions, isEmpty);
    });

    test('ignores blocks that are not exactly 16 bytes', () {
      final tooShort = Uint8List(4);

      final transactions = parseTransactionBlocks([tooShort]);

      expect(transactions, isEmpty);
    });
  });
}
