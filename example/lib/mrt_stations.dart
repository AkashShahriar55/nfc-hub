/// Dhaka MRT (metro) and Hatirjheel Bus station codes, as used in FeliCa
/// transaction blocks under service code 0x220F. Ported from mrt-buddy's
/// StationService.
const Map<int, String> _stationNames = {
  10: 'Motijheel',
  20: 'Bangladesh Secretariat',
  25: 'Dhaka University',
  30: 'Shahbagh',
  35: 'Karwan Bazar',
  40: 'Farmgate',
  45: 'Bijoy Sarani',
  50: 'Agargaon',
  55: 'Shewrapara',
  60: 'Kazipara',
  65: 'Mirpur 10',
  70: 'Mirpur 11',
  75: 'Pallabi',
  80: 'Uttara South',
  85: 'Uttara Center',
  90: 'Uttara North',

  // Hatirjheel Bus Stations
  13: 'Mohanagar (HJ)',
  16: 'Rampura (HJ)',
  17: 'Badda (HJ)',
  19: 'Police Plaza (HJ)',
  28: 'FDC (HJ)',
};

/// Returns the station name for [code], or `'Unknown ($code)'` if it isn't
/// a recognized station.
String stationName(int code) => _stationNames[code] ?? 'Unknown ($code)';
