import 'dart:async';

import 'package:flutter/foundation.dart';

import 'nfc_hub_api.dart';
import 'platform/android_nfc_manager.dart';
import 'platform/platform_interface.dart';
import 'source/android_source.dart';
import 'source/ccid_source.dart';
import 'tag/tag_driver.dart';

/// The device's single entry point for both direct CCID/PC-SC access
/// ([listReaders]/[connect], unchanged since before Plan 3) and the unified
/// tag API added in Plan 3 Task 7 ([tagStream]/[readTag]/[connectionState]/
/// [openNfcSettings]), which merges the phone's built-in NFC antenna with
/// CCID/PC-SC readers behind one API.
///
/// The [AndroidNfcManager]/[AndroidNfcSource]/[CcidSource] backing the
/// unified API are constructed lazily, on first use, and reused after that.
/// The constructor parameters below exist purely so tests can substitute
/// fakes for them; production callers should just use `NfcHub()`.
class NfcHub {
  NfcHub({
    @visibleForTesting AndroidNfcManager? androidNfcManager,
    @visibleForTesting AndroidNfcSource? androidNfcSource,
    @visibleForTesting CcidSource? ccidSource,
  })  : _androidNfcManager = androidNfcManager,
        _androidNfcSource = androidNfcSource,
        _ccidSource = ccidSource;

  AndroidNfcManager? _androidNfcManager;
  AndroidNfcSource? _androidNfcSource;
  CcidSource? _ccidSource;

  AndroidNfcManager get _manager => _androidNfcManager ??= AndroidNfcManager();

  AndroidNfcSource get _nfcSource =>
      _androidNfcSource ??= AndroidNfcSource(_manager);

  CcidSource get _readerSource =>
      _ccidSource ??= CcidSource(NfcHubPlatform.instance);

  /// List available readers
  ///
  /// Returns a list of reader names
  Future<List<String>> listReaders() {
    return NfcHubPlatform.instance.listReaders();
  }

  /// Connect to a reader by its name [reader]
  ///
  /// Returns a [CcidCard] object
  Future<CcidCard> connect(String reader) {
    return NfcHubPlatform.instance.connect(reader);
  }

  /// A unified stream of identified tags from both the phone's built-in NFC
  /// antenna and every attached CCID/PC-SC reader, merged behind one API --
  /// an app never has to know, or branch on, which source produced a tag.
  ///
  /// Pass [from] to restrict to a single source instead: a
  /// [CcidSourceFilter.builtInNfc] for the phone's own antenna, or a
  /// [CcidSourceFilter.reader] for one named CCID/PC-SC reader. Omit it (or
  /// pass `null`) to receive tags from every source, interleaved as they
  /// arrive.
  ///
  /// Starts whichever underlying source(s) the filter selects on first
  /// listen, and stops them once the last listener of this stream cancels.
  Stream<TagDriver> tagStream({CcidSourceFilter? from}) {
    return mergeTagStreams(
      androidSource: _nfcSource,
      ccidSource: _readerSource,
      filter: from,
    );
  }

  /// Returns the first tag seen on [tagStream] (optionally narrowed by
  /// [from]).
  ///
  /// If [timeout] is given and no tag arrives within it, the returned
  /// future completes with a [TimeoutException] instead.
  Future<TagDriver> readTag({CcidSourceFilter? from, Duration? timeout}) {
    final first = tagStream(from: from).first;
    return timeout == null ? first : first.timeout(timeout);
  }

  /// A stream of the combined connection state: whether the phone's
  /// built-in NFC antenna is currently available (and why not, if it
  /// isn't), plus the live presence state of every attached CCID/PC-SC
  /// reader.
  Stream<CcidConnectionState> connectionState() {
    return combineConnectionState(
      manager: _manager,
      ccidSource: _readerSource,
    );
  }

  /// Opens the system NFC settings screen, so the user can turn NFC on.
  Future<void> openNfcSettings() => _manager.openNfcSettings();
}

class CcidCard {
  final String reader;

  /// The card's answer-to-reset, captured at connect time where the
  /// platform supports it (Android only, currently). Null on platforms/
  /// paths that don't surface it — `identifyTag` falls back to capability
  /// probing in that case.
  final Uint8List? atr;

  CcidCard(this.reader, {this.atr});

  /// Send APDU command [capdu]
  ///
  /// Returns the response APDU
  Future<String?> transceive(String capdu) {
    return NfcHubPlatform.instance.transceive(reader, capdu);
  }

  /// Disconnect from the card
  Future<void> disconnect() {
    return NfcHubPlatform.instance.disconnect(reader);
  }
}
