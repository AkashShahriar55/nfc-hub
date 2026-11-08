package com.nsa.nfchub

import io.flutter.Log

/// The plugin's single, greppable logging surface on the Android side.
///
/// Everything goes out under the tag "NfcHub". (The plugin previously logged
/// under `FlutterPlugin::class.java.name` -- the literal string
/// "io.flutter.embedding.engine.plugins.FlutterPlugin" -- which is shared with
/// the engine and impossible to filter on.) To watch a reader session:
///
///     adb logcat -c && adb logcat -s NfcHub:V
///
/// Both switches are driven from Dart by `NfcHub.setLogging(...)` (method
/// channel "setLogging"), so log volume can be changed from app code without
/// rebuilding the plugin.
object NfcHubLog {
    const val TAG = "NfcHub"

    /// Gates the event trace ([d]): reader attach/detach, card detect, USB
    /// permission results. Roughly a line per event. On by default so a
    /// misbehaving reader leaves evidence even if the app never calls
    /// setLogging.
    @JvmStatic
    var enabled = true

    /// Gates the frame-level trace ([v]): every USB bulk transfer, decoded
    /// CCID headers, per-tick connect attempts. OFF by default -- the poll
    /// loop runs twice a second, so this is well over a thousand lines a
    /// minute on an idle reader and buries everything else.
    @JvmStatic
    var verbose = false

    /// Lifecycle and decision points -- low volume. Silenced by [enabled].
    fun d(message: String) {
        if (enabled) Log.d(TAG, message)
    }

    /// Failures. ALWAYS logged, at any setting -- an error you turned off is
    /// an error you will debug twice.
    fun e(message: String, error: Throwable? = null) {
        if (error != null) Log.e(TAG, message, error) else Log.e(TAG, message)
    }

    /// High-volume trace (USB frames, per-tick polling). Needs BOTH switches:
    /// verbose is a level above the event trace, not a way around it.
    fun v(message: String) {
        if (enabled && verbose) Log.d(TAG, message)
    }
}

/// CCID bStatus bits 0-1 (ICC status), spelled out. "ICC not present" is the
/// one to look for when a card is physically on the reader but nothing reads:
/// it means the reader's own antenna never picked the card up.
fun iccStatusLabel(iccStatus: Int): String = when (iccStatus) {
    0 -> "ICC present and active"
    1 -> "ICC present and inactive"
    2 -> "ICC not present"
    else -> "reserved"
}

/// CCID bStatus bits 6-7 (command status).
fun commandStatusLabel(commandStatus: Int): String = when (commandStatus) {
    0 -> "processed without error"
    1 -> "failed"
    2 -> "time extension requested"
    else -> "reserved"
}

private val HEX_DIGITS = "0123456789ABCDEF".toCharArray()

/// Uppercase hex of the first [limit] bytes, with a "+NB" suffix when
/// truncated -- logcat drops long lines, and a full 256-byte read block would
/// otherwise push the interesting header off the end.
fun ByteArray.toLogHex(limit: Int = 64): String {
    if (isEmpty()) return "(empty)"
    val shown = minOf(size, limit)
    val sb = StringBuilder(shown * 2)
    for (i in 0 until shown) {
        val b = this[i].toInt() and 0xff
        sb.append(HEX_DIGITS[b shr 4]).append(HEX_DIGITS[b and 0x0f])
    }
    if (size > shown) sb.append("+${size - shown}B")
    return sb.toString()
}
