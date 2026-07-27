package com.cheqplease.nfchub

import android.hardware.usb.UsbDeviceConnection
import android.hardware.usb.UsbEndpoint

class Ccid(
    private val usbDeviceConnection: UsbDeviceConnection,
    private val bulkIn: UsbEndpoint,
    private val bulkOut: UsbEndpoint
) {
    private var currentSeq = 0.toByte()

    /// Releases the underlying USB device connection (and any claimed
    /// interface). Call on disconnect so the card's session doesn't leak.
    fun close() {
        NfcHubLog.v("Ccid.close(): releasing USB device connection")
        usbDeviceConnection.close()
    }

    fun iccPowerOn(): ByteArray {
        val seq = currentSeq++
        val command = byteArrayOf(
            MESSAGE_TYPE_PC_TO_RDR_ICCPOWERON,
            0x00, 0x00, 0x00, 0x00,
            0x00,
            seq,
            0x00, // Auto voltage selection
            0x00, 0x00
        )
        NfcHubLog.v("iccPowerOn: seq=$seq")
        sendCcidPcToRdrMessage(command)
        val response = receiveCcidRdrToPcMessage(seq)
        NfcHubLog.v("iccPowerOn: seq=$seq -> ATR ${response.data.toLogHex()}")
        return response.data
    }

    fun iccPowerOff() {
        val seq = currentSeq++
        val command = byteArrayOf(
            MESSAGE_TYPE_PC_TO_RDR_ICCPOWEROFF,
            0x00, 0x00, 0x00, 0x00,
            0x00,
            seq,
            0x00, 0x00, 0x00
        )
        sendCcidPcToRdrMessage(command)
    }

    fun xfrBlock(apdu: ByteArray): ByteArray {
        val seq = currentSeq++
        val command = byteArrayOf(
            MESSAGE_TYPE_PC_TO_RDR_XFRBLOCK,
            apdu.size.toByte(),
            (apdu.size shr 8).toByte(),
            (apdu.size shr 16).toByte(),
            (apdu.size shr 24).toByte(),
            0x00,
            seq,
            0x00,
            0x00,
            0x00
        )
        val data = command + apdu

        NfcHubLog.v("xfrBlock: seq=$seq capdu=${apdu.toLogHex()} (${apdu.size}B)")
        var bytesSent = 0
        while (bytesSent < data.size) {
            val chunkSize = minOf(data.size - bytesSent, bulkOut.maxPacketSize)
            val chunk = data.copyOfRange(bytesSent, bytesSent + chunkSize)
            sendCcidPcToRdrMessage(chunk)
            bytesSent += chunkSize
        }

        val response = receiveCcidRdrToPcMessage(seq).data
        NfcHubLog.v("xfrBlock: seq=$seq -> rapdu=${response.toLogHex()} (${response.size}B)")
        return response
    }


    fun getDescriptor(interfaceIdx: Int): CcidDescriptor? {
        val rawDescriptors = usbDeviceConnection.rawDescriptors
        if (rawDescriptors == null) {
            NfcHubLog.e("getDescriptor($interfaceIdx): rawDescriptors is null")
            return null
        }
        NfcHubLog.v("getDescriptor($interfaceIdx): walking ${rawDescriptors.size}B of raw descriptors")
        var byteIndex = 0
        var currInterfaceNumber = 0

        while (byteIndex + 1 < rawDescriptors.size) {
            val descriptorLength = rawDescriptors[byteIndex].toInt() and 0xff
            val descriptorType = rawDescriptors[byteIndex + 1].toInt() and 0xff
            // A zero bLength would advance byteIndex by 0 and spin this loop
            // forever -- on the single-threaded ccidExecutor that wedges EVERY
            // later CCID call (connect/transceive/disconnect) with no error and
            // no completed Result, which reads as "the reader just stopped
            // responding". Bail out loudly instead.
            if (descriptorLength == 0) {
                NfcHubLog.e(
                    "getDescriptor($interfaceIdx): zero-length descriptor at offset " +
                            "$byteIndex -- aborting walk (malformed descriptor table)"
                )
                return null
            }

            // Check if it's an interface descriptor
            if (descriptorType == 0x04) {
                currInterfaceNumber = rawDescriptors[byteIndex + 2].toInt() and 0xff
                NfcHubLog.v("  descriptor@$byteIndex: INTERFACE #$currInterfaceNumber")
            }
            // Check if it's a CCID class descriptor and the interface number matches
            else if (descriptorType == 0x21 && currInterfaceNumber == interfaceIdx) {
                val dwProtocols = (rawDescriptors[byteIndex + 6].toInt() and 0xff) or
                        ((rawDescriptors[byteIndex + 7].toInt() and 0xff) shl 8) or
                        ((rawDescriptors[byteIndex + 8].toInt() and 0xff) shl 16) or
                        ((rawDescriptors[byteIndex + 9].toInt() and 0xff) shl 24)
                val dwFeatures = (rawDescriptors[byteIndex + 40].toInt() and 0xff) or
                        ((rawDescriptors[byteIndex + 41].toInt() and 0xff) shl 8) or
                        ((rawDescriptors[byteIndex + 42].toInt() and 0xff) shl 16) or
                        ((rawDescriptors[byteIndex + 43].toInt() and 0xff) shl 24)
                val dwMaxIFSD = (rawDescriptors[byteIndex + 28].toInt() and 0xff) or
                        ((rawDescriptors[byteIndex + 29].toInt() and 0xff) shl 8) or
                        ((rawDescriptors[byteIndex + 30].toInt() and 0xff) shl 16) or
                        ((rawDescriptors[byteIndex + 31].toInt() and 0xff) shl 24)
                // Per-tick: the poll loop re-reads the descriptor on every
                // connect attempt, and it never changes for a given reader.
                NfcHubLog.v(
                    "getDescriptor($interfaceIdx): CCID class descriptor @$byteIndex " +
                            "dwProtocols=0x%08X dwFeatures=0x%08X dwMaxIFSD=%d"
                                .format(dwProtocols, dwFeatures, dwMaxIFSD)
                )
                val levelOfExchange = when ((dwFeatures shr 16) and 0xFF) {
                    0x01 -> LevelOfExchange.TPDU
                    0x02 -> LevelOfExchange.ShortAPDU
                    0x04 -> LevelOfExchange.ExtendedAPDU
                    else -> {
                        NfcHubLog.e(
                            "getDescriptor($interfaceIdx): unknown level of exchange " +
                                    "0x%02X (from dwFeatures 0x%08X)"
                                        .format((dwFeatures shr 16) and 0xFF, dwFeatures)
                        )
                        throw CcidException("Unknown level of exchange")
                    }
                }
                NfcHubLog.v(
                    "getDescriptor($interfaceIdx): levelOfExchange=$levelOfExchange " +
                            "protocols byte=0x%02X (T0=%b T1=%b)".format(
                                dwProtocols.toByte().toInt() and 0xff,
                                (dwProtocols and Protocol.T0.value) > 0,
                                (dwProtocols and Protocol.T1.value) > 0
                            )
                )
                return CcidDescriptor(dwProtocols.toByte(), levelOfExchange, dwMaxIFSD)
            }

            byteIndex += descriptorLength
        }

        NfcHubLog.e(
            "getDescriptor($interfaceIdx): no CCID class descriptor (0x21) found for " +
                    "interface $interfaceIdx in ${rawDescriptors.size}B of descriptors"
        )
        return null
    }

    private fun sendCcidPcToRdrMessage(message: ByteArray) {
        NfcHubLog.v("  usb tx -> ${message.toLogHex()} (${message.size}B)")
        val transmitted = usbDeviceConnection.bulkTransfer(bulkOut, message, message.size, 1000)
        if (transmitted != message.size) {
            NfcHubLog.e("  usb tx FAILED: bulkTransfer returned $transmitted of ${message.size}B")
            throw CcidException("Failed to transmit data ($transmitted / ${message.size})")
        }
    }

    private fun receiveCcidRdrToPcMessage(expectedSeq: Byte): CcidRdrToPcMessage {
        var message: CcidRdrToPcMessage
        do {
            message = receiveRawMessage(expectedSeq)
        } while (message.isStatusTimeoutExtensionRequest)

        if (!message.isStatusSuccess) {
            NfcHubLog.d(
                "  rdr->pc NOT SUCCESS: bStatus=0x%02X bError=0x%02X iccStatus=%d (%s) cmdStatus=%d (%s)"
                    .format(
                        message.status.toInt() and 0xff,
                        message.error.toInt() and 0xff,
                        message.iccStatus,
                        iccStatusLabel(message.iccStatus),
                        message.commandStatus,
                        commandStatusLabel(message.commandStatus)
                    )
            )
            throw CcidException("Card error: ${message.iccStatus}")
        }

        return message
    }

    private fun receiveRawMessage(expectedSeq: Byte): CcidRdrToPcMessage {
        var retries = 3
        var bytesRead = 0
        var message: CcidRdrToPcMessage? = null
        val buffer = ByteArray(bulkIn.maxPacketSize)
        var lastException: CcidException? = null
        while (retries > 0) {
            try {
                bytesRead = usbDeviceConnection.bulkTransfer(bulkIn, buffer, buffer.size, USB_TIMEOUT)
                if (bytesRead <= 0) {
                    // -1 here after the full USB_TIMEOUT is the classic "reader
                    // never answered" signature: the command went out but nothing
                    // came back on the bulk-IN endpoint.
                    throw CcidException("Failed to read data (bulkTransfer returned $bytesRead)")
                }
                NfcHubLog.v(
                    "  usb rx <- ${buffer.copyOf(bytesRead).toLogHex()} (${bytesRead}B)"
                )
                if (bytesRead < HEADER_SIZE) {
                    throw CcidException("Incorrect header (only ${bytesRead}B, need $HEADER_SIZE)")
                }
                if (buffer[0] != MESSAGE_TYPE_RDR_TO_PC_DATABLOCK) {
                    throw CcidException(
                        "Unexpected message type 0x%02X (expected 0x%02X RDR_to_PC_DataBlock)"
                            .format(buffer[0].toInt() and 0xff, MESSAGE_TYPE_RDR_TO_PC_DATABLOCK.toInt() and 0xff)
                    )
                }
                message = CcidRdrToPcMessage.parseHeader(buffer)
                NfcHubLog.v(
                    "  rdr->pc header: type=0x%02X len=%d slot=%d seq=%d bStatus=0x%02X bError=0x%02X icc=%d cmd=%d"
                        .format(
                            message.messageType.toInt() and 0xff,
                            message.length,
                            message.slot.toInt() and 0xff,
                            message.seq.toInt() and 0xff,
                            message.status.toInt() and 0xff,
                            message.error.toInt() and 0xff,
                            message.iccStatus,
                            message.commandStatus
                        )
                )
                if (message.seq != expectedSeq) {
                    throw CcidException("Unexpected sequence number ${message.seq}, expected $expectedSeq")
                }
                lastException = null
                break
            } catch (e: CcidException) {
                lastException = e
                retries--
                NfcHubLog.v("  rdr->pc read failed (${e.message}) -- $retries retry/retries left")
                if (retries > 0) {
                    Thread.sleep(100)
                }
            }
        }

        if (lastException != null) {
            throw lastException
        }

        val dataBuffer = ByteArray(message!!.length)
        var bytesBuffered = bytesRead - HEADER_SIZE
        System.arraycopy(buffer, HEADER_SIZE, dataBuffer, 0, bytesBuffered)

        while (bytesBuffered < message.length) {
            bytesRead = usbDeviceConnection.bulkTransfer(bulkIn, buffer, buffer.size, USB_TIMEOUT)
            NfcHubLog.v(
                "  usb rx (cont) <- ${bytesRead}B, $bytesBuffered/${message.length} buffered"
            )
            if (bytesRead <= 0) {
                throw CcidException(
                    "Failed to read continuation data (bulkTransfer returned $bytesRead " +
                            "at $bytesBuffered/${message.length}B)"
                )
            }
            System.arraycopy(buffer, 0, dataBuffer, bytesBuffered, bytesRead)
            bytesBuffered += bytesRead
        }

        return message.withData(dataBuffer)
    }

    companion object {
        private const val HEADER_SIZE = 10
        private const val USB_TIMEOUT = 5000

        private const val MESSAGE_TYPE_PC_TO_RDR_ICCPOWERON = 0x62.toByte()
        private const val MESSAGE_TYPE_PC_TO_RDR_ICCPOWEROFF = 0x63.toByte()
        private const val MESSAGE_TYPE_PC_TO_RDR_XFRBLOCK = 0x6F.toByte()
        private const val MESSAGE_TYPE_RDR_TO_PC_DATABLOCK = 0x80.toByte()
    }
}

class CcidException(message: String) : Exception(message)

data class CcidRdrToPcMessage(
    val messageType: Byte,
    val length: Int,
    val slot: Byte,
    val seq: Byte,
    val status: Byte,
    val error: Byte,
    val specific: Byte,
    val data: ByteArray
) {
    fun withData(data: ByteArray): CcidRdrToPcMessage {
        return CcidRdrToPcMessage(
            messageType,
            length,
            slot,
            seq,
            status,
            error,
            specific,
            data
        )
    }

    val iccStatus: Int
        get() = status.toInt() and 0x03

    val commandStatus: Int
        get() = (status.toInt() shr 6) and 0x03

    val isStatusTimeoutExtensionRequest: Boolean
        get() = commandStatus == 0x02

    val isStatusSuccess: Boolean
        get() = commandStatus == 0x00 && iccStatus == 0x00

    companion object {
        fun parseHeader(data: ByteArray): CcidRdrToPcMessage {
            return CcidRdrToPcMessage(
                data[0],
                (data[1].toInt() and 0xff) or ((data[2].toInt() and 0xff) shl 8) or ((data[3].toInt() and 0xff) shl 16) or ((data[4].toInt() and 0xff) shl 24),
                data[5],
                data[6],
                data[7],
                data[8],
                data[9],
                byteArrayOf()
            )
        }
    }
}
