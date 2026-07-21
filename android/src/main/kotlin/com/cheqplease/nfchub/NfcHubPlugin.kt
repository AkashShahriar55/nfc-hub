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

    // CCID USB I/O (iccPowerOn, xfrBlock, device close) is BLOCKING -- USB bulk
    // transfers with multi-second timeouts. Method-channel handlers run on the
    // main (platform) thread, so running these there janks/ANRs the UI once the
    // auto-detect poll loop + eager reads issue many transceives. Run all CCID
    // USB work on this dedicated SERIAL background thread (single-threaded so a
    // reader's Ccid, incl. its CCID sequence counter, is only ever touched by
    // one thread), and post result.success/error back to the main thread.
    private val ccidExecutor: ExecutorService = Executors.newSingleThreadExecutor()
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
                    if (intent.getBooleanExtra(UsbManager.EXTRA_PERMISSION_GRANTED, false)) {
                        device?.apply {
                            val reader = readers[intent.getStringExtra("name")]
                            if (reader == null) {
                                Log.e(TAG, "Reader not found")
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
                                    Log.e(TAG, "CCID connect (post-permission) failed off-thread: ${e.message}", e)
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
                        Log.d(TAG, "permission denied for device $device")
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
                        Log.d(TAG, "USB device detached: $detachedDevice")
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
                    result.error("CCID_READER_NOT_FOUND", "Reader not found", null)
                    return
                }
                val ccid = reader.ccid
                if (ccid == null) {
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
                    } catch (e: Throwable) {
                        Log.e(TAG, "CCID transceive failed off-thread: ${e.message}", e)
                        mainHandler.post { result.error("CCID_TRANSCEIVE_ERROR", e.message, null) }
                    }
                }
            }

            "disconnect" -> {
                val name = call.arguments as String
                val reader = readers[name]
                if (reader == null) {
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
                        Log.e(TAG, "CCID disconnect failed off-thread: ${e.message}", e)
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
                try {
                    result.success(nfcController.transceive(handle, tech, data))
                } catch (e: TagGoneException) {
                    result.error("TAG_LOST", e.message, null)
                }
            }

            "nfcMifareAuth" -> {
                val handle = call.argument<Int>("handle")!!
                val sector = call.argument<Int>("sector")!!
                val keyA = call.argument<Boolean>("keyA")!!
                val key = call.argument<ByteArray>("key")!!
                try {
                    val ok = nfcController.mifareAuthenticate(handle, sector, keyA, key)
                    if (ok) {
                        result.success(null)
                    } else {
                        result.error("MIFARE_AUTH_FAILED", "MIFARE sector authentication rejected", null)
                    }
                } catch (e: TagGoneException) {
                    result.error("TAG_LOST", e.message, null)
                }
            }

            "nfcMifareReadBlock" -> {
                val handle = call.argument<Int>("handle")!!
                val block = call.argument<Int>("block")!!
                try {
                    result.success(nfcController.mifareReadBlock(handle, block))
                } catch (e: TagGoneException) {
                    result.error("TAG_LOST", e.message, null)
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
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        context = binding.activity.applicationContext
        usbManager = context.getSystemService(Context.USB_SERVICE) as UsbManager
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

        usbManager.deviceList.values.forEach { device ->
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
        return readers.keys.toList()
    }

    @OptIn(ExperimentalStdlibApi::class)
    private fun connect(name: String, result: Result) {
        val reader = readers[name]
        if (reader == null) {
            result.error("CCID_READER_NOT_FOUND", "Reader not found", null)
            return
        }
        if (reader.result != null) {
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
            result.error("CCID_READER_NOT_FOUND", "Reader not found", null)
            return
        }

        if (reader.ccid != null) {
            result.error("CCID_READER_ALREADY_CONNECTED", "Reader already connected", null)
            return
        }

        if (!usbManager.hasPermission(device)) {
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
                    Log.e(TAG, "CCID connect failed off-thread: ${e.message}", e)
                    mainHandler.post { result.error("CCID_READER_CONNECT_ERROR", e.message, null) }
                }
            }
        }
    }

    @OptIn(ExperimentalStdlibApi::class)
    private fun connectToInterface(device: UsbDevice, interfaceIdx: Int): Pair<Ccid, ByteArray>? {
        val usbInterface = device.getInterface(interfaceIdx)
        val usbConnection = usbManager.openDevice(device)
        if (usbConnection == null) {
            Log.e(TAG, "Failed to open device")
            return null
        }
        var success = false
        return try {
            val endpoints = getEndpoints(usbInterface)
            val ccid = Ccid(usbConnection, endpoints.first, endpoints.second)
            val descriptor = ccid.getDescriptor(interfaceIdx)
            if (descriptor?.supportsProtocol(Protocol.T1) != true) {
                Log.d(TAG, "Unsupported protocol")
                return null
            }
            if (!usbConnection.claimInterface(usbInterface, true)) {
                Log.e(TAG, "Failed to claim interface")
                return null
            }
            val atr = ccid.iccPowerOn()
            Log.d(TAG, "ATR: ${atr.toHexString()}")
            success = true
            Pair(ccid, atr)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to connect to interface: ${e.message}")
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
        private val TAG = FlutterPlugin::class.java.name
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
