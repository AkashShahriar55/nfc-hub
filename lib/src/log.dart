import 'package:flutter/foundation.dart';

/// Whether nfc_hub emits its diagnostic trace at all: poll-loop lifecycle,
/// per-reader state transitions, connect/identify outcomes, card insert and
/// removal. Roughly a line per event, plus a heartbeat every ~10s.
///
/// Defaults to on in debug builds, off in release. Errors are logged
/// regardless — this gates the trace, never a failure.
///
/// Prefer [NfcHub.setLogging], which sets this AND the native half in one
/// call. Setting this variable directly only affects the Dart half, leaving
/// the native USB tracing wherever it already was.
bool nfcHubLogging = kDebugMode;

/// Whether the **native** CCID layer dumps every USB frame: raw bulk-in/out
/// hex, per-transfer byte counts, decoded `RDR_to_PC` headers.
///
/// Off by default, and deliberately separate from [nfcHubLogging], because
/// this is the firehose: the poll loop probes twice a second and each probe is
/// ~5 lines, so a minute of an idle reader is well over a thousand lines. Turn
/// it on only when you need to see what the reader is actually saying on the
/// wire — a card that won't power on, or an APDU that returns something
/// unexpected.
///
/// Dart-side only reflects the last value pushed via [NfcHub.setLogging];
/// nothing in Dart reads it, since there are no Dart-side frame dumps.
bool nfcHubVerboseLogging = false;

/// Prefix on every Dart-side line, so the trace can be picked out of other
/// `flutter`-tagged output with a plain `grep nfc_hub`.
const _prefix = 'nfc_hub';

/// Logs one diagnostic line, prefixed with [name].
///
/// Emitted with [debugPrint], NOT `dart:developer`'s `log()`. That distinction
/// matters for field debugging: `developer.log` only reaches the VM service,
/// so it shows in a `flutter run` console but is INVISIBLE to `adb logcat` —
/// which is exactly the tool you reach for when a reader misbehaves on a
/// device that isn't attached to a dev machine. `debugPrint` reaches both,
/// landing in logcat under the `flutter` tag.
///
/// Lines carrying an [error] are always emitted; plain trace lines only when
/// [nfcHubLogging] is on.
void nfcLog(
  String message, {
  String name = _prefix,
  Object? error,
  StackTrace? stackTrace,
}) {
  if (!nfcHubLogging && error == null) return;
  debugPrint('[$name] $message');
  // Only for genuine failures -- a stack trace per trace line would drown the
  // signal the rest of this instrumentation exists to surface.
  if (stackTrace != null) debugPrint('[$name] $stackTrace');
}
