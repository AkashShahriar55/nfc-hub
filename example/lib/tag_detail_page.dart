import 'package:flutter/material.dart';
import 'package:nfc_hub/nfc_hub.dart';

import 'mrt_transaction.dart';
import 'widgets/result_tile.dart';

/// The tag detail page: the driver's [TagInfo] is auto-loaded on open, then
/// a set of family-specific buttons each trigger one read on demand (the
/// heavy reads -- memory dump, DESFire GetVersion -- are multi-second, so
/// they're opt-in rather than fired automatically). Every read renders
/// through [ResultTile] so a failure is as visible and copyable as a
/// success.
class TagDetailPage extends StatefulWidget {
  final TagDriver driver;

  const TagDetailPage({super.key, required this.driver});

  @override
  State<TagDetailPage> createState() => _TagDetailPageState();
}

/// One row's read state: loading, then either [value] or [error] -- never
/// both, mirroring [ResultTile]'s own tri-state.
class _ReadState {
  final bool loading;
  final String? value;
  final Object? error;

  const _ReadState.loading()
      : loading = true,
        value = null,
        error = null;
  const _ReadState.value(this.value)
      : loading = false,
        error = null;
  const _ReadState.error(this.error)
      : loading = false,
        value = null;
}

class _TagDetailPageState extends State<TagDetailPage> {
  final Map<String, _ReadState> _results = {};

  @override
  void initState() {
    super.initState();
    _run('Tag Info', () => _loadTagInfo(widget.driver));
  }

  /// Runs [body], recording its outcome under [title] as loading, then
  /// value or error. Every `setState` is guarded by [mounted] -- reads are
  /// multi-second and the user can navigate away mid-read.
  Future<void> _run(String title, Future<String> Function() body) async {
    setState(() => _results[title] = const _ReadState.loading());
    try {
      final value = await body();
      if (!mounted) return;
      setState(() => _results[title] = _ReadState.value(value));
    } catch (e) {
      if (!mounted) return;
      setState(() => _results[title] = _ReadState.error(e));
    }
  }

  Future<String> _loadTagInfo(TagDriver driver) async {
    final TagInfo info = await driver.readTagInfo();
    final lines = [
      'Technology: ${info.technology}',
      'UID: ${_hex(info.uid)}',
      'ATR: ${info.atr == null ? '(none)' : _hex(info.atr!)}',
    ];
    if (info is FelicaInfo) {
      if (info.modelName != null) {
        lines.add(
            'Chip model: ${info.modelName} (unofficial, community-sourced)');
      }
      if (info.systemCodes.isNotEmpty) {
        final codeDescriptions = info.systemCodes.map((c) {
          final hexCode =
              '0x${c.toRadixString(16).padLeft(4, '0').toUpperCase()}';
          final label = felicaSystemCodeLabel(c);
          return label == null ? hexCode : '$hexCode ($label, unofficial)';
        }).join(', ');
        lines.add('System codes: $codeDescriptions');
      }
    }
    if (info is IsoDepInfo && info.desfireVersion != null) {
      lines.add('DESFire UID: ${_hex(info.desfireVersion!.uid)}');
    }
    return lines.join('\n');
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  String _formatPages(List<int> bytes) {
    final lines = <String>[];
    for (var i = 0; i < bytes.length; i += 4) {
      final page = i ~/ 4;
      final end = i + 4 > bytes.length ? bytes.length : i + 4;
      final chunk = bytes.sublist(i, end);
      lines.add('Page $page: ${_hex(chunk)}');
    }
    return lines.isEmpty ? '(empty)' : lines.join('\n');
  }

  String _formatTransaction(Transaction t) {
    final ts = t.timestamp;
    final date = '${ts.year}-${_pad(ts.month)}-${_pad(ts.day)} '
        '${_pad(ts.hour)}:00';
    return '$date · ${t.typeLabel} · ${t.fromStation} → ${t.toStation} · '
        'Balance: ${t.balance}';
  }

  String _pad(int n) => n.toString().padLeft(2, '0');

  /// The action buttons for [driver]'s concrete family. Each button starts
  /// exactly one read; nothing here runs until pressed.
  List<Widget> _actionsFor(TagDriver driver) {
    if (driver is Type2Tag) {
      return [
        _actionButton('UID', () async => _hex(await driver.readUid())),
        _actionButton(
            'Capability Container',
            () async =>
                (await driver.readCapabilityContainer()).toString()),
        _actionButton('NDEF', () async {
          final records = await driver.readNdef();
          return records.isEmpty ? '(empty message)' : records.join('\n');
        }),
        _actionButton(
            'Memory Dump',
            () async => _formatPages(await driver.readMemoryDump())),
        _actionButton('Chip Version', () async {
          final version = await driver.readChipVersion();
          return version == null
              ? 'Unavailable (reader/tag does not support GET_VERSION)'
              : version.toString();
        }),
      ];
    } else if (driver is MifareClassicTag) {
      return [
        _actionButton('Sector 0', () async {
          await driver.authenticateWithDefaultKeys(0);
          final blocks = await driver.readSector(0);
          return blocks.map(_hex).join('\n');
        }, buttonLabel: 'Read Sector 0'),
      ];
    } else if (driver is FelicaTag) {
      return [
        _actionButton('IDm', () async => _hex(await driver.idm)),
        _actionButton('Transactions', () async {
          final result =
              await driver.readWithoutEncryption(0x220F, [0, 1, 2, 3]);
          if (!result.isSuccess) {
            // A non-success status is still a valid card response (e.g. the
            // service isn't present on this card), not a read failure --
            // it's shown as the tile's value, not its error.
            return 'Card reported status '
                '${result.statusFlag1.toRadixString(16)}/'
                '${result.statusFlag2.toRadixString(16)}';
          }
          final transactions = parseTransactionBlocks(result.blocks);
          if (transactions.isEmpty) {
            return '(no transactions in this block range)';
          }
          return transactions.map(_formatTransaction).join('\n');
        }),
      ];
    } else if (driver is IsoDepTag) {
      return [
        _actionButton(
            'SELECT (empty AID)',
            () async =>
                await driver.selectApplication('') ?? '(no response)'),
        _actionButton(
            'DESFire GetVersion',
            () async => (await driver.readDesfireVersion()).toString()),
      ];
    }
    // TypeBTag (and anything unrecognized): the auto-loaded Tag Info above
    // already covers PUPI/ATQB -- no extra reads.
    return [];
  }

  Widget _actionButton(String title, Future<String> Function() body,
      {String? buttonLabel}) {
    final state = _results[title];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ElevatedButton(
            onPressed:
                (state?.loading ?? false) ? null : () => _run(title, body),
            child: Text(buttonLabel ?? title),
          ),
          if (state != null)
            ResultTile(
              title: title,
              loading: state.loading,
              value: state.value,
              error: state.error,
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tagInfoState = _results['Tag Info'];
    return Scaffold(
      appBar: AppBar(title: Text('Tag Detail (${widget.driver.runtimeType})')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ResultTile(
              title: 'Tag Info',
              loading: tagInfoState?.loading ?? true,
              value: tagInfoState?.value,
              error: tagInfoState?.error,
            ),
            const Divider(height: 32),
            ..._actionsFor(widget.driver),
          ],
        ),
      ),
    );
  }
}
