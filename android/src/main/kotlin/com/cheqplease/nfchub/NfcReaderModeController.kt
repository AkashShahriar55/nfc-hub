package com.cheqplease.nfchub

import android.app.Activity
import android.content.Context
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.IsoDep
import android.nfc.tech.MifareClassic
import android.nfc.tech.NfcA
import android.nfc.tech.NfcB
import android.nfc.tech.NfcF
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/** Owns reader mode, a handle->Tag map, and lazy per-tag tech connections.
 *  All identity extraction happens here (from the Tag, no connect()); all
 *  parsing/identification happens in Dart. */
class NfcReaderModeController(
    private val context: Context
) : NfcAdapter.ReaderCallback {

    private var sink: EventChannel.EventSink? = null

    fun setSink(sink: EventChannel.EventSink?) { this.sink = sink }

    private val adapter: NfcAdapter? = NfcAdapter.getDefaultAdapter(context)
    private val main = Handler(Looper.getMainLooper())
    private val tags = HashMap<Int, Tag>()
    private val connected = HashMap<Int, Any>() // handle -> connected tech
    private var nextHandle = 1
    private var activity: Activity? = null

    fun attachActivity(a: Activity?) { activity = a }

    fun nfcState(): String = when {
        adapter == null -> "noHardware"
        adapter.isEnabled -> "enabled"
        else -> "disabled"
    }

    fun startReaderMode() {
        val a = activity ?: return
        val flags = NfcAdapter.FLAG_READER_NFC_A or
            NfcAdapter.FLAG_READER_NFC_B or
            NfcAdapter.FLAG_READER_NFC_F or
            NfcAdapter.FLAG_READER_SKIP_NDEF_CHECK or
            NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
        adapter?.enableReaderMode(a, this, flags, null)
    }

    fun stopReaderMode() {
        val a = activity ?: return
        adapter?.disableReaderMode(a)
        closeAll()
    }

    override fun onTagDiscovered(tag: Tag) {
        val handle = synchronized(tags) { val h = nextHandle++; tags[h] = tag; h }
        val techList = tag.techList.toList()
        val map = HashMap<String, Any?>()
        map["type"] = "tagDiscovered"
        map["handle"] = handle
        map["techList"] = techList
        map["uid"] = tag.id
        NfcA.get(tag)?.let { map["atqa"] = it.atqa; map["sak"] = it.sak.toInt() }
        NfcB.get(tag)?.let {
            // ATQB reconstructed as 50 | PUPI(id) | AppData | ProtocolInfo
            map["atqb"] = byteArrayOf(0x50) + tag.id + it.applicationData + it.protocolInfo
        }
        NfcF.get(tag)?.let { map["idm"] = tag.id; map["pmm"] = it.manufacturer }
        IsoDep.get(tag)?.let { map["historicalBytes"] = it.historicalBytes ?: it.hiLayerResponse }
        main.post { sink?.success(map) }
    }

    /** Lazily connects the requested tech and transceives. Throws to the
     *  MethodChannel Result as code TAG_LOST when the tag has left. */
    fun transceive(handle: Int, tech: String, data: ByteArray): ByteArray {
        val tag = synchronized(tags) { tags[handle] }
            ?: throw TagGoneException("Unknown or lost tag handle $handle")
        return try {
            when (tech) {
                "NfcA" -> connectNfcA(handle, tag).transceive(data)
                "NfcB" -> connectNfcB(handle, tag).transceive(data)
                "NfcF" -> connectNfcF(handle, tag).transceive(data)
                "IsoDep" -> connectIsoDep(handle, tag).transceive(data)
                else -> throw IllegalArgumentException("Unknown tech $tech")
            }
        } catch (e: java.io.IOException) {
            close(handle)
            throw TagGoneException("Tag lost during transceive: ${e.message}")
        }
    }

    /** Wrong-key rejection returns false from the platform API (that's a normal
     *  MIFARE_AUTH_FAILED outcome); only tag-loss (IOException/TagLostException,
     *  thrown by connect()/authenticateSectorWithKeyA/B) becomes TAG_LOST. */
    fun mifareAuthenticate(handle: Int, sector: Int, keyA: Boolean, key: ByteArray): Boolean {
        val tag = synchronized(tags) { tags[handle] }
            ?: throw TagGoneException("Unknown or lost tag handle $handle")
        return try {
            val mc = connectMifare(handle, tag)
            if (keyA) mc.authenticateSectorWithKeyA(sector, key)
            else mc.authenticateSectorWithKeyB(sector, key)
        } catch (e: java.io.IOException) {
            close(handle)
            throw TagGoneException("Tag lost during MIFARE auth: ${e.message}")
        }
    }

    fun mifareReadBlock(handle: Int, block: Int): ByteArray {
        val tag = synchronized(tags) { tags[handle] }
            ?: throw TagGoneException("Unknown or lost tag handle $handle")
        return try {
            connectMifare(handle, tag).readBlock(block)
        } catch (e: java.io.IOException) {
            close(handle)
            throw TagGoneException("Tag lost during MIFARE read: ${e.message}")
        }
    }

    private fun connectNfcA(h: Int, tag: Tag): NfcA =
        (connected[h] as? NfcA) ?: NfcA.get(tag).also { it.connect(); connected[h] = it }
    private fun connectNfcB(h: Int, tag: Tag): NfcB =
        (connected[h] as? NfcB) ?: NfcB.get(tag).also { it.connect(); connected[h] = it }
    private fun connectNfcF(h: Int, tag: Tag): NfcF =
        (connected[h] as? NfcF) ?: NfcF.get(tag).also { it.connect(); connected[h] = it }
    private fun connectIsoDep(h: Int, tag: Tag): IsoDep =
        (connected[h] as? IsoDep) ?: IsoDep.get(tag).also { it.connect(); connected[h] = it }
    private fun connectMifare(h: Int, tag: Tag): MifareClassic =
        (connected[h] as? MifareClassic) ?: MifareClassic.get(tag).also { it.connect(); connected[h] = it }

    private fun close(handle: Int) {
        synchronized(tags) { tags.remove(handle) }
        (connected.remove(handle) as? android.nfc.tech.TagTechnology)?.let {
            try { it.close() } catch (_: Exception) {}
        }
    }
    private fun closeAll() {
        synchronized(tags) { tags.keys.toList() }.forEach { close(it) }
    }
}

class TagGoneException(message: String) : Exception(message)
