import 'ccid.dart';

/// Base class for tag-family-specific drivers returned by [identifyTag]
/// (see `ccid_tag_detection.dart`).
///
/// Each driver wraps a connected [CcidCard] and exposes only the read
/// operations that make sense for that tag family.
abstract class TagDriver {
  final CcidCard card;

  const TagDriver(this.card);
}

/// Thrown by `identifyTag` when a connected card doesn't match any known
/// tag family, whether via ATR matching or capability probing.
class UnrecognizedTagException implements Exception {
  final String message;

  const UnrecognizedTagException(this.message);

  @override
  String toString() => 'UnrecognizedTagException: $message';
}
