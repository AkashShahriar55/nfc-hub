import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nfc_hub/nfc_hub.dart';

import 'connection_status_bar.dart';

/// The harness home screen: the connection status bar on top, and below it
/// a live list of tags auto-detected via `tagStream()` — tap a phone or
/// seat a card on a reader and the tag appears with its [TagInfo] filled
/// in, no button press required.
///
/// [tags] and [connectionState] are injectable so tests can drive detection
/// with fake streams without touching the platform channel. When not
/// supplied, they default to a lazily-created [NfcHub]'s `tagStream()`/
/// `connectionState()` — a real [NfcHub] is never constructed when both are
/// injected.
class HarnessHome extends StatefulWidget {
  const HarnessHome({super.key, this.tags, this.connectionState});

  final Stream<TagDriver>? tags;
  final Stream<CcidConnectionState>? connectionState;

  @override
  State<HarnessHome> createState() => _HarnessHomeState();
}

/// One row's worth of summary for a detected tag: the driver itself, plus
/// either its [TagInfo] (on a successful `readTagInfo()`) or the error
/// string (on a failed one) -- a failed info read still lists the tag
/// rather than dropping it silently.
class _TagEntry {
  final TagDriver driver;
  final TagInfo? info;
  final String? error;

  const _TagEntry({required this.driver, this.info, this.error});
}

class _HarnessHomeState extends State<HarnessHome> {
  StreamSubscription<TagDriver>? _subscription;
  final List<_TagEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    final tags = widget.tags ?? NfcHub().tagStream();
    _subscription = tags.listen(_onTag);
  }

  Future<void> _onTag(TagDriver driver) async {
    TagInfo? info;
    String? error;
    try {
      info = await driver.readTagInfo();
    } catch (e) {
      error = '$e';
    }
    if (!mounted) return;
    setState(() {
      _entries.insert(0, _TagEntry(driver: driver, info: info, error: error));
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _openDetail(TagDriver driver) {
    Navigator.of(context).push(
      MaterialPageRoute(
        // TODO(task4): replace with TagDetailPage(driver: driver)
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text('${driver.runtimeType}')),
          body: const Center(child: Text('Detail page — Task 4')),
        ),
      ),
    );
  }

  IconData _iconFor(TagDriver driver) {
    final name = driver.runtimeType.toString();
    if (name.contains('Felica')) return Icons.wifi;
    if (name.contains('MifareClassic')) return Icons.credit_card;
    if (name.contains('Type2')) return Icons.nfc;
    if (name.contains('IsoDep')) return Icons.contactless;
    if (name.contains('TypeB')) return Icons.badge;
    return Icons.credit_card;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(8.0),
          child: ConnectionStatusBar(states: widget.connectionState),
        ),
        Expanded(
          child: _entries.isEmpty
              ? Center(
                  child: Text(
                    'Tap a tag or place a card on a reader…',
                    style: Theme.of(context).textTheme.bodyMedium,
                    textAlign: TextAlign.center,
                  ),
                )
              : ListView.builder(
                  itemCount: _entries.length,
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    final info = entry.info;
                    final title = info?.technology ??
                        entry.driver.runtimeType.toString();
                    final uidHex =
                        info != null ? _hex(info.uid) : '(unavailable)';
                    final subtitle = entry.error == null
                        ? 'UID: $uidHex'
                        : 'UID: $uidHex — ${entry.error}';
                    return ListTile(
                      leading: Icon(_iconFor(entry.driver)),
                      title: Text(title),
                      subtitle: Text(subtitle),
                      onTap: () => _openDetail(entry.driver),
                    );
                  },
                ),
        ),
      ],
    );
  }

  String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
