import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nfc_hub/nfc_hub.dart';

/// The live dual-source connection header for the harness: a chip for the
/// phone's built-in NFC antenna (ready / disabled+Enable / no-hardware /
/// unknown-while-waiting) plus one chip per attached CCID/PC-SC reader,
/// each showing its name and a filled/hollow dot for whether a card is
/// currently seated.
///
/// [states] and [onEnableNfc] are injectable so tests can drive this widget
/// without touching the platform channel. When not supplied, they default
/// to a lazily-created [NfcHub]'s `connectionState()`/`openNfcSettings`.
class ConnectionStatusBar extends StatefulWidget {
  const ConnectionStatusBar({super.key, this.states, this.onEnableNfc});

  final Stream<NfcConnectionState>? states;
  final Future<void> Function()? onEnableNfc;

  @override
  State<ConnectionStatusBar> createState() => _ConnectionStatusBarState();
}

class _ConnectionStatusBarState extends State<ConnectionStatusBar> {
  StreamSubscription<NfcConnectionState>? _subscription;
  NfcConnectionState? _state;

  @override
  void initState() {
    super.initState();
    final states = widget.states ?? NfcHub().connectionState();
    _subscription = states.listen((state) {
      if (!mounted) return;
      setState(() => _state = state);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  Future<void> _enableNfc() {
    final onEnableNfc = widget.onEnableNfc ?? NfcHub().openNfcSettings;
    return onEnableNfc();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final state = _state;

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _builtInNfcChip(theme, state),
        if (state?.builtInNfcReason == NfcUnavailableReason.disabled)
          TextButton(
            onPressed: _enableNfc,
            child: const Text('Enable'),
          ),
        for (final reader in state?.externalReaders ?? const [])
          _readerChip(theme, reader),
      ],
    );
  }

  Widget _builtInNfcChip(ThemeData theme, NfcConnectionState? state) {
    if (state == null) {
      return const Chip(label: Text('NFC: unknown'));
    }
    if (state.builtInNfcAvailable) {
      return Chip(
        avatar: Icon(Icons.check_circle,
            color: theme.colorScheme.primary, size: 18),
        label: const Text('NFC ready'),
      );
    }
    switch (state.builtInNfcReason) {
      case NfcUnavailableReason.disabled:
        return Chip(
          avatar: Icon(Icons.nfc, color: theme.colorScheme.error, size: 18),
          label: const Text('NFC disabled'),
        );
      case NfcUnavailableReason.noHardware:
        return const Chip(label: Text('No NFC hardware'));
      case NfcUnavailableReason.none:
        return const Chip(label: Text('NFC: unknown'));
    }
  }

  Widget _readerChip(ThemeData theme, ExternalReaderState reader) {
    return Chip(
      avatar: Icon(
        reader.cardPresent ? Icons.circle : Icons.circle_outlined,
        size: 14,
        color: reader.cardPresent
            ? theme.colorScheme.primary
            : theme.disabledColor,
      ),
      label: Text(reader.name),
    );
  }
}
