import 'package:nfc_hub/nfc_hub.dart';

import 'mrt_transaction.dart';

/// One labelled read captured at detection time: either a [value] or an
/// [error], never both. Rendered by the detail page.
class ReadResult {
  final String title;
  final String? value;
  final Object? error;

  const ReadResult.value(this.title, this.value) : error = null;
  const ReadResult.error(this.title, this.error) : value = null;
}

/// Everything read from a detected tag, captured EAGERLY while the tag is
/// still present (on the reader / in the phone's field) so the detail view
/// works even after the card has been removed. Built by [readEverything].
class TagReadout {
  final TagDriver driver;
  final TagInfo? info;
  final Object? infoError;
  final List<ReadResult> results;

  const TagReadout({
    required this.driver,
    this.info,
    this.infoError,
    this.results = const [],
  });

  String get technology => info?.technology ?? driver.runtimeType.toString();
}

/// Reads the [TagInfo] plus every family-specific datum for [driver] right
/// now, while the tag is present. Best-effort: each read's failure is
/// captured as a [ReadResult.error] rather than thrown, so a card removed
/// mid-read yields a partial read-out instead of nothing.
///
/// Pass the already-resolved [info]/[infoError] with [infoResolved] true to
/// avoid reading TagInfo twice (the home screen reads it first to show the
/// list row immediately).
Future<TagReadout> readEverything(
  TagDriver driver, {
  TagInfo? info,
  Object? infoError,
  bool infoResolved = false,
}) async {
  if (!infoResolved) {
    try {
      info = await driver.readTagInfo();
    } catch (e) {
      infoError = e;
    }
  }

  final results = <ReadResult>[];
  Future<void> run(String title, Future<String> Function() body) async {
    try {
      results.add(ReadResult.value(title, await body()));
    } catch (e) {
      results.add(ReadResult.error(title, e));
    }
  }

  if (driver is Type2Tag) {
    await run('UID', () async => _hex(await driver.readUid()));
    await run('Capability Container',
        () async => (await driver.readCapabilityContainer()).toString());
    await run('NDEF', () async {
      final records = await driver.readNdef();
      return records.isEmpty ? '(empty message)' : records.join('\n');
    });
    await run(
        'Memory Dump', () async => _formatPages(await driver.readMemoryDump()));
    await run('Chip Version', () async {
      final v = await driver.readChipVersion();
      return v?.toString() ??
          'Unavailable (reader/tag does not support GET_VERSION)';
    });
  } else if (driver is MifareClassicTag) {
    await run('Sector 0', () async {
      await driver.authenticateWithDefaultKeys(0);
      final blocks = await driver.readSector(0);
      return blocks.map(_hex).join('\n');
    });
  } else if (driver is FelicaTag) {
    await run('IDm', () async => _hex(await driver.idm));
    await run('Transactions', () async {
      final result = await driver.readWithoutEncryption(0x220F, [0, 1, 2, 3]);
      if (!result.isSuccess) {
        // A non-success status is still a valid card response (e.g. the
        // service isn't on this card), not a read failure -- shown as a value.
        return 'Card reported status '
            '${result.statusFlag1.toRadixString(16)}/'
            '${result.statusFlag2.toRadixString(16)}';
      }
      final transactions = parseTransactionBlocks(result.blocks);
      return transactions.isEmpty
          ? '(no transactions in this block range)'
          : transactions.map(_formatTransaction).join('\n');
    });
  } else if (driver is IsoDepTag) {
    await run('SELECT (empty AID)',
        () async => await driver.selectApplication('') ?? '(no response)');
    await run('DESFire GetVersion',
        () async => (await driver.readDesfireVersion()).toString());
  }
  // TypeBTag (and anything unrecognized): the TagInfo summary already covers
  // PUPI/ATQB -- no extra reads.

  return TagReadout(
    driver: driver,
    info: info,
    infoError: infoError,
    results: results,
  );
}

/// The formatted TagInfo summary lines (technology/UID/ATR plus family extras
/// like FeliCa chip model / system codes and the DESFire UID).
List<String> tagInfoLines(TagInfo info) {
  final lines = [
    'Technology: ${info.technology}',
    'UID: ${_hex(info.uid)}',
    'ATR: ${info.atr == null ? '(none)' : _hex(info.atr!)}',
  ];
  if (info is FelicaInfo) {
    if (info.modelName != null) {
      lines
          .add('Chip model: ${info.modelName} (unofficial, community-sourced)');
    }
    if (info.systemCodes.isNotEmpty) {
      final codes = info.systemCodes.map((c) {
        final hex = '0x${c.toRadixString(16).padLeft(4, '0').toUpperCase()}';
        final label = felicaSystemCodeLabel(c);
        return label == null ? hex : '$hex ($label, unofficial)';
      }).join(', ');
      lines.add('System codes: $codes');
    }
  }
  if (info is IsoDepInfo && info.desfireVersion != null) {
    lines.add('DESFire UID: ${_hex(info.desfireVersion!.uid)}');
  }
  return lines;
}

/// Lowercase hex of [bytes]. Public so the home-screen row can reuse it.
String hexOf(List<int> bytes) => _hex(bytes);

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

String _formatPages(List<int> bytes) {
  final lines = <String>[];
  for (var i = 0; i < bytes.length; i += 4) {
    final page = i ~/ 4;
    final end = i + 4 > bytes.length ? bytes.length : i + 4;
    lines.add('Page $page: ${_hex(bytes.sublist(i, end))}');
  }
  return lines.isEmpty ? '(empty)' : lines.join('\n');
}

String _formatTransaction(Transaction t) {
  final ts = t.timestamp;
  final date =
      '${ts.year}-${_pad(ts.month)}-${_pad(ts.day)} ${_pad(ts.hour)}:00';
  return '$date · ${t.typeLabel} · ${t.fromStation} → ${t.toStation} · '
      'Balance: ${t.balance}';
}

String _pad(int n) => n.toString().padLeft(2, '0');
