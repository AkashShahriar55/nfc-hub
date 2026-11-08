import 'package:flutter/foundation.dart';
import 'package:platform_detector/platform_detector.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../nfc_hub_base.dart';
import 'method_channel.dart';
import 'pcsc.dart';

abstract class NfcHubPlatform extends PlatformInterface {
  /// Constructs a NfcHubPlatform.
  NfcHubPlatform() : super(token: _token);

  static final Object _token = Object();

  static final NfcHubPlatform _methodChannelInstance = MethodChannelNfcHub();

  static final NfcHubPlatform _pcscInstance = PcscNfcHub();

  static NfcHubPlatform? _instanceOverride;

  /// The default instance of [NfcHubPlatform] to use.
  ///
  /// Defaults to [MethodChannelNfcHub] on mobile/macOS, [PcscNfcHub] elsewhere.
  static NfcHubPlatform get instance {
    final override = _instanceOverride;
    if (override != null) {
      return override;
    }
    if (isMobile() || isMacOs()) {
      return _methodChannelInstance;
    } else {
      return _pcscInstance;
    }
  }

  /// Sets a test-only override for [instance]. Pass `null` to restore the
  /// platform-selected default.
  @visibleForTesting
  static set instance(NfcHubPlatform? instance) {
    if (instance != null) {
      PlatformInterface.verifyToken(instance, _token);
    }
    _instanceOverride = instance;
  }

  Future<List<String>> listReaders() {
    throw UnimplementedError('listReaders() has not been implemented.');
  }

  Future<String?> transceive(String reader, String capdu) {
    throw UnimplementedError('transceive() has not been implemented.');
  }

  Future<CcidCard> connect(String reader) {
    throw UnimplementedError('connect() has not been implemented.');
  }

  Future<void> disconnect(String reader) {
    throw UnimplementedError('disconnect() has not been implemented.');
  }

  /// Pushes the log settings down to the native side, where the USB/CCID
  /// tracing actually lives.
  ///
  /// A no-op by default rather than a throw: a platform with no native half to
  /// configure (PC/SC) and a test fake should both be able to ignore this
  /// without breaking [NfcHub.setLogging].
  Future<void> setLogging(
      {required bool enabled, required bool verbose}) async {}
}
