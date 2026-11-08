import 'dart:typed_data';

/// Base class for tag-family-specific drivers returned by [identifyTag]
/// (see `detection.dart`).
///
/// Each driver wraps a typed transport (see `../transport/transport.dart`)
/// and exposes only the read operations that make sense for that tag
/// family. Drivers are transport-agnostic: the same driver serves a card on
/// a USB CCID reader and a tag on the device's own antenna.
abstract class TagDriver {
  const TagDriver();

  /// A generic identification summary for this tag: technology, UID, and
  /// ATR where the transport supplies one. Concrete drivers return their
  /// family-specific subtype (e.g. [Type2Tag] returns a `Type2TagInfo`).
  Future<TagInfo> readTagInfo();
}

/// A generic identification summary common to every tag family, returned
/// by each driver's `readTagInfo()`. Concrete subclasses (`Type2TagInfo`,
/// `MifareClassicInfo`, `FelicaInfo`, `IsoDepInfo`, `TypeBInfo`) add
/// family-specific fields.
abstract class TagInfo {
  String get technology;
  Uint8List get uid;
  Uint8List? get atr;
}

/// Thrown by `identifyTag` when a connected card doesn't match any known
/// tag family, whether via ATR matching or capability probing.
class UnrecognizedTagException implements Exception {
  final String message;

  const UnrecognizedTagException(this.message);

  @override
  String toString() => 'UnrecognizedTagException: $message';
}
