import 'dart:typed_data';

class _FelicaChipEntry {
  final int? rom;
  final int ic;
  final String name;

  const _FelicaChipEntry(this.rom, this.ic, this.name);
}

/// Known FeliCa IC Code (PMm bytes 0-1: ROM Type, IC Type) -> chip model
/// mappings. **Community-sourced** (reverse-engineered by open-source
/// projects such as `nfcpy` and `kormax/felica-tool`) -- Sony does not
/// publish this table. Do not present results as officially authoritative.
const _felicaChips = <_FelicaChipEntry>[
  _FelicaChipEntry(0x01, 0x20, 'RC-S962 (FeliCa Standard)'),
  _FelicaChipEntry(0x03, 0x32, 'RC-SA00/1'),
  _FelicaChipEntry(0x03, 0x33, 'RC-SA00/2'),
  _FelicaChipEntry(0x03, 0x34, 'RC-SA01/1'),
  _FelicaChipEntry(0x03, 0x35, 'RC-SA01/2'),
  _FelicaChipEntry(0x01, 0x36, 'RC-SA04/1'),
  _FelicaChipEntry(null, 0x3E, 'RC-SA08'),
  _FelicaChipEntry(0x01, 0x44, 'RC-SA20/1'),
  _FelicaChipEntry(0x01, 0x46, 'RC-SA21/2'),
  _FelicaChipEntry(null, 0xF0, 'FeliCa Lite (RC-S965)'),
  _FelicaChipEntry(0x00, 0xF1, 'FeliCa Lite-S (RC-S966)'),
  _FelicaChipEntry(null, 0xE0, 'FeliCa Plug (RC-S926)'),
];

/// Resolves a chip model name from [pmm]'s IC Code bytes (`pmm[0]` = ROM
/// Type, `pmm[1]` = IC Type). Tries an exact `(rom, ic)` match first, then
/// falls back to an `ic`-only match for entries with no fixed ROM Type.
/// Returns `null` if [pmm] is too short or the IC code isn't recognized.
String? felicaModelName(Uint8List pmm) {
  if (pmm.length < 2) return null;
  final rom = pmm[0];
  final ic = pmm[1];
  for (final entry in _felicaChips) {
    if (entry.ic == ic && entry.rom == rom) return entry.name;
  }
  for (final entry in _felicaChips) {
    if (entry.ic == ic && entry.rom == null) return entry.name;
  }
  return null;
}

/// Known FeliCa System Code -> description mappings. **Community-sourced**
/// -- Sony does not publish a public System Code registry (codes are
/// privately assigned per issuer). Returns `null` for an unrecognized code.
const _systemCodeLabels = <int, String>{
  0x0003: 'Japan transit common area (Suica/PASMO/ICOCA/etc.)',
  0x8008: 'Octopus (Hong Kong)',
  0x86A7: 'Suica-family secondary system',
  0x88B4: 'FeliCa Lite/Lite-S native system',
  0x12FC: 'NFC Forum Type 3 Tag (NDEF)',
  0xFE00: 'FeliCa Networks common area (Edy/nanaco/WAON/etc.)',
  0x90E3: 'MRT_PASS (Dhaka MRT/RapidPass)',
  0xFFFF: 'Wildcard / unformatted',
};

/// Returns a readable name for [systemCode], or null if it is not recognized.
String? felicaSystemCodeLabel(int systemCode) => _systemCodeLabels[systemCode];
