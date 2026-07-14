import 'dart:typed_data';

import '../nfc_hub_base.dart';

/// Base class for tag-family-specific drivers returned by [identifyTag]
/// (see `ccid_tag_detection.dart`).
///
/// Each driver wraps a connected [CcidCard] and exposes only the read
/// operations that make sense for that tag family.
abstract class TagDriver {
  final CcidCard card;

  const TagDriver(this.card);
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
