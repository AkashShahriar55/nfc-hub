import 'dart:typed_data';

import 'mrt_stations.dart';

/// A single decoded transaction from a Dhaka MRT/RapidPass FeliCa card's
/// service 0x220F transaction history. Ported from mrt-buddy's
/// Transaction/TransactionParser.
class Transaction {
  /// The block's first 4 bytes, as space-separated uppercase hex. Used to
  /// classify the transaction via [typeLabel].
  final String fixedHeader;

  final DateTime timestamp;

  /// The block's bytes 6-7, as space-separated uppercase hex — recorded
  /// as-is from the card, distinct from the human-readable [typeLabel].
  final String transactionType;

  final String fromStation;
  final String toStation;
  final int balance;

  /// The block's last 2 bytes, as space-separated uppercase hex.
  final String trailing;

  const Transaction({
    required this.fixedHeader,
    required this.timestamp,
    required this.transactionType,
    required this.fromStation,
    required this.toStation,
    required this.balance,
    required this.trailing,
  });

  /// A human-readable label derived from [fixedHeader], mirroring
  /// mrt-buddy's `TransactionType.fromHeader()`.
  String get typeLabel {
    switch (fixedHeader) {
      case '42 D6 30 00':
        return 'Hatirjheel Bus (end)';
      case '08 D2 20 00':
        return 'Hatirjheel Bus (start)';
      case '08 52 10 00':
        return 'Dhaka Metro';
      case '1D 60 02 01':
      case '42 60 02 00':
        return 'Balance Update';
      default:
        return 'Unknown';
    }
  }
}

/// Decodes a FeliCa transaction-history timestamp (the 3-byte, big-endian
/// bit-packed value at block offset 4) into a [DateTime].
///
/// The card only stores a 2-digit year, so the century is inferred from
/// the current date (matching mrt-buddy's `TimestampService`).
DateTime decodeTimestamp(int value) {
  final hour = (value >> 3) & 0x1F;
  final day = (value >> 8) & 0x1F;
  final month = (value >> 13) & 0x0F;
  final year = (value >> 17) & 0x1F;

  final currentYear = DateTime.now().year;
  final baseYear = currentYear - (currentYear % 100);
  final fullYear = baseYear + year;

  final validMonth = (month >= 1 && month <= 12) ? month : 1;
  final validDay = (day >= 1 && day <= 31) ? day : 1;

  return DateTime(fullYear, validMonth, validDay, hour % 24);
}

/// Parses each 16-byte block in [blocks] as a transaction-history record,
/// dropping any that decode to a pre-2020 timestamp — mrt-buddy's signal
/// for an unused/padding block rather than a real transaction.
List<Transaction> parseTransactionBlocks(List<Uint8List> blocks) {
  final transactions = <Transaction>[];
  for (final block in blocks) {
    if (block.length != 16) continue;
    final transaction = _parseTransactionBlock(block);
    if (transaction.timestamp.isAfter(DateTime(2020, 1, 1))) {
      transactions.add(transaction);
    }
  }
  return transactions;
}

Transaction _parseTransactionBlock(Uint8List block) {
  final fixedHeader = _hex(block.sublist(0, 4));

  // Big-endian 3-byte timestamp at offset 4; its last byte is also the
  // first byte of the transactionType field below (the card's field
  // layout overlaps by one byte, matching mrt-buddy's parser exactly).
  final timestampValue = (block[4] << 16) | (block[5] << 8) | block[6];
  final transactionType = _hex(block.sublist(6, 8));

  final fromStationCode = block[8];
  final toStationCode = block[10];

  // Little-endian 3-byte balance at offset 11.
  final balance = block[11] | (block[12] << 8) | (block[13] << 16);

  final trailing = _hex(block.sublist(14, 16));

  return Transaction(
    fixedHeader: fixedHeader,
    timestamp: decodeTimestamp(timestampValue),
    transactionType: transactionType,
    fromStation: stationName(fromStationCode),
    toStation: stationName(toStationCode),
    balance: balance,
    trailing: trailing,
  );
}

String _hex(List<int> bytes) => bytes
    .map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase())
    .join(' ');
