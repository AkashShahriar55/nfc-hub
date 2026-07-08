import 'package:ccid/ccid.dart';
import 'package:flutter/material.dart';

class TagDetailsPage extends StatefulWidget {
  final TagDriver driver;

  const TagDetailsPage({super.key, required this.driver});

  @override
  State<TagDetailsPage> createState() => _TagDetailsPageState();
}

class _TagDetailsPageState extends State<TagDetailsPage> {
  final Map<String, String> _results = {};

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    final driver = widget.driver;
    if (driver is Type2Tag) {
      await _load('UID', () async => _hex(await driver.readUid()));
      await _load('Capability Container',
          () async => (await driver.readCapabilityContainer()).toString());
      await _load('NDEF', () async {
        final records = await driver.readNdef();
        return records.isEmpty ? '(empty message)' : records.join('\n');
      });
      await _load('Memory Dump',
          () async => _formatPages(await driver.readMemoryDump()));
      await _load('Chip Version', () async {
        final version = await driver.readChipVersion();
        return version == null
            ? 'Unavailable (reader/tag does not support GET_VERSION)'
            : version.toString();
      });
    } else if (driver is MifareClassicTag) {
      await _load('Sector 0', () async {
        await driver.authenticateWithDefaultKeys(0);
        final blocks = await driver.readSector(0);
        return blocks.map(_hex).join('\n');
      });
    } else if (driver is FelicaTag) {
      await _load('IDm', () async => _hex(await driver.idm));
      await _load('Service 0x220F, blocks 0-3', () async {
        final result =
            await driver.readWithoutEncryption(0x220F, [0, 1, 2, 3]);
        if (!result.isSuccess) {
          return 'Card reported status '
              '${result.statusFlag1.toRadixString(16)}/'
              '${result.statusFlag2.toRadixString(16)}';
        }
        return result.blocks.map(_hex).join('\n');
      });
    } else if (driver is IsoDepTag) {
      await _load('SELECT (empty AID)',
          () async => await driver.selectApplication('') ?? '(no response)');
    }
  }

  Future<void> _load(String title, Future<String> Function() body) async {
    try {
      final value = await body();
      if (!mounted) return;
      setState(() => _results[title] = value);
    } catch (e) {
      if (!mounted) return;
      setState(() => _results[title] = 'Failed: $e');
    }
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

  Widget _section(String title, String? content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(content ?? 'Loading...'),
        ],
      ),
    );
  }

  List<String> _sectionTitlesFor(TagDriver driver) {
    if (driver is Type2Tag) {
      return [
        'UID',
        'Capability Container',
        'NDEF',
        'Memory Dump',
        'Chip Version',
      ];
    } else if (driver is MifareClassicTag) {
      return ['Sector 0'];
    } else if (driver is FelicaTag) {
      return ['IDm', 'Service 0x220F, blocks 0-3'];
    } else if (driver is IsoDepTag) {
      return ['SELECT (empty AID)'];
    }
    return [];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Tag Details (${widget.driver.runtimeType})')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final title in _sectionTitlesFor(widget.driver))
              _section(title, _results[title]),
          ],
        ),
      ),
    );
  }
}
