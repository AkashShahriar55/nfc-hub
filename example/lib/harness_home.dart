import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nfc_hub/nfc_hub.dart';

import 'connection_status_bar.dart';
import 'tag_detail_page.dart';
import 'tag_readout.dart';

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
  final Stream<NfcConnectionState>? connectionState;

  @override
  State<HarnessHome> createState() => _HarnessHomeState();
}

/// One row's worth of a detected tag: the driver, its [TagInfo] (or the error
/// from a failed `readTagInfo()` -- a failed read still lists the tag rather
/// than dropping it silently), and, once the eager read finishes, the full
/// cached [TagReadout] the detail page shows. [readout] is null while the
/// eager read is still in flight (the row shows a spinner then).
class _TagEntry {
  _TagEntry({required this.driver, this.info, this.infoError});

  final TagDriver driver;
  final TagInfo? info;
  final Object? infoError;
  TagReadout? readout;
}

class _HarnessHomeState extends State<HarnessHome> {
  StreamSubscription<TagDriver>? _subscription;
  final List<_TagEntry> _entries = [];

  /// A SINGLE NfcHub shared by both the tag stream and the connection-state
  /// stream when neither is injected. `late final` so it is built only if a
  /// default is actually needed (never in tests, which inject both streams).
  /// Using one instance avoids spinning up two NfcHubs -- and therefore two
  /// CcidSource poll loops over the same USB readers, with doubled USB
  /// traffic and permission prompts.
  late final NfcHub _hub = NfcHub();

  /// The connection-state stream, resolved once (not per build, which would
  /// hand ConnectionStatusBar a fresh stream it ignores after the first).
  late final Stream<NfcConnectionState> _statesStream =
      widget.connectionState ?? _hub.connectionState();

  @override
  void initState() {
    super.initState();
    final tags = widget.tags ?? _hub.tagStream();
    _subscription = tags.listen(_onTag, onError: _onTagError);
  }

  /// Per-tap stream errors (e.g. [UnrecognizedTagException] for a tag no
  /// known family matches, or an identification failure on a seated card)
  /// must be visible to the operator -- hardware-validation scenario 9 taps
  /// an unsupported tag and expects observable feedback -- and must not
  /// become unhandled zone errors. The subscription itself survives; later
  /// taps keep arriving.
  void _onTagError(Object error) {
    nfcLog('harness: tag stream error: $error', error: error);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not read tag: $error')),
    );
  }

  Future<void> _onTag(TagDriver driver) async {
    nfcLog('harness: tag received from stream: ${driver.runtimeType}');
    // Phase 1: identify quickly so the row appears with its technology + UID.
    TagInfo? info;
    Object? infoError;
    try {
      info = await driver.readTagInfo();
      nfcLog('harness: readTagInfo -> ${info.technology}');
    } catch (e) {
      infoError = e;
      nfcLog('harness: readTagInfo failed: $e', error: e);
    }
    if (!mounted) return;
    final entry = _TagEntry(driver: driver, info: info, infoError: infoError);
    setState(() => _entries.insert(0, entry));

    // Phase 2: read EVERYTHING now, while the tag is still present, and cache
    // it -- so the detail view works after the card is lifted. The row shows
    // a spinner until this completes.
    final readout = await readEverything(
      driver,
      info: info,
      infoError: infoError,
      infoResolved: true,
    );
    if (!mounted) return;
    setState(() => entry.readout = readout);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _openDetail(_TagEntry entry) {
    final readout = entry.readout;
    if (readout == null) return; // still reading -- row isn't tappable yet
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TagDetailPage(readout: readout),
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
          // Pass BOTH the shared hub's connection-state stream AND its
          // openNfcSettings, so a bare HarnessHome() never makes
          // ConnectionStatusBar build its own second NfcHub -- neither for
          // the stream nor for the Enable-NFC action (see [_hub]).
          child: ConnectionStatusBar(
            states: _statesStream,
            onEnableNfc: _hub.openNfcSettings,
          ),
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
                    final title =
                        info?.technology ?? entry.driver.runtimeType.toString();
                    final uidHex =
                        info != null ? _hex(info.uid) : '(unavailable)';
                    final reading = entry.readout == null;
                    final subtitle = entry.infoError != null
                        ? 'UID: $uidHex — ${entry.infoError}'
                        : reading
                            ? 'UID: $uidHex — reading…'
                            : 'UID: $uidHex';
                    return ListTile(
                      leading: Icon(_iconFor(entry.driver)),
                      title: Text(title),
                      subtitle: Text(subtitle),
                      trailing: reading
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.chevron_right),
                      // Not tappable until the eager read has cached the data.
                      onTap: reading ? null : () => _openDetail(entry),
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
