import 'package:shared_preferences/shared_preferences.dart';

/// Serwis do zapisywania i wczytywania ustawień kalibracji
class CalibrationSettingsService {
  static const String _userMinKey = 'calib_user_min';
  static const String _userMaxKey = 'calib_user_max';
  static const String _deadZoneKey = 'calib_dead_zone';
  static const String _baselinePercentKey = 'calib_baseline_percent';
  static const String _customRangeEnabledKey = 'calib_custom_range_enabled';

  /// Zapisz ustawienia użytkownika
  Future<void> saveUserSettings({
    double? userMin,
    double? userMax,
    required double deadZone,
    required double baselinePercent,
    required bool customRangeEnabled,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    
    if (userMin != null) {
      await prefs.setDouble(_userMinKey, userMin);
    } else {
      await prefs.remove(_userMinKey);
    }
    
    if (userMax != null) {
      await prefs.setDouble(_userMaxKey, userMax);
    } else {
      await prefs.remove(_userMaxKey);
    }
    
    await prefs.setDouble(_deadZoneKey, deadZone);
    await prefs.setDouble(_baselinePercentKey, baselinePercent);
    await prefs.setBool(_customRangeEnabledKey, customRangeEnabled);
    
    print('📝 Zapisano ustawienia kalibracji');
  }

  /// Wczytaj ustawienia użytkownika
  Future<CalibrationSettings> loadUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    return CalibrationSettings(
      userMin: prefs.getDouble(_userMinKey),
      userMax: prefs.getDouble(_userMaxKey),
      deadZone: prefs.getDouble(_deadZoneKey) ?? 0.3,
      baselinePercent: prefs.getDouble(_baselinePercentKey) ?? 20.0,
      customRangeEnabled: prefs.getBool(_customRangeEnabledKey) ?? false,
    );
  }

  /// Wyczyść zapisane ustawienia
  Future<void> clearUserSettings() async {
    final prefs = await SharedPreferences.getInstance();
    
    await prefs.remove(_userMinKey);
    await prefs.remove(_userMaxKey);
    await prefs.remove(_deadZoneKey);
    await prefs.remove(_baselinePercentKey);
    await prefs.remove(_customRangeEnabledKey);
    
    print('🗑️ Wyczyszczono ustawienia kalibracji');
  }
}

/// Klasa przechowująca ustawienia kalibracji
class CalibrationSettings {
  final double? userMin;
  final double? userMax;
  final double deadZone;
  final double baselinePercent;
  final bool customRangeEnabled;

  CalibrationSettings({
    this.userMin,
    this.userMax,
    required this.deadZone,
    required this.baselinePercent,
    required this.customRangeEnabled,
  });

  @override
  String toString() {
    return 'CalibrationSettings(userMin: $userMin, userMax: $userMax, '
           'deadZone: $deadZone, baselinePercent: $baselinePercent, '
           'customRangeEnabled: $customRangeEnabled)';
  }
}
