import 'package:flutter/foundation.dart';
import 'package:platform_detector/platform_detector.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../nfc_hub_base.dart';
import 'method_channel.dart';
import 'pcsc.dart';

abstract class CcidPlatform extends PlatformInterface {
  /// Constructs a CcidPlatform.
  CcidPlatform() : super(token: _token);

  static final Object _token = Object();

  static final CcidPlatform _methodChannelInstance = MethodChannelCcid();

  static final CcidPlatform _pcscInstance = PcscCcid();

  static CcidPlatform? _instanceOverride;

  /// The default instance of [CcidPlatform] to use.
  ///
  /// Defaults to [MethodChannelCcid] on mobile/macOS, [PcscCcid] elsewhere.
  static CcidPlatform get instance {
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
  static set instance(CcidPlatform? instance) {
    if (instance != null) {
      PlatformInterface.verifyToken(instance, _token);
    }
    _instanceOverride = instance;
  }

  Future<List<String>> listReaders() {
    throw UnimplementedError('poll() has not been implemented.');
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
}
