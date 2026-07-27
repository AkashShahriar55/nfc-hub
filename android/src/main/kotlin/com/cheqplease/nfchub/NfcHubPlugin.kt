package com.cheqplease.nfchub

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.usb.*
import android.nfc.NfcAdapter
import android.os.Build
import android.os.Handler
import android.os.Looper
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import io.flutter.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result


/** NfcHubPlugin */
class NfcHubPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var context: Context
    private lateinit var appContext: Context
    private lateinit var usbManager: UsbManager
    private var readers = mutableMapOf<String, Reader>()

    // Last-logged USB topology / reader-name list, so listReaders() (called on
    // every 500ms poll tick) only logs on change instead of every tick.
    private var lastUsbSignature: String? = null
    private var lastReaderNames: List<String>? = null

    // CCID USB I/O (iccPowerOn, xfrBlock, device close) is BLOCKING -- USB bulk
    // transfers with multi-second timeouts. Method-channel handlers run on the
    // main (platform) thread, so running these there janks/ANRs the UI once the
    // auto-detect poll loop + eager reads issue many transceives. Run all CCID
    // USB work on this dedicated SERIAL background thread (single-threaded so a
    // reader's Ccid, incl. its CCID sequence counter, is only ever touched by
    // one thread), and post result.success/error back to the main thread.
    private val ccidExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    // Built-in-NFC tag I/O (connect/transceive/auth/readBlock) is blocking RF
    // I/O, exactly like the CCID USB path -- run it on its own serial executor
    // so it neither janks the main thread nor queues behind slow USB work.
    private val nfcExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private val mainHandler = Handler(Looper.getMainLooper())

    // --- Built-in (reader-mode) NFC state ---
    // One controller for the plugin's lifetime: it owns the handle->Tag map
    // and is the ReaderCallback, so re-creating it per event-channel
    // onListen/onCancel (as before) was fragile -- it only worked by
    // coincidence of dispatch ordering on the main thread. The sink is now a
    // mutable field on the controller (see setSink), set/cleared by the event
    // channel's onListen/onCancel.
    private lateinit var nfcController: NfcReaderModeController
    private var nfcEventSink: EventChannel.EventSink? = null
    private var activityBinding: Activity? = null
    // Source of truth for "should reader mode be on" is Dart (Task 4's
    // AndroidNfcSource, listener-count driven). We just remember the last
    // request so we can re-apply it across activity/config-change transitions
    // (the controller itself is stable now; this flag only drives whether we
    // re-call startReaderMode() after a fresh activity is attached).
    private var nfcReaderModeRequested = false
    private var nfcStateReceiverRegistered = false

    private val nfcStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context, intent: Intent) {
            if (intent.action == NfcAdapter.ACTION_ADAPTER_STATE_CHANGED) {
                val adapterState = intent.getIntExtra(
                    NfcAdapter.EXTRA_ADAPTER_STATE, NfcAdapter.STATE_OFF
                )
                // The app asked for reader mode while NFC was off (or the user toggled it
                // off and on): enableReaderMode was a no-op then, so re-apply it the
                // moment the adapter comes up -- otherwise built-in NFC stays dead until
                // the app restarts its session.
                if (adapterState == NfcAdapter.STATE_ON && nfcReaderModeRequested) {
                    nfcController.startReaderMode()
                }
                val map = HashMap<String, Any?>()
                map["type"] = "nfcStateChanged"
                map["state"] = nfcController.nfcState()
                nfcEventSink?.success(map)
            }
        }
    }

    private val usbReceiver = object : BroadcastReceiver() {
        @OptIn(ExperimentalStdlibApi::class)
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action == ACTION_USB_PERMISSION) {
                synchronized(this) {
                    val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    val granted =
                        intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)
                    NfcHubLog.d(
                        "USB permission result for \"${intent.getStringExtra("name")}\": " +
                                "granted=$granted device=${device?.deviceName ?: "(missing)"}"
                    )
                    if (granted) {
                        device?.apply {
                            val reader = readers[intent.getStringExtra("name")]
                            if (reader == null) {
                                NfcHubLog.e(
                                    "Permission granted but reader " +
                                            "\"${intent.getStringExtra("name")}\" is no longer " +
                                            "tracked (known: ${readers.keys})"
                                )
                                return
                            }
                            // Blocking USB work off the main thread (same reason
                            // as connect()); complete the pending Result on the
                            // main thread once connected.
                            ccidExecutor.execute {
                                try {
                                    val connected = connectToInterface(device, reader.interfaceIdx)
                                    mainHandler.post {
                                        if (connected != null) {
                                            val (ccid, atr) = connected
                                            readers[reader.name] = reader.copy(ccid = ccid, result = null)
                                            reader.result!!.success(atr.toHexString())
                                        } else {
                                            reader.result!!.error(
                                                "CCID_READER_CONNECT_ERROR",
                                                "Failed to connect",
                                                null
                                            )
                                        }
                                    }
                                } catch (e: Throwable) {
                                    NfcHubLog.e("CCID connect (post-permission) failed off-thread: ${e.message}", e)
                                    mainHandler.post {
                                        reader.result?.error("CCID_READER_CONNECT_ERROR", e.message, null)
                                    }
                                }
                            }
                        } ?: run {
                            // Permission granted but device is missing from intent.
                            // Look up the reader by name and complete its pending result
                            // so it doesn't hang the poll loop.
                            val grantedName = intent.getStringExtra("name")
                            val reader = grantedName?.let { readers[it] }
                            val pending = reader?.result
                            if (reader != null && pending != null) {
                                readers[reader.name] = reader.copy(result = null)
                                pending.error(
                                    "CCID_READER_CONNECT_ERROR",
                                    "USB device missing from permission response",
                                    null
                                )
                            }
                        }
                    } else {
                        NfcHubLog.e(
                            "USB permission DENIED for $device -- this reader will not be " +
                                    "retried until it is unplugged and re-attached"
                        )
                        val deniedName = intent.getStringExtra("name")
                        val reader = deniedName?.let { readers[it] }
                        val pending = reader?.result
                        if (reader != null && pending != null) {
                            readers[reader.name] = reader.copy(result = null)
                            pending.error(
                                "CCID_PERMISSION_DENIED",
                                "USB permission denied for reader ${reader.name}",
                                null
                            )
                        }
                    }
                }
            }
            if (intent.action == UsbManager.ACTION_USB_DEVICE_DETACHED) {
                synchronized(this) {
                    val device: UsbDevice? = intent.getParcelableExtra(UsbManager.EXTRA_DEVICE)
                    device?.let { detachedDevice ->
                        readers.values
                            .filter { it.deviceName == detachedDevice.deviceName }
                            .forEach { r ->
                                r.result?.error(
                                    "CCID_READER_DETACHED",
                                    "Reader ${r.name} detached while a request was pending",
                                    null
                                )
                            }
                        readers.entries.removeIf { (_, reader) ->
                            reader.deviceName == detachedDevice.deviceName
                        }
                        NfcHubLog.d("USB device detached: $detachedDevice")
                    }
                }
            }
        }
    }

    override fun onAttachedToEngine(flutterPluginBinding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(flutterPluginBinding.binaryMessenger, "nfc_hub")
        channel.setMethodCallHandler(this)

        appContext = flutterPluginBinding.applicationContext
        nfcController = NfcReaderModeController(appContext)

        eventChannel = EventChannel(flutterPluginBinding.binaryMessenger, "nfc_hub/events")
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
                nfcEventSink = sink
                nfcController.setSink(sink)
            }

            override fun onCancel(arguments: Any?) {
                nfcController.stopReaderMode()
                nfcEventSink = null
                nfcController.setSink(null)
            }
        })
    }

    @OptIn(ExperimentalStdlibApi::class)
    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "setLogging" -> {
                NfcHubLog.enabled = call.argument<Boolean>("enabled") ?: true
                NfcHubLog.verbose = call.argument<Boolean>("verbose") ?: false
                // Logged through Log directly, not NfcHubLog: a call that turns
                // logging OFF must still leave a trace of when it happened,
                // otherwise a silent log is indistinguishable from a dead one.
                Log.i(
                    NfcHubLog.TAG,
                    "setLogging: enabled=${NfcHubLog.enabled} verbose=${NfcHubLog.verbose}"
                )
                // Re-log the USB topology on the next tick. Both caches suppress
                // repeats, so enabling logging mid-session would otherwise show
                // polling activity with no baseline of what is actually attached.
                lastUsbSignature = null
                lastReaderNames = null
                result.success(null)
            }

            "listReaders" -> {
                result.success(listReaders())
            }

            "connect" -> {
                val name = call.arguments as String
                connect(name, result)
            }

            "transceive" -> {
                val name = call.argument<String>("reader")!!
                val capdu = call.argument<String>("capdu")!!
                val reader = readers[name]
                if (reader == null) {
                    NfcHubLog.e("transceive on unknown reader \"$name\" (known: ${readers.keys})")
                    result.error("CCID_READER_NOT_FOUND", "Reader not found", null)
                    return
                }
                val ccid = reader.ccid
                if (ccid == null) {
                    NfcHubLog.e("transceive on \"$name\" but no card session is open")
                    result.error("CCID_READER_NOT_CONNECTED", "Reader not connected", null)
                    return
                }
                // xfrBlock is a blocking USB bulk transfer; run it off the main
                // thread so the poll loop + eager reads never jank the UI.
                // Catch Throwable, not just CcidException: xfrBlock's parse path
                // can throw NegativeArraySizeException / ArrayIndexOutOfBounds on
                // a malformed reader response. On the main thread Flutter caught
                // any such escape and returned an error reply; off-thread it would
                // escape this Runnable, orphan `result`, and hang the Dart await
                // FOREVER -- which freezes CcidSource's poll loop (its _ticking
                // guard never clears). EVERY path here MUST complete `result`.
                ccidExecutor.execute {
                    try {
                        val resp = ccid.xfrBlock(capdu.hexToByteArray())
                        mainHandler.post { result.success(resp.toHexString()) }
                    } catch (e: CcidException) {
                        // Expected in normal operation (e.g. the liveness probe
                        // hitting a just-removed card) -- one debug line, no
                        // stack trace. The Dart side still gets the error reply.
                        NfcHubLog.d("CCID transceive failed: ${e.message}")
                        mainHandler.post { result.error("CCID_TRANSCEIVE_ERROR", e.message, null) }
                    } catch (e: Throwable) {
                        NfcHubLog.e("CCID transceive failed off-thread: ${e.message}", e)
                        mainHandler.post { result.error("CCID_TRANSCEIVE_ERROR", e.message, null) }
                    }
                }
            }

            "disconnect" -> {
                val name = call.arguments as String
                NfcHubLog.v("disconnect(\"$name\")")
                val reader = readers[name]
                if (reader == null) {
                    NfcHubLog.e("disconnect on unknown reader \"$name\" (known: ${readers.keys})")
                    result.error("CCID_READER_NOT_FOUND", "Reader not found", null)
                    return
                }
                // Clear the reference on the main thread immediately so any
                // subsequent transceive sees "not connected", then release the
                // held USB connection on the CCID executor -- serialized after
                // any transceive already queued for this reader, and off the
                // main thread since close() does USB teardown. Releasing the
                // connection (not just the reference) is what stops the poll
                // loop's removal/re-insertion cycle leaking one per removal.
                val ccid = reader.ccid
                readers[name] = reader.copy(ccid = null)
                ccidExecutor.execute {
                    try {
                        ccid?.close()
                        mainHandler.post { result.success(null) }
                    } catch (e: Throwable) {
                        // Must still complete `result` -- an orphaned Result here
                        // hangs the poll loop's disconnect await (see transceive).
                        NfcHubLog.e("CCID disconnect failed off-thread: ${e.message}", e)
                        mainHandler.post { result.error("CCID_DISCONNECT_ERROR", e.message, null) }
                    }
                }
            }

            "nfcStartReaderMode" -> {
                nfcReaderModeRequested = true
                nfcController.startReaderMode()
                result.success(null)
            }

            "nfcStopReaderMode" -> {
                nfcReaderModeRequested = false
                nfcController.stopReaderMode()
                result.success(null)
            }

            "nfcTransceive" -> {
                val handle = call.argument<Int>("handle")!!
                val tech = call.argument<String>("tech")!!
                val data = call.argument<ByteArray>("data")!!
                nfcExecutor.execute {
                    try {
                        val resp = nfcController.transceive(handle, tech, data)
                        mainHandler.post { result.success(resp) }
                    } catch (e: TagGoneException) {
                        mainHandler.post { result.error("TAG_LOST", e.message, null) }
                    } catch (e: Throwable) {
                        // EVERY path must complete `result` (see the CCID transceive
                        // comment above) -- an orphaned Result hangs the Dart await.
                        mainHandler.post { result.error("NFC_IO_ERROR", e.message, null) }
                    }
                }
            }

            "nfcMifareAuth" -> {
                val handle = call.argument<Int>("handle")!!
                val sector = call.argument<Int>("sector")!!
                val keyA = call.argument<Boolean>("keyA")!!
                val key = call.argument<ByteArray>("key")!!
                nfcExecutor.execute {
                    try {
                        val ok = nfcController.mifareAuthenticate(handle, sector, keyA, key)
                        mainHandler.post {
                            if (ok) result.success(null)
                            else result.error(
                                "MIFARE_AUTH_FAILED",
                                "MIFARE sector authentication rejected", null
                            )
                        }
                    } catch (e: TagGoneException) {
                        mainHandler.post { result.error("TAG_LOST", e.message, null) }
                    } catch (e: Throwable) {
                        mainHandler.post { result.error("NFC_IO_ERROR", e.message, null) }
                    }
                }
            }

            "nfcMifareReadBlock" -> {
                val handle = call.argument<Int>("handle")!!
                val block = call.argument<Int>("block")!!
                nfcExecutor.execute {
                    try {
                        val resp = nfcController.mifareReadBlock(handle, block)
                        mainHandler.post { result.success(resp) }
                    } catch (e: TagGoneException) {
                        mainHandler.post { result.error("TAG_LOST", e.message, null) }
                    } catch (e: Throwable) {
                        mainHandler.post { result.error("NFC_IO_ERROR", e.message, null) }
                    }
                }
            }

            "getNfcState" -> {
                result.success(nfcController.nfcState())
            }

            "openNfcSettings" -> {
                val intent = Intent(android.provider.Settings.ACTION_NFC_SETTINGS)
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                appContext.startActivity(intent)
                result.success(null)
            }

            else -> {
                result.notImplemented()
            }
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        ccidExecutor.shutdown()
        nfcExecutor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        context = binding.activity.applicationContext
        usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
        // Until this fires, `usbManager` is an uninitialized lateinit and every
        // listReaders() throws -- so "no readers, no logs" and "plugin never
        // attached to an activity" look identical from Dart. Mark the boundary.
        NfcHubLog.d(
            "onAttachedToActivity: UsbManager ready, USB receivers registered " +
                    "(package=${context.packageName}, sdk=${Build.VERSION.SDK_INT})"
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(
                usbReceiver, IntentFilter(ACTION_USB_PERMISSION), Context.RECEIVER_EXPORTED
            )
        } else {
            context.registerReceiver(usbReceiver, IntentFilter(ACTION_USB_PERMISSION))
        }
        context.registerReceiver(usbReceiver, IntentFilter(UsbManager.ACTION_USB_DEVICE_DETACHED))

        attachNfcActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        detachNfcActivity()
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        attachNfcActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        detachNfcActivity()
    }

    private fun attachNfcActivity(activity: Activity) {
        activityBinding = activity
        nfcController.attachActivity(activity)
        registerNfcStateReceiver()
        if (nfcReaderModeRequested) nfcController.startReaderMode()
    }

    private fun detachNfcActivity() {
        if (nfcStateReceiverRegistered) {
            try {
                context.unregisterReceiver(nfcStateReceiver)
            } catch (e: IllegalArgumentException) {
                // Not registered (e.g. onDetached without a matching attach); ignore.
            }
            nfcStateReceiverRegistered = false
        }
        nfcController.stopReaderMode()
        nfcController.attachActivity(null)
        activityBinding = null
    }

    private fun registerNfcStateReceiver() {
        if (nfcStateReceiverRegistered) return
        val filter = IntentFilter(NfcAdapter.ACTION_ADAPTER_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            context.registerReceiver(nfcStateReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(nfcStateReceiver, filter)
        }
        nfcStateReceiverRegistered = true
    }

    private fun listReaders(): List<String> {
        val readerTree = mutableMapOf<String, MutableList<Reader>>()
        val newReaders = mutableMapOf<String, Reader>()

        val deviceList = usbManager.deviceList
        // listReaders() runs on every poll tick (2x/s). Dumping the full USB
        // topology each time would bury everything else, so only log it when
        // the set of attached devices actually changes -- which is exactly when
        // it's interesting (plug/unplug, or a reader that never shows up at all).
        val signature = deviceList.values.joinToString(",") {
            "${it.deviceName}:${it.vendorId}:${it.productId}"
        }
        if (signature != lastUsbSignature) {
            lastUsbSignature = signature
            NfcHubLog.d("USB enumeration: ${deviceList.size} device(s) visible")
            deviceList.values.forEach { device ->
                NfcHubLog.d(
                    "  %s vid=0x%04X pid=0x%04X product=%s manufacturer=%s interfaces=%d".format(
                        device.deviceName,
                        device.vendorId,
                        device.productId,
                        device.productName ?: "(null)",
                        device.manufacturerName ?: "(null)",
                        device.interfaceCount
                    )
                )
                (0 until device.interfaceCount).forEach { i ->
                    val usbInterface = device.getInterface(i)
                    NfcHubLog.d(
                        "    if[%d] class=0x%02X subclass=0x%02X protocol=0x%02X endpoints=%d name=%s -> %s".format(
                            i,
                            usbInterface.interfaceClass,
                            usbInterface.interfaceSubclass,
                            usbInterface.interfaceProtocol,
                            usbInterface.endpointCount,
                            usbInterface.name ?: "(null)",
                            if (usbInterface.interfaceClass == UsbConstants.USB_CLASS_CSCID) {
                                "CCID (0x0B) -- usable"
                            } else {
                                "not CCID, ignored"
                            }
                        )
                    )
                }
                NfcHubLog.d("  permission held for ${device.deviceName}: ${usbManager.hasPermission(device)}")
            }
            if (deviceList.isEmpty()) {
                NfcHubLog.e(
                    "No USB devices visible at all. Either the reader is not " +
                            "enumerating (cable/OTG/power), or this build lacks USB host access."
                )
            }
        }

        deviceList.values.forEach { device ->
            (0 until device.interfaceCount).forEach { i ->
                val usbInterface = device.getInterface(i)
                if (usbInterface.interfaceClass == UsbConstants.USB_CLASS_CSCID) {
                    val displayName = getDisplayName(device, usbInterface)
                    val reader = Reader(displayName, device.deviceName, i, null, null)
                    readerTree.getOrPut(displayName) { mutableListOf() }.add(reader)
                }
            }
        }

        readerTree.forEach { (name, list) ->
            if (list.size > 1) {
                list.forEachIndexed { index, reader ->
                    newReaders["$name (${index + 1})"] = reader
                }
            } else {
                newReaders[name] = list[0]
            }
        }

        newReaders.forEach { (name, _) ->
            if (readers.containsKey(name)) {
                newReaders[name] = readers[name]!!
            }
        }

        readers = newReaders
        val names = readers.keys.toList()
        if (names != lastReaderNames) {
            lastReaderNames = names
            NfcHubLog.d("listReaders -> $names")
        }
        return names
    }

    @OptIn(ExperimentalStdlibApi::class)
    private fun connect(name: String, result: Result) {
        NfcHubLog.v("connect(\"$name\")")
        val reader = readers[name]
        if (reader == null) {
            NfcHubLog.e("connect(\"$name\"): not in readers map (known: ${readers.keys})")
            result.error("CCID_READER_NOT_FOUND", "Reader not found", null)
            return
        }
        if (reader.result != null) {
            NfcHubLog.d("connect(\"$name\"): a USB permission request is already pending")
            // A permission request is already in flight for this reader; completing
            // a second one would orphan the first (a Result that never completes
            // hangs the Dart-side await forever -- see CcidSource's poll loop).
            result.error(
                "CCID_PERMISSION_PENDING",
                "A USB permission request is already pending for $name",
                null
            )
            return
        }
        val device =
            usbManager.deviceList.filter { it.key == reader.deviceName }.values.firstOrNull()
        if (device == null) {
            NfcHubLog.e(
                "connect(\"$name\"): USB device ${reader.deviceName} is gone from " +
                        "deviceList (now: ${usbManager.deviceList.keys})"
            )
            result.error("CCID_READER_NOT_FOUND", "Reader not found", null)
            return
        }

        if (reader.ccid != null) {
            NfcHubLog.d("connect(\"$name\"): already connected (a card session is open)")
            result.error("CCID_READER_ALREADY_CONNECTED", "Reader already connected", null)
            return
        }

        if (!usbManager.hasPermission(device)) {
            NfcHubLog.d(
                "connect(\"$name\"): no USB permission -- showing the OS dialog. " +
                        "Nothing can be read until it is granted."
            )
            // Request permission
            readers[name] = reader.copy(result = result)
            val intent = Intent(ACTION_USB_PERMISSION)
            intent.putExtra("name", name)
            intent.setPackage(context.packageName)
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                0,
                intent,
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            )
            usbManager.requestPermission(device, pendingIntent)
            return
        } else {
            // connectToInterface does blocking USB work (openDevice, iccPowerOn
            // with a multi-second timeout). Run it on the CCID executor so an
            // empty-reader poll tick can't block the main thread on a slow/failed
            // power-on. Mutate the readers map back on the main thread.
            ccidExecutor.execute {
                try {
                    val connected = connectToInterface(device, reader.interfaceIdx)
                    mainHandler.post {
                        if (connected != null) {
                            val (ccid, atr) = connected
                            readers[name] = reader.copy(ccid = ccid)
                            result.success(atr.toHexString())
                        } else {
                            result.error("CCID_READER_CONNECT_ERROR", "Failed to connect", null)
                        }
                    }
                } catch (e: Throwable) {
                    // Must still complete `result` -- an orphaned Result here hangs
                    // the poll loop's connect await (see transceive).
                    NfcHubLog.e("CCID connect failed off-thread: ${e.message}", e)
                    mainHandler.post { result.error("CCID_READER_CONNECT_ERROR", e.message, null) }
                }
            }
        }
    }

    @OptIn(ExperimentalStdlibApi::class)
    private fun connectToInterface(device: UsbDevice, interfaceIdx: Int): Pair<Ccid, ByteArray>? {
        NfcHubLog.v("connectToInterface(${device.deviceName}, if=$interfaceIdx)")
        val usbInterface = device.getInterface(interfaceIdx)
        val usbConnection = usbManager.openDevice(device)
        if (usbConnection == null) {
            NfcHubLog.e(
                "openDevice(${device.deviceName}) returned null -- permission revoked, " +
                        "or the device is claimed by another process/driver"
            )
            return null
        }
        var success = false
        return try {
            val endpoints = getEndpoints(usbInterface)
            NfcHubLog.v(
                "  endpoints: bulkIn addr=0x%02X max=%dB, bulkOut addr=0x%02X max=%dB".format(
                    endpoints.first.address,
                    endpoints.first.maxPacketSize,
                    endpoints.second.address,
                    endpoints.second.maxPacketSize
                )
            )
            val ccid = Ccid(usbConnection, endpoints.first, endpoints.second)
            val descriptor = ccid.getDescriptor(interfaceIdx)
            if (descriptor?.supportsProtocol(Protocol.T1) != true) {
                NfcHubLog.e(
                    "Unsupported protocol: descriptor=$descriptor -- T=1 not advertised, " +
                            "so this reader is rejected before any card is ever powered on"
                )
                return null
            }
            if (!usbConnection.claimInterface(usbInterface, true)) {
                NfcHubLog.e(
                    "claimInterface(if=$interfaceIdx) failed -- another process (or a " +
                            "leaked connection from a previous attempt) still holds it"
                )
                return null
            }
            val atr = ccid.iccPowerOn()
            // ACR122U firmware quirk: the PICC slot can answer iccPowerOn with
            // SUCCESS and a degenerate stub ATR (3B 00) when NO card is present;
            // every later transceive then fails with iccStatus=2 (ICC not
            // present). No real contactless card yields an ATR this short (PC/SC
            // Part 3 pseudo-ATRs and ATS-derived ATRs are always >= 5 bytes), so
            // treat it as "no card" here -- otherwise the Dart poll loop sees a
            // phantom card and spins a connect/identify-fail/disconnect loop.
            if (atr.size < 5) {
                NfcHubLog.v("Degenerate ATR ${atr.toHexString()} -- no card present")
                return null
            }
            NfcHubLog.d("CARD DETECTED on ${device.deviceName} if=$interfaceIdx, ATR: ${atr.toHexString()}")
            success = true
            Pair(ccid, atr)
        } catch (e: CcidException) {
            // Expected on every poll tick of an empty reader (no card answers
            // power-on) -- verbose, not error, and no stack trace.
            NfcHubLog.v("No card / power-on failed: ${e.message}")
            null
        } catch (e: Exception) {
            NfcHubLog.e("Failed to connect to interface: ${e.message}", e)
            null
        } finally {
            // Release the USB connection on EVERY failure path. The auto-detect
            // poll loop calls connect() on an empty reader every tick; iccPowerOn
            // fails (no card) each time, and without this close() each attempt
            // leaked a UsbDeviceConnection and a claimed interface. That
            // accumulation corrupts the reader's USB state so that once a card
            // IS placed it can no longer be powered on. Only the success path
            // keeps the connection open (it becomes the card's session).
            if (!success) {
                usbConnection.close()
            }
        }
    }

    private fun getEndpoints(usbInterface: UsbInterface): Pair<UsbEndpoint, UsbEndpoint> {
        var bulkIn: UsbEndpoint? = null
        var bulkOut: UsbEndpoint? = null
        for (i in 0 until usbInterface.endpointCount) {
            val endpoint = usbInterface.getEndpoint(i)
            if (endpoint.type == UsbConstants.USB_ENDPOINT_XFER_BULK) {
                if (endpoint.direction == UsbConstants.USB_DIR_IN) {
                    bulkIn = endpoint
                } else {
                    bulkOut = endpoint
                }
            }
        }
        if (bulkIn == null || bulkOut == null) {
            NfcHubLog.e(
                "Bulk endpoints not found on interface ${usbInterface.id} " +
                        "(${usbInterface.endpointCount} endpoint(s): bulkIn=$bulkIn bulkOut=$bulkOut)"
            )
            throw Exception("Bulk endpoints not found")
        }
        return Pair(bulkIn, bulkOut)
    }

    private fun getDisplayName(device: UsbDevice, usbInterface: UsbInterface): String {
        val nameParts = mutableListOf<String>()
        if (device.productName != null) {
            nameParts.add(device.productName!!)
        } else {
            nameParts.add("Unknown")
        }

        if (usbInterface.name != null) {
            nameParts.add(usbInterface.name!!)
        } else {
            nameParts.add("CCID")
        }

        return nameParts.joinToString(" ")
    }

    companion object {
        private const val ACTION_USB_PERMISSION = "com.cheqplease.nfchub.USB_PERMISSION"
    }

    private data class Reader(
        val name: String,
        val deviceName: String,
        val interfaceIdx: Int,
        val ccid: Ccid?,
        val result: Result?
    )
}
