import 'dart:math' as math;
import '../models/enums.dart';

/// Monthly peak sun hours (kWh/m2/day) for Nigerian cities.
///
/// SOURCE: NASA POWER (Prediction Of Worldwide Energy Resources), parameter
/// ALLSKY_SFC_SW_DWN — all-sky surface shortwave downward irradiance,
/// Renewable Energy community, long-term monthly climatology. Retrieved
/// July 2026 from https://power.larc.nasa.gov/ for each city-centre
/// coordinate below. The figures are kWh/m2/day, which is numerically the
/// same as peak sun hours.
///
/// These are GLOBAL HORIZONTAL irradiance (GHI). At Nigeria's low latitudes a
/// fixed array tilted to latitude gains only a little over the horizontal, so
/// designing on GHI is slightly conservative; the residual tilt/orientation
/// deviation is carried separately by the orientation factor in the derate
/// model, not here. Swap for a tilted (plane-of-array) series only if you also
/// remove that orientation factor, or the tilt gain is double-counted.
///
/// CED R08-002 §2.5 and §8.3(d): a standalone system must be designed for
/// "the month of the lowest average daily solar radiation during the
/// operational period", not the annual mean. In Lagos the worst month is
/// July at 3.8 against an annual average of 4.6 — a system sized on the
/// average browns out through the rainy season.
///
/// City-centre coordinates used (lat, lon), for reproducibility:
///   Lagos 6.52,3.38 · Ibadan 7.38,3.95 · Abeokuta 7.15,3.36 ·
///   Benin City 6.34,5.60 · Port Harcourt 4.82,7.05 · Calabar 4.96,8.33 ·
///   Enugu 6.46,7.55 · Abuja 9.06,7.50 · Jos 9.90,8.86 · Ilorin 8.48,4.54 ·
///   Kaduna 10.51,7.42 · Kano 12.00,8.59 · Sokoto 13.01,5.25 ·
///   Maiduguri 11.83,13.15 · Yola 9.20,12.50
const Map<String, List<double>> monthlyPsh = {
  //                Jan  Feb  Mar  Apr  May  Jun  Jul  Aug  Sep  Oct  Nov  Dec
  'Lagos':         [4.9, 4.8, 5.0, 5.0, 4.7, 3.9, 3.8, 4.1, 4.2, 4.7, 5.0, 5.0],
  'Ibadan':        [4.9, 4.8, 5.0, 5.1, 5.0, 4.5, 3.8, 3.6, 4.1, 4.7, 5.1, 4.9],
  'Abeokuta':      [4.9, 4.8, 5.0, 5.1, 5.0, 4.5, 3.8, 3.6, 4.1, 4.7, 5.1, 4.9],
  'Benin City':    [4.9, 4.6, 4.7, 4.8, 4.7, 4.2, 3.7, 3.7, 3.9, 4.4, 4.9, 4.9],
  'Port Harcourt': [4.8, 4.7, 4.4, 4.5, 4.3, 3.5, 3.2, 3.4, 3.6, 4.0, 4.3, 4.7],
  'Calabar':       [5.0, 4.8, 4.5, 4.6, 4.4, 3.7, 3.2, 3.1, 3.5, 4.0, 4.4, 4.9],
  'Enugu':         [5.2, 4.9, 5.0, 5.0, 4.9, 4.5, 4.0, 3.9, 4.2, 4.7, 5.1, 5.2],
  'Abuja':         [5.5, 5.6, 5.9, 5.8, 5.5, 5.0, 4.5, 4.1, 4.8, 5.4, 5.8, 5.6],
  'Jos':           [5.7, 5.7, 6.0, 5.8, 5.4, 5.0, 4.5, 4.1, 4.8, 5.4, 5.9, 5.7],
  'Ilorin':        [5.2, 5.3, 5.6, 5.6, 5.3, 4.9, 4.3, 4.0, 4.5, 5.0, 5.4, 5.2],
  'Kaduna':        [5.7, 5.9, 6.2, 6.2, 5.9, 5.5, 5.0, 4.6, 5.3, 5.7, 6.0, 5.7],
  'Kano':          [5.5, 5.9, 6.3, 6.6, 6.5, 6.2, 5.8, 5.6, 6.1, 6.1, 5.9, 5.5],
  'Sokoto':        [5.6, 6.1, 6.4, 6.5, 6.3, 6.1, 5.9, 5.6, 6.1, 6.1, 5.8, 5.5],
  'Maiduguri':     [5.9, 6.3, 6.6, 6.6, 6.3, 5.8, 5.4, 5.1, 5.7, 6.0, 6.1, 5.8],
  'Yola':          [5.9, 6.0, 6.3, 6.2, 5.9, 5.6, 5.1, 4.7, 5.2, 5.8, 6.0, 5.8],
};

const List<String> monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// Cities available for selection, alphabetical.
List<String> get availableCities {
  final list = monthlyPsh.keys.toList()..sort();
  return list;
}

/// Fallback for a city not in the table.
const String fallbackCity = 'Lagos';

List<double> _series(String city) => monthlyPsh[city] ?? monthlyPsh[fallbackCity]!;

/// The PSH figure to design against.
double resolvePsh(String city, PshMode mode) {
  final m = _series(city);
  if (mode == PshMode.worstMonth) {
    return m.reduce(math.min);
  }
  return m.reduce((a, b) => a + b) / m.length;
}

double worstMonthPsh(String city) => _series(city).reduce(math.min);

double annualAveragePsh(String city) {
  final m = _series(city);
  return m.reduce((a, b) => a + b) / m.length;
}

double bestMonthPsh(String city) => _series(city).reduce(math.max);

/// Name of the design month, for the report and the results screen.
String worstMonthName(String city) {
  final m = _series(city);
  var idx = 0;
  for (var i = 1; i < m.length; i++) {
    if (m[i] < m[idx]) idx = i;
  }
  return monthNames[idx];
}

/// Full twelve-month series, for charting.
List<double> pshSeries(String city) => List<double>.from(_series(city));
