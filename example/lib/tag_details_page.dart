import 'package:ccid/ccid.dart';
import 'package:flutter/material.dart';

class TagDetailsPage extends StatefulWidget {
  final CcidCard card;

  const TagDetailsPage({super.key, required this.card});

  @override
  State<TagDetailsPage> createState() => _TagDetailsPageState();
}

class _TagDetailsPageState extends State<TagDetailsPage> {
  String? _uidResult;
  String? _capabilityContainerResult;
  String? _ndefResult;
  String? _memoryDumpResult;
  String? _chipVersionResult;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  Future<void> _loadAll() async {
    await _loadUid();
    await _loadCapabilityContainer();
    await _loadNdef();
    await _loadMemoryDump();
    await _loadChipVersion();
  }

  Future<void> _loadUid() async {
    try {
      final uid = await widget.card.readUid();
      if (!mounted) return;
      setState(() => _uidResult = _hex(uid));
    } catch (e) {
      if (!mounted) return;
      setState(() => _uidResult = 'Failed: $e');
    }
  }

  Future<void> _loadCapabilityContainer() async {
    try {
      final cc = await widget.card.readCapabilityContainer();
      if (!mounted) return;
      setState(() => _capabilityContainerResult = cc.toString());
    } catch (e) {
      if (!mounted) return;
      setState(() => _capabilityContainerResult = 'Failed: $e');
    }
  }

  Future<void> _loadNdef() async {
    try {
      final records = await widget.card.readNdef();
      if (!mounted) return;
      setState(() {
        _ndefResult =
            records.isEmpty ? '(empty message)' : records.join('\n');
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _ndefResult = 'Failed: $e');
    }
  }

  Future<void> _loadMemoryDump() async {
    try {
      final dump = await widget.card.readMemoryDump();
      if (!mounted) return;
      setState(() => _memoryDumpResult = _formatPages(dump));
    } catch (e) {
      if (!mounted) return;
      setState(() => _memoryDumpResult = 'Failed: $e');
    }
  }

  Future<void> _loadChipVersion() async {
    try {
      final version = await widget.card.readChipVersion();
      if (!mounted) return;
      setState(() {
        _chipVersionResult = version == null
            ? 'Unavailable (reader/tag does not support GET_VERSION)'
            : version.toString();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _chipVersionResult = 'Failed: $e');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tag Details')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section('UID', _uidResult),
            _section('Capability Container', _capabilityContainerResult),
            _section('NDEF', _ndefResult),
            _section('Memory Dump', _memoryDumpResult),
            _section('Chip Version', _chipVersionResult),
          ],
        ),
      ),
    );
  }
}
