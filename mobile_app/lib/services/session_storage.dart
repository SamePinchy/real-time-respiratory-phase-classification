import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/breath_data_model.dart';

class SessionStorageService {
  static const String _sessionsKey = 'saved_sessions';

  // Zapisz sesję
  Future<void> saveSession(BreathSession session) async {
    final prefs = await SharedPreferences.getInstance();
    
    // Pobierz istniejące sesje
    List<BreathSession> sessions = await getSavedSessions();
    
    // Dodaj nową sesję
    sessions.add(session);
    
    // Konwertuj do JSON i zapisz
    List<String> sessionsJson = sessions.map((s) => jsonEncode(_sessionToJson(s))).toList();
    await prefs.setStringList(_sessionsKey, sessionsJson);
  }

  // Pobierz wszystkie zapisane sesje
  Future<List<BreathSession>> getSavedSessions() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? sessionsJson = prefs.getStringList(_sessionsKey);
    
    if (sessionsJson == null) return [];
    
    return sessionsJson.map((jsonStr) {
      Map<String, dynamic> json = jsonDecode(jsonStr);
      return _sessionFromJson(json);
    }).toList();
  }

  // Usuń sesję
  Future<void> deleteSession(String sessionId) async {
    final prefs = await SharedPreferences.getInstance();
    List<BreathSession> sessions = await getSavedSessions();
    
    sessions.removeWhere((s) => s.id == sessionId);
    
    List<String> sessionsJson = sessions.map((s) => jsonEncode(_sessionToJson(s))).toList();
    await prefs.setStringList(_sessionsKey, sessionsJson);
  }

  // Wyczyść wszystkie sesje
  Future<void> clearAllSessions() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_sessionsKey);
  }

  Map<String, dynamic> _sessionToJson(BreathSession session) {
    return {
      'id': session.id,
      'startTime': session.startTime.toIso8601String(),
      'endTime': session.endTime?.toIso8601String(),
      'data': session.data.map((d) => d.toJson()).toList(),
      'phaseIndices': session.phaseIndices,
    };
  }

  BreathSession _sessionFromJson(Map<String, dynamic> json) {
    return BreathSession(
      id: json['id'],
      startTime: DateTime.parse(json['startTime']),
      endTime: json['endTime'] != null ? DateTime.parse(json['endTime']) : null,
      data: (json['data'] as List)
          .map((d) => BreathData.fromJson(d))
          .toList(),
      phaseIndices: json['phaseIndices'] != null
          ? List<int>.from(json['phaseIndices'] as List)
          : [],
    );
  }
}