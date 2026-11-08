import 'dart:typed_data';

import 'package:nfc_hub/nfc_hub.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [NfcFTransport] that records every frame handed to [transceive] and
/// returns a scripted response for it, keyed by the request frame's hex.
///
/// The driver sits above the reader-dialect layer (PN532 InDataExchange
/// wrapping / `D5 41 <status>` header stripping), which now lives in
/// `CcidTransportBackend` (see `lib/src/transport/ccid_backend.dart`). So
/// unlike the old fixtures (raw response frames WITH the `D5 41 00`
/// InDataExchange prefix), these fixtures are the bare FeliCa response
/// frame the backend would have already unwrapped for the driver.
class _FakeNfcFTransport implements NfcFTransport {
  final Uint8List _idm;
  final Uint8List? _pmm;
  final Map<String, Uint8List> responses;
  final List<Uint8List> requestedFrames = [];

  _FakeNfcFTransport(this._idm,
      {Uint8List? pmm, Map<String, Uint8List> responses = const {}})
      : _pmm = pmm,
        responses = responses.map((k, v) => MapEntry(k.toLowerCase(), v));

  @override
  Future<Uint8List> get idm async => _idm;

  @override
  Future<Uint8List> get pmm async {
    final pmm = _pmm;
    if (pmm == null) {
      throw Exception('no fake pmm configured');
    }
    return pmm;
  }

  @override
  Future<Uint8List> transceive(Uint8List felicaFrame) async {
    requestedFrames.add(felicaFrame);
    final key = hex.encode(felicaFrame).toLowerCase();
    final response = responses[key];
    if (response == null) {
      throw Exception('No fake response configured for frame: $key');
    }
    return response;
  }
}

void main() {
  const idmHex = 'AABBCCDDEE001122';
  final idmBytes =
      Uint8List.fromList([0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0x00, 0x11, 0x22]);

  test('idm returns the transport-supplied IDm', () async {
    final transport = _FakeNfcFTransport(idmBytes);
    final tag = FelicaTag(transport);

    final idm = await tag.idm;

    expect(idm, equals(idmBytes));
  });

  test('pmm returns the transport-supplied PMm', () async {
    const pmmHex = '0135428282468CFF';
    final transport = _FakeNfcFTransport(idmBytes,
        pmm: Uint8List.fromList(hex.decode(pmmHex)));
    final tag = FelicaTag(transport);

    final pmm = await tag.pmm;

    expect(pmm, equals(hex.decode(pmmHex)));
  });

  test(
      'readWithoutEncryption() sends the FeliCa read frame and parses a '
      'successful response', () async {
    // Read command frame: cmd=06, idm(8), numServices=01,
    // serviceCode LE (0F22 for 0x220F), numBlocks=01,
    // blockListElement(80,00). Byte layout verified against ACS's ACR122U
    // NFC Reader API, section 7.3 worked example.
    const readFrameHex = '06${idmHex}010F22018000';
    // FeliCa response frame (the D5 41 00 InDataExchange prefix has already
    // been stripped by the backend by the time the driver sees this):
    // len=1D, respCode=07, idm(8), SF1=00, SF2=00, numBlocks=01,
    // block(16 bytes of 0xAA).
    const readResponseHex = '1D07${idmHex}000001'
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    final transport = _FakeNfcFTransport(idmBytes, responses: {
      readFrameHex: Uint8List.fromList(hex.decode(readResponseHex)),
    });
    final tag = FelicaTag(transport);

    final result = await tag.readWithoutEncryption(0x220F, [0]);

    expect(result.isSuccess, isTrue);
    expect(result.blocks, hasLength(1));
    expect(result.blocks[0], equals(List.filled(16, 0xAA)));
    expect(
      transport.requestedFrames.map(hex.encode),
      contains(readFrameHex.toLowerCase()),
    );
  });

  test('readWithoutEncryption() throws when the response frame is too short',
      () async {
    const readFrameHex = '06${idmHex}010F22018000';
    // Fewer than 12 bytes -- violates the response.length < 12 guard.
    const readResponseHex = '0507$idmHex';
    final transport = _FakeNfcFTransport(idmBytes, responses: {
      readFrameHex: Uint8List.fromList(hex.decode(readResponseHex)),
    });
    final tag = FelicaTag(transport);

    expect(
      () => tag.readWithoutEncryption(0x220F, [0]),
      throwsException,
    );
  });

  test('requestSystemCodes() enumerates every system on the card', () async {
    const requestFrameHex = '0C$idmHex';
    // Response frame: len=0F (15 bytes: len+respCode+idm(8)+numSystems+
    // 2 system codes), respCode=0D, idm(8), numSystems=02,
    // systemCode0=0003, systemCode1=90E3.
    const requestResponseHex = '0F0D${idmHex}02000390E3';
    final transport = _FakeNfcFTransport(idmBytes, responses: {
      requestFrameHex: Uint8List.fromList(hex.decode(requestResponseHex)),
    });
    final tag = FelicaTag(transport);

    final systemCodes = await tag.requestSystemCodes();

    expect(systemCodes, equals([0x0003, 0x90E3]));
  });

  test('readTagInfo() combines idm, pmm-derived model, and system codes',
      () async {
    // ROM Type 0x03, IC Type 0x35 -> RC-SA01/2 (the confirmed Dhaka MRT
    // chip -- see felica_info_test.dart).
    const pmmHex = '0335428282468CFF';
    const requestFrameHex = '0C$idmHex';
    // 1 system code (90E3): len=0D (13 bytes: len+respCode+idm(8)+
    // numSystems+1 system code).
    const requestResponseHex = '0D' '0D' '$idmHex' '01' '90E3';
    final transport = _FakeNfcFTransport(
      idmBytes,
      pmm: Uint8List.fromList(hex.decode(pmmHex)),
      responses: {
        requestFrameHex: Uint8List.fromList(hex.decode(requestResponseHex)),
      },
    );
    final tag = FelicaTag(transport);

    final info = await tag.readTagInfo();

    expect(info.technology, equals('FeliCa (RC-SA01/2)'));
    expect(info.systemCodes, equals([0x90E3]));
  });

  test(
      "readTagInfo()'s systemCodes stay empty when requestSystemCodes() "
      'fails (best-effort)', () async {
    const pmmHex = '0335428282468CFF';
    final transport = _FakeNfcFTransport(
      idmBytes,
      pmm: Uint8List.fromList(hex.decode(pmmHex)),
      // No response configured for the Request System Code frame -> the
      // fake throws, which readTagInfo() must swallow.
    );
    final tag = FelicaTag(transport);

    final info = await tag.readTagInfo();

    expect(info.technology, equals('FeliCa (RC-SA01/2)'));
    expect(info.systemCodes, isEmpty);
    expect(info.atr, isNull);
  });
}
