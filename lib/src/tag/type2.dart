import 'dart:typed_data';

import '../ndef.dart';
import '../transport/transport.dart';
import 'tag_driver.dart';
import 'tag_info.dart';

class Type2TagInfo implements TagInfo {
  @override
  final String technology;
  @override
  final Uint8List uid;
  @override
  final Uint8List? atr;
  final CapabilityContainer? capabilityContainer;

  const Type2TagInfo({
    required this.technology,
    required this.uid,
    required this.atr,
    required this.capabilityContainer,
  });
}

/// Driver for an NFC Forum Type 2 Tag (e.g. NTAG213/215/216, Mifare
/// Ultralight) connected through a contactless PC/SC reader.
class Type2Tag extends TagDriver {
  final Type2Transport transport;

  /// The card's ATR, where the source supplies one. Null on sources that
  /// have no ATR concept (the device's built-in NFC antenna).
  final Uint8List? atr;

  const Type2Tag(this.transport, {this.atr});

  /// Reads the NDEF message from the tag.
  ///
  /// Throws an [Exception] if the tag has no NDEF capability container or
  /// no NDEF message is found on it.
  Future<List<NdefRecord>> readNdef() async {
    final cc = await readCapabilityContainer();
    if (!cc.isNdefFormatted) {
      throw Exception(
          'Tag does not contain NDEF data (no capability container found)');
    }
    final data = await _readPagesFrom(4, maxBytes: cc.dataAreaSize);
    final message = parseTlvForNdefMessage(data);
    if (message == null) {
      throw Exception('No NDEF message found on tag');
    }
    return parseNdefRecords(message);
  }

  /// Reads the tag's UID via the standard PC/SC "Get Data" pseudo-APDU.
  Future<Uint8List> readUid() => transport.readUid();

  /// A generic identification summary: UID, ATR, and the Capability
  /// Container if the tag has one (best-effort -- a read failure here
  /// doesn't prevent returning the rest of the info).
  @override
  Future<Type2TagInfo> readTagInfo() async {
    final tagUid = await readUid();
    CapabilityContainer? cc;
    try {
      cc = await readCapabilityContainer();
    } catch (_) {
      // best-effort; leave cc null
    }
    return Type2TagInfo(
      technology: 'NFC Forum Type 2 (MIFARE Ultralight/NTAG)',
      uid: tagUid,
      atr: atr,
      capabilityContainer: cc,
    );
  }

  /// Reads and parses the tag's Capability Container (CC), normally found
  /// at page 3 of the tag's memory.
  Future<CapabilityContainer> readCapabilityContainer() async {
    return CapabilityContainer.parse(await transport.readCapabilityContainer());
  }

  /// Reads the tag's full raw memory, starting at page 0, until a page
  /// read fails or the page number would no longer fit in one byte.
  Future<Uint8List> readMemoryDump() => _readPagesFrom(0);

  /// Attempts to read the tag's chip identification via the NXP
  /// `GET_VERSION` (0x60) command.
  ///
  /// Returns `null` if the reader doesn't support this, the command fails,
  /// or the response isn't the expected 8 bytes, rather than throwing.
  Future<ChipVersion?> readChipVersion() async {
    final data = await transport.getVersion();
    return data == null ? null : ChipVersion.parse(data);
  }

  Future<Uint8List> _readPagesFrom(int startPage, {int? maxBytes}) async {
    final buffer = BytesBuilder();
    var page = startPage;
    while ((maxBytes == null || buffer.length < maxBytes) && page <= 0xFF) {
      Uint8List chunk;
      try {
        chunk = await transport.readPages(page);
      } catch (_) {
        break;
      }
      buffer.add(chunk);
      page += 4;
    }
    return buffer.toBytes();
  }
}
