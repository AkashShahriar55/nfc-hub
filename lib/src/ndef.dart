import 'dart:convert';
import 'dart:typed_data';

/// A single NDEF record decoded from a tag's NDEF message.
class NdefRecord {
  /// Type Name Format, identifies how [type] should be interpreted.
  final int tnf;

  /// The record type (e.g. 'T' for Text, 'U' for URI).
  final Uint8List type;

  /// The record id, empty if not present.
  final Uint8List id;

  /// The raw record payload.
  final Uint8List payload;

  NdefRecord({
    required this.tnf,
    required this.type,
    required this.id,
    required this.payload,
  });

  static const int _tnfWellKnown = 0x01;

  static const List<String> _uriPrefixes = [
    '', // 0x00
    'http://www.', // 0x01
    'https://www.', // 0x02
    'http://', // 0x03
    'https://', // 0x04
    'tel:', // 0x05
    'mailto:', // 0x06
    'ftp://anonymous:anonymous@', // 0x07
    'ftp://ftp.', // 0x08
    'ftps://', // 0x09
    'sftp://', // 0x0A
    'smb://', // 0x0B
    'nfs://', // 0x0C
    'ftp://', // 0x0D
    'dav://', // 0x0E
    'news:', // 0x0F
    'telnet://', // 0x10
    'imap:', // 0x11
    'rtsp://', // 0x12
    'urn:', // 0x13
    'pop:', // 0x14
    'sip:', // 0x15
    'sips:', // 0x16
    'tftp:', // 0x17
    'btspp://', // 0x18
    'btl2cap://', // 0x19
    'btgoep://', // 0x1A
    'tcpobex://', // 0x1B
    'irdaobex://', // 0x1C
    'file://', // 0x1D
    'urn:epc:id:', // 0x1E
    'urn:epc:tag:', // 0x1F
    'urn:epc:pat:', // 0x20
    'urn:epc:raw:', // 0x21
    'urn:epc:', // 0x22
    'urn:nfc:', // 0x23
  ];

  /// The record [type] decoded as a UTF-8 string.
  String get typeString => utf8.decode(type, allowMalformed: true);

  /// Decodes this record as an NFC Forum well-known Text record ('T').
  ///
  /// Returns null if this is not a Text record.
  String? get asText {
    if (tnf != _tnfWellKnown || typeString != 'T' || payload.isEmpty) {
      return null;
    }
    final statusByte = payload[0];
    final isUtf16 = (statusByte & 0x80) != 0;
    final languageCodeLength = statusByte & 0x3F;
    final textStart = 1 + languageCodeLength;
    if (textStart > payload.length) return null;
    final textBytes = payload.sublist(textStart);
    if (!isUtf16) {
      return utf8.decode(textBytes, allowMalformed: true);
    }
    return _decodeUtf16(textBytes);
  }

  static String _decodeUtf16(Uint8List bytes) {
    var start = 0;
    var bigEndian = true;
    if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      start = 2;
    } else if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      bigEndian = false;
      start = 2;
    }
    final codeUnits = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      codeUnits.add(bigEndian
          ? (bytes[i] << 8) | bytes[i + 1]
          : (bytes[i + 1] << 8) | bytes[i]);
    }
    return String.fromCharCodes(codeUnits);
  }

  /// Decodes this record as an NFC Forum well-known URI record ('U').
  ///
  /// Returns null if this is not a URI record.
  String? get asUri {
    if (tnf != _tnfWellKnown || typeString != 'U' || payload.isEmpty) {
      return null;
    }
    final prefixCode = payload[0];
    final prefix =
        prefixCode < _uriPrefixes.length ? _uriPrefixes[prefixCode] : '';
    final suffix = utf8.decode(payload.sublist(1), allowMalformed: true);
    return '$prefix$suffix';
  }

  String _hex() =>
      payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() {
    final text = asText;
    if (text != null) return 'Text: $text';
    final uri = asUri;
    if (uri != null) return 'URI: $uri';
    return 'NdefRecord(tnf: $tnf, type: $typeString, payload: ${_hex()})';
  }
}

/// Scans [data] for TLV blocks (as used by NFC Forum Type 2 Tags) and
/// returns the value of the first NDEF Message TLV (tag 0x03), or null
/// if none is found.
Uint8List? parseTlvForNdefMessage(Uint8List data) {
  var i = 0;
  while (i < data.length) {
    final tag = data[i];
    if (tag == 0x00) {
      // NULL TLV: no length/value, skip.
      i += 1;
      continue;
    }
    if (tag == 0xFE) {
      // Terminator TLV.
      break;
    }
    if (i + 1 >= data.length) break;
    var length = data[i + 1];
    var valueStart = i + 2;
    if (length == 0xFF) {
      if (i + 3 >= data.length) break;
      length = (data[i + 2] << 8) | data[i + 3];
      valueStart = i + 4;
    }
    final valueEnd = valueStart + length;
    if (valueEnd > data.length) break;
    if (tag == 0x03) {
      return data.sublist(valueStart, valueEnd);
    }
    i = valueEnd;
  }
  return null;
}

/// Parses a raw NDEF message (the value of an NDEF Message TLV) into a
/// list of [NdefRecord]s.
///
/// Chunked records (the `CF` flag) are not supported — each physical
/// record in the message is returned as its own [NdefRecord] without
/// reassembling chunked payloads.
List<NdefRecord> parseNdefRecords(Uint8List message) {
  final records = <NdefRecord>[];
  var i = 0;
  while (i < message.length) {
    final flags = message[i];
    final sr = (flags & 0x10) != 0;
    final il = (flags & 0x08) != 0;
    final tnf = flags & 0x07;
    final me = (flags & 0x40) != 0;
    i += 1;

    if (i >= message.length) break;
    final typeLength = message[i];
    i += 1;

    int payloadLength;
    if (sr) {
      if (i >= message.length) break;
      payloadLength = message[i];
      i += 1;
    } else {
      if (i + 4 > message.length) break;
      payloadLength = (message[i] << 24) |
          (message[i + 1] << 16) |
          (message[i + 2] << 8) |
          message[i + 3];
      i += 4;
    }

    var idLength = 0;
    if (il) {
      if (i >= message.length) break;
      idLength = message[i];
      i += 1;
    }

    if (i + typeLength > message.length) break;
    final type = message.sublist(i, i + typeLength);
    i += typeLength;

    if (i + idLength > message.length) break;
    final id = message.sublist(i, i + idLength);
    i += idLength;

    if (i + payloadLength > message.length) break;
    final payload = message.sublist(i, i + payloadLength);
    i += payloadLength;

    records.add(NdefRecord(tnf: tnf, type: type, id: id, payload: payload));

    if (me) break;
  }
  return records;
}
