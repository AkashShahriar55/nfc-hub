import '../tag/tag_driver.dart';

/// A source of identified tags -- the phone's built-in NFC antenna
/// ([AndroidNfcSource], later `CcidSource`), or (Task 7) the two merged into
/// one unified stream.
///
/// Implementations turn whatever discovery mechanism they wrap into a
/// stream of fully-identified [TagDriver]s, ready for family-specific reads.
abstract class TagSource {
  /// A stream of identified tags. Implementations typically start whatever
  /// underlying discovery mechanism they need on first listen, and stop it
  /// once the last listener cancels -- so nothing stays "hot" (radios,
  /// polling loops) with nobody consuming it.
  Stream<TagDriver> tags();

  /// Releases any resources held by this source (stopping discovery if it
  /// is still running). After calling this, the source must not be used
  /// again.
  Future<void> dispose();
}
