import 'dart:typed_data';

/// Base class for tag-family-specific drivers returned by [identifyTag]
/// (see `detection.dart`).
///
/// Each driver wraps a typed transport (see `../transport/transport.dart`)
/// and exposes only the read operations that make sense for that tag
/// family. Drivers are transport-agnostic: the same driver serves a card on
/// a USB CCID reader and a tag on the device's own antenna.
abstract class TagDriver {
  /// Creates a driver.
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
  /// A readable name for the tag's technology.
  String get technology;

  /// The tag's unique identifier.
  Uint8List get uid;

  /// The card's ATR, or null on sources without one, such as built-in NFC.
  Uint8List? get atr;
}

/// Thrown by `identifyTag` when a connected card doesn't match any known
/// tag family, whether via ATR matching or capability probing.
class UnrecognizedTagException implements Exception {
  /// A description of the failure.
  final String message;

  /// Creates an exception with [message].
  const UnrecognizedTagException(this.message);

  @override
  String toString() => 'UnrecognizedTagException: $message';
}
