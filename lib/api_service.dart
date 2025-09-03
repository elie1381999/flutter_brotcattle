// lib/api_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show debugPrint;
import 'supabase_config.dart'; // must define SUPABASE_URL and SUPABASE_ANON_KEY

class ApiService {
  final String token;
  ApiService(this.token);

  // ---------------------------
  // Basic HTTP helpers
  // ---------------------------
  Future<http.Response> _get(String url, {Map<String, String>? headers}) =>
      http.get(Uri.parse(url), headers: headers);

  Future<http.Response> _post(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) => http.post(
    Uri.parse(url),
    headers: headers,
    body: body is String ? body : json.encode(body),
  );

  Future<http.Response> _patch(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) => http.patch(
    Uri.parse(url),
    headers: headers,
    body: body is String ? body : json.encode(body),
  );

  Future<http.Response> _delete(String url, {Map<String, String>? headers}) =>
      http.delete(Uri.parse(url), headers: headers);

  Map<String, String> _commonHeaders({
    bool jsonBody = false,
    bool preferRepresentation = false,
    String? preferResolution,
  }) {
    final headers = <String, String>{
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
    if (jsonBody) headers['Content-Type'] = 'application/json';
    if (preferRepresentation) {
      var pref = 'return=representation';
      if (preferResolution != null && preferResolution.isNotEmpty)
        pref += ',$preferResolution';
      headers['Prefer'] = pref;
    }
    return headers;
  }

  // ---------------------------
  // Small raw helper for fetching parsed JSON lists/maps
  // ---------------------------
  /// Performs a GET and returns parsed JSON (List or Map) or null on error
  Future<dynamic> httpGetParsed(String url) async {
    try {
      final resp = await _get(url, headers: _commonHeaders());
      debugPrint('httpGetParsed ${resp.statusCode} $url');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isEmpty) return null;
        return json.decode(resp.body);
      } else {
        debugPrint('httpGetParsed error: ${resp.statusCode} ${resp.body}');
        return null;
      }
    } catch (e) {
      debugPrint('httpGetParsed exception: $e');
      return null;
    }
  }

  // ---------------------------
  // JWT utilities (used for getUserFarmIds)
  // ---------------------------
  String _decodeBase64Url(String str) {
    var output = str.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 0:
        break;
      case 2:
        output += '==';
        break;
      case 3:
        output += '=';
        break;
      default:
        return '';
    }
    try {
      return utf8.decode(base64.decode(output));
    } catch (e) {
      debugPrint('base64 decode error: $e');
      return '';
    }
  }

  Map<String, dynamic> _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final payload = parts[1];
      final decoded = _decodeBase64Url(payload);
      final Map<String, dynamic> map = json.decode(decoded);
      return map;
    } catch (e) {
      debugPrint('JWT decode error: $e');
      return {};
    }
  }

  String getTelegramIdFromToken() {
    final p = _decodeJwtPayload(token);
    return (p['telegram_id'] ?? p['sub'])?.toString() ?? '';
  }

  bool isTokenExpired() {
    try {
      final p = _decodeJwtPayload(token);
      if (!p.containsKey('exp')) return true;
      final expNum = p['exp'];
      final expSec = expNum is int
          ? expNum
          : int.tryParse(expNum.toString()) ?? 0;
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= expSec;
    } catch (e) {
      debugPrint('isTokenExpired error: $e');
      return true;
    }
  }

  // ---------------------------
  // User / farm / animals helpers
  // ---------------------------
  Future<String?> fetchUserIdForTelegram(String telegramId) async {
    final url =
        '$SUPABASE_URL/rest/v1/app_users?select=id&telegram_id=eq.$telegramId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchUserId status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return null;
    final List data = json.decode(resp.body);
    if (data.isEmpty) return null;
    return (data.first['id'] ?? '').toString();
  }

  Future<List<String>> fetchOwnedFarmIds(String userId) async {
    final url = '$SUPABASE_URL/rest/v1/farms?select=id&owner_id=eq.$userId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchOwnedFarms status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data
        .map<String>((e) => (e['id'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<List<String>> fetchMemberFarmIds(String userId) async {
    final url =
        '$SUPABASE_URL/rest/v1/farm_members?select=farm_id&user_id=eq.$userId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint(
      'fetchMemberFarms status: ${resp.statusCode} body: ${resp.body}',
    );
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data
        .map<String>((e) => (e['farm_id'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<List<String>> getUserFarmIds() async {
    final telegramId = getTelegramIdFromToken();
    if (telegramId.isEmpty) throw Exception('Invalid token: no telegram_id');
    final userId = await fetchUserIdForTelegram(telegramId);
    if (userId == null || userId.isEmpty)
      throw Exception('No app user found for Telegram ID $telegramId');
    final owned = await fetchOwnedFarmIds(userId);
    final member = await fetchMemberFarmIds(userId);
    final set = <String>{...owned, ...member};
    return set.toList();
  }

  Future<List<Map<String, dynamic>>> fetchAnimalsForFarms(
    List<String> farmIds,
  ) async {
    if (farmIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=in.$encodedList&order=id';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchAnimalsForFarms status: ${resp.statusCode}');
    if (resp.statusCode != 200) {
      debugPrint('fetchAnimalsForFarms body: ${resp.body}');
      throw Exception('Failed to fetch animals: ${resp.statusCode}');
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(
      data.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  /// Convenience: fetch farms by ids and return map id -> name
  Future<Map<String, String>> fetchFarmsByIds(List<String> farmIds) async {
    final map = <String, String>{};
    if (farmIds.isEmpty) return map;
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url =
        '$SUPABASE_URL/rest/v1/farms?select=id,name&order=id&id=in.$encodedList';
    final parsed = await httpGetParsed(url);
    if (parsed is List) {
      for (final f in parsed) {
        try {
          final id = (f['id'] ?? '').toString();
          final name = (f['name'] ?? '').toString();
          if (id.isNotEmpty) map[id] = name;
        } catch (_) {}
      }
    }
    return map;
  }

  // ---------------------------
  // Animal CRUD
  // ---------------------------
  /// Create an animal. Returns the created record (representation) or null.
  Future<Map<String, dynamic>?> createAnimal(
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/animals';
    try {
      final resp = await _post(
        url,
        body: payload,
        headers: _commonHeaders(jsonBody: true, preferRepresentation: true),
      );
      debugPrint('createAnimal status: ${resp.statusCode} body: ${resp.body}');
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          resp.body.isNotEmpty) {
        // Supabase returns a list when posting an array — but single object is OK too.
        final decoded = json.decode(resp.body);
        if (decoded is List && decoded.isNotEmpty) {
          return Map<String, dynamic>.from(decoded.first as Map);
        } else if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (e) {
      debugPrint('createAnimal error: $e');
    }
    return null;
  }

  /// Update an animal identified by id. Returns the updated record or null.
  Future<Map<String, dynamic>?> updateAnimal(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/animals?id=eq.$id';
    try {
      final resp = await _patch(
        url,
        body: payload,
        headers: _commonHeaders(jsonBody: true, preferRepresentation: true),
      );
      debugPrint('updateAnimal status: ${resp.statusCode} body: ${resp.body}');
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          resp.body.isNotEmpty) {
        final decoded = json.decode(resp.body);
        if (decoded is List && decoded.isNotEmpty) {
          return Map<String, dynamic>.from(decoded.first as Map);
        } else if (decoded is Map) {
          return Map<String, dynamic>.from(decoded);
        }
      }
    } catch (e) {
      debugPrint('updateAnimal error: $e');
    }
    return null;
  }

  /// Delete an animal by id. Returns true on success.
  Future<bool> deleteAnimal(String id) async {
    final url = '$SUPABASE_URL/rest/v1/animals?id=eq.$id';
    try {
      final resp = await _delete(url, headers: _commonHeaders());
      debugPrint('deleteAnimal status: ${resp.statusCode} body: ${resp.body}');
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('deleteAnimal error: $e');
      return false;
    }
  }

  // ---------------------------
  // Milk CRUD operations (unchanged from your original)
  // ---------------------------
  Future<List<Map<String, dynamic>>> fetchMilkHistory({
    required List<String> animalIds,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    if (animalIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${animalIds.join(',')})');
    String url =
        '$SUPABASE_URL/rest/v1/milk_production?select=*&animal_id=in.$encodedList&order=date.desc';
    if (fromDate != null)
      url += '&date=gte.${fromDate.toIso8601String().split('T')[0]}';
    if (toDate != null)
      url += '&date=lte.${toDate.toIso8601String().split('T')[0]}';
    final resp = await _get(url, headers: _commonHeaders());
    if (resp.statusCode != 200) {
      throw Exception(
        'Failed to fetch milk history: ${resp.statusCode} ${resp.body}',
      );
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(
      data.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  // ---------------------------
  // Milk CRUD operations
  // ---------------------------

  /// Save single milk production entry; uses upsert to avoid unique-constraint failures.
  /// Returns map: { success: bool, statusCode, data (record or null), body, error? }
  Future<Map<String, dynamic>> saveMilkProduction({
    required String animalId,
    required String? farmId,
    required double quantity,
    required DateTime date,
    String entryType = 'per_cow',
    String? note,
    String? session, // optional session
  }) async {
    final payload = <String, dynamic>{
      'animal_id': animalId,
      'farm_id': farmId?.isNotEmpty == true ? farmId : null,
      'quantity': quantity,
      'date': date.toIso8601String().split('T')[0],
      'entry_type': entryType,
      'note': note,
      'source': 'web',
    };
    if (session != null && session.isNotEmpty) payload['session'] = session;

    // upsert on unique (animal_id,date,entry_type,session) - ensure DB constraint matches
    final url =
        '$SUPABASE_URL/rest/v1/milk_production?on_conflict=animal_id,date,entry_type,session';
    try {
      final resp = await _post(
        url,
        body: [payload],
        headers: _commonHeaders(
          jsonBody: true,
          preferRepresentation: true,
          preferResolution: 'merge-duplicates',
        ),
      );

      debugPrint(
        'saveMilkProduction status: ${resp.statusCode} body: ${resp.body}',
      );

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          try {
            final parsed = json.decode(resp.body);
            if (parsed is List && parsed.isNotEmpty) {
              final rec = Map<String, dynamic>.from(parsed.first as Map);
              return {
                'success': true,
                'statusCode': resp.statusCode,
                'data': rec,
                'body': resp.body,
              };
            } else if (parsed is Map) {
              return {
                'success': true,
                'statusCode': resp.statusCode,
                'data': Map<String, dynamic>.from(parsed),
                'body': resp.body,
              };
            }
          } catch (e) {
            debugPrint('saveMilkProduction parse error: $e');
          }
        }
        return {
          'success': true,
          'statusCode': resp.statusCode,
          'data': null,
          'body': resp.body.isNotEmpty ? resp.body : null,
        };
      }

      // On conflict (if DB unique constraint different) we return the failure so caller can decide
      return {
        'success': false,
        'statusCode': resp.statusCode,
        'data': null,
        'body': resp.body,
        'error': 'Server returned ${resp.statusCode}',
      };
    } catch (e, st) {
      debugPrint('saveMilkProduction error: $e\n$st');
      return {
        'success': false,
        'statusCode': -1,
        'data': null,
        'body': null,
        'error': e.toString(),
      };
    }
  }

  /// Bulk upsert (array POST) — returns created/updated records or null on failure
  Future<List<Map<String, dynamic>>?> saveMilkProductionBulk(
    List<Map<String, dynamic>> payloads,
  ) async {
    if (payloads.isEmpty) return [];
    final url =
        '$SUPABASE_URL/rest/v1/milk_production?on_conflict=animal_id,date,entry_type,session';
    try {
      final resp = await _post(
        url,
        body: payloads,
        headers: _commonHeaders(
          jsonBody: true,
          preferRepresentation: true,
          preferResolution: 'merge-duplicates',
        ),
      );
      debugPrint(
        'saveMilkProductionBulk status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          final List data = json.decode(resp.body);
          return data
              .map<Map<String, dynamic>>(
                (e) => Map<String, dynamic>.from(e as Map),
              )
              .toList();
        }
        return [];
      }
      debugPrint(
        'saveMilkProductionBulk unexpected response: ${resp.statusCode} ${resp.body}',
      );
      return null;
    } catch (e) {
      debugPrint('saveMilkProductionBulk error: $e');
      return null;
    }
  }

  /// Update milk entry and return updated record (or null)
  Future<Map<String, dynamic>?> updateMilkEntry(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await _patch(
        url,
        body: payload,
        headers: _commonHeaders(jsonBody: true, preferRepresentation: true),
      );
      debugPrint(
        'updateMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          final List data = json.decode(resp.body);
          if (data.isNotEmpty)
            return Map<String, dynamic>.from(data.first as Map);
        }
        return null;
      }
      debugPrint(
        'updateMilkEntry unexpected response: ${resp.statusCode} ${resp.body}',
      );
      return null;
    } catch (e) {
      debugPrint('updateMilkEntry error: $e');
      return null;
    }
  }

  /// Delete milk entry by id. Returns true if deleted.
  Future<bool> deleteMilkEntry(String id) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await _delete(url, headers: _commonHeaders());
      debugPrint(
        'deleteMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('deleteMilkEntry error: $e');
      return false;
    }
  }
}















/*
// lib/api_service.dart the best
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show debugPrint;
import 'supabase_config.dart'; // make sure this defines SUPABASE_URL and SUPABASE_ANON_KEY

class ApiService {
  final String token;
  ApiService(this.token);

  // ---------------------------
  // Basic HTTP helpers
  // ---------------------------
  Future<http.Response> _get(String url, {Map<String, String>? headers}) =>
      http.get(Uri.parse(url), headers: headers);

  Future<http.Response> _post(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) => http.post(
    Uri.parse(url),
    headers: headers,
    body: body is String ? body : json.encode(body),
  );

  Future<http.Response> _patch(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) => http.patch(
    Uri.parse(url),
    headers: headers,
    body: body is String ? body : json.encode(body),
  );

  Future<http.Response> _delete(String url, {Map<String, String>? headers}) =>
      http.delete(Uri.parse(url), headers: headers);

  Map<String, String> _commonHeaders({
    bool jsonBody = false,
    bool preferRepresentation = false,
    String? preferResolution,
  }) {
    final headers = <String, String>{
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
    if (jsonBody) headers['Content-Type'] = 'application/json';
    if (preferRepresentation) {
      var pref = 'return=representation';
      if (preferResolution != null && preferResolution.isNotEmpty)
        pref += ',$preferResolution';
      headers['Prefer'] = pref;
    }
    return headers;
  }

  // ---------------------------
  // JWT utilities (used for getUserFarmIds)
  // ---------------------------
  String _decodeBase64Url(String str) {
    var output = str.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 0:
        break;
      case 2:
        output += '==';
        break;
      case 3:
        output += '=';
        break;
      default:
        return '';
    }
    try {
      return utf8.decode(base64.decode(output));
    } catch (e) {
      debugPrint('base64 decode error: $e');
      return '';
    }
  }

  Map<String, dynamic> _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final payload = parts[1];
      final decoded = _decodeBase64Url(payload);
      final Map<String, dynamic> map = json.decode(decoded);
      return map;
    } catch (e) {
      debugPrint('JWT decode error: $e');
      return {};
    }
  }

  String getTelegramIdFromToken() {
    final p = _decodeJwtPayload(token);
    return (p['telegram_id'] ?? p['sub'])?.toString() ?? '';
  }

  bool isTokenExpired() {
    try {
      final p = _decodeJwtPayload(token);
      if (!p.containsKey('exp')) return true;
      final expNum = p['exp'];
      final expSec = expNum is int
          ? expNum
          : int.tryParse(expNum.toString()) ?? 0;
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= expSec;
    } catch (e) {
      debugPrint('isTokenExpired error: $e');
      return true;
    }
  }

  // ---------------------------
  // User / farm / animals helpers
  // ---------------------------
  Future<String?> fetchUserIdForTelegram(String telegramId) async {
    final url =
        '$SUPABASE_URL/rest/v1/app_users?select=id&telegram_id=eq.$telegramId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchUserId status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return null;
    final List data = json.decode(resp.body);
    if (data.isEmpty) return null;
    return (data.first['id'] ?? '').toString();
  }

  Future<List<String>> fetchOwnedFarmIds(String userId) async {
    final url = '$SUPABASE_URL/rest/v1/farms?select=id&owner_id=eq.$userId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchOwnedFarms status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data
        .map<String>((e) => (e['id'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<List<String>> fetchMemberFarmIds(String userId) async {
    final url =
        '$SUPABASE_URL/rest/v1/farm_members?select=farm_id&user_id=eq.$userId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint(
      'fetchMemberFarms status: ${resp.statusCode} body: ${resp.body}',
    );
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data
        .map<String>((e) => (e['farm_id'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<List<String>> getUserFarmIds() async {
    final telegramId = getTelegramIdFromToken();
    if (telegramId.isEmpty) throw Exception('Invalid token: no telegram_id');
    final userId = await fetchUserIdForTelegram(telegramId);
    if (userId == null || userId.isEmpty)
      throw Exception('No app user found for Telegram ID $telegramId');
    final owned = await fetchOwnedFarmIds(userId);
    final member = await fetchMemberFarmIds(userId);
    final set = <String>{...owned, ...member};
    return set.toList();
  }

  Future<List<Map<String, dynamic>>> fetchAnimalsForFarms(
    List<String> farmIds,
  ) async {
    if (farmIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=in.$encodedList&order=id';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchAnimalsForFarms status: ${resp.statusCode}');
    if (resp.statusCode != 200) {
      debugPrint('fetchAnimalsForFarms body: ${resp.body}');
      throw Exception('Failed to fetch animals: ${resp.statusCode}');
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(
      data.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  Future<List<Map<String, dynamic>>> fetchMilkHistory({
    required List<String> animalIds,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    if (animalIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${animalIds.join(',')})');
    String url =
        '$SUPABASE_URL/rest/v1/milk_production?select=*&animal_id=in.$encodedList&order=date.desc';
    if (fromDate != null)
      url += '&date=gte.${fromDate.toIso8601String().split('T')[0]}';
    if (toDate != null)
      url += '&date=lte.${toDate.toIso8601String().split('T')[0]}';
    final resp = await _get(url, headers: _commonHeaders());
    if (resp.statusCode != 200) {
      throw Exception(
        'Failed to fetch milk history: ${resp.statusCode} ${resp.body}',
      );
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(
      data.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  // ---------------------------
  // Milk CRUD operations
  // ---------------------------

  /// Save single milk production entry; uses upsert to avoid unique-constraint failures.
  /// Returns map: { success: bool, statusCode, data (record or null), body, error? }
  Future<Map<String, dynamic>> saveMilkProduction({
    required String animalId,
    required String? farmId,
    required double quantity,
    required DateTime date,
    String entryType = 'per_cow',
    String? note,
    String? session, // optional session
  }) async {
    final payload = <String, dynamic>{
      'animal_id': animalId,
      'farm_id': farmId?.isNotEmpty == true ? farmId : null,
      'quantity': quantity,
      'date': date.toIso8601String().split('T')[0],
      'entry_type': entryType,
      'note': note,
      'source': 'web',
    };
    if (session != null && session.isNotEmpty) payload['session'] = session;

    // upsert on unique (animal_id,date,entry_type,session) - ensure DB constraint matches
    final url =
        '$SUPABASE_URL/rest/v1/milk_production?on_conflict=animal_id,date,entry_type,session';
    try {
      final resp = await _post(
        url,
        body: [payload],
        headers: _commonHeaders(
          jsonBody: true,
          preferRepresentation: true,
          preferResolution: 'merge-duplicates',
        ),
      );

      debugPrint(
        'saveMilkProduction status: ${resp.statusCode} body: ${resp.body}',
      );

      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          try {
            final parsed = json.decode(resp.body);
            if (parsed is List && parsed.isNotEmpty) {
              final rec = Map<String, dynamic>.from(parsed.first as Map);
              return {
                'success': true,
                'statusCode': resp.statusCode,
                'data': rec,
                'body': resp.body,
              };
            } else if (parsed is Map) {
              return {
                'success': true,
                'statusCode': resp.statusCode,
                'data': Map<String, dynamic>.from(parsed),
                'body': resp.body,
              };
            }
          } catch (e) {
            debugPrint('saveMilkProduction parse error: $e');
          }
        }
        return {
          'success': true,
          'statusCode': resp.statusCode,
          'data': null,
          'body': resp.body.isNotEmpty ? resp.body : null,
        };
      }

      // On conflict (if DB unique constraint different) we return the failure so caller can decide
      return {
        'success': false,
        'statusCode': resp.statusCode,
        'data': null,
        'body': resp.body,
        'error': 'Server returned ${resp.statusCode}',
      };
    } catch (e, st) {
      debugPrint('saveMilkProduction error: $e\n$st');
      return {
        'success': false,
        'statusCode': -1,
        'data': null,
        'body': null,
        'error': e.toString(),
      };
    }
  }

  /// Bulk upsert (array POST) — returns created/updated records or null on failure
  Future<List<Map<String, dynamic>>?> saveMilkProductionBulk(
    List<Map<String, dynamic>> payloads,
  ) async {
    if (payloads.isEmpty) return [];
    final url =
        '$SUPABASE_URL/rest/v1/milk_production?on_conflict=animal_id,date,entry_type,session';
    try {
      final resp = await _post(
        url,
        body: payloads,
        headers: _commonHeaders(
          jsonBody: true,
          preferRepresentation: true,
          preferResolution: 'merge-duplicates',
        ),
      );
      debugPrint(
        'saveMilkProductionBulk status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          final List data = json.decode(resp.body);
          return data
              .map<Map<String, dynamic>>(
                (e) => Map<String, dynamic>.from(e as Map),
              )
              .toList();
        }
        return [];
      }
      debugPrint(
        'saveMilkProductionBulk unexpected response: ${resp.statusCode} ${resp.body}',
      );
      return null;
    } catch (e) {
      debugPrint('saveMilkProductionBulk error: $e');
      return null;
    }
  }

  /// Update milk entry and return updated record (or null)
  Future<Map<String, dynamic>?> updateMilkEntry(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await _patch(
        url,
        body: payload,
        headers: _commonHeaders(jsonBody: true, preferRepresentation: true),
      );
      debugPrint(
        'updateMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          final List data = json.decode(resp.body);
          if (data.isNotEmpty)
            return Map<String, dynamic>.from(data.first as Map);
        }
        return null;
      }
      debugPrint(
        'updateMilkEntry unexpected response: ${resp.statusCode} ${resp.body}',
      );
      return null;
    } catch (e) {
      debugPrint('updateMilkEntry error: $e');
      return null;
    }
  }

  /// Delete milk entry by id. Returns true if deleted.
  Future<bool> deleteMilkEntry(String id) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await _delete(url, headers: _commonHeaders());
      debugPrint(
        'deleteMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('deleteMilkEntry error: $e');
      return false;
    }
  }
}
*/


















/*// lib/api_service.dart working with edit .. milk
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart' show debugPrint;
import 'supabase_config.dart';

class ApiService {
  final String token;
  ApiService(this.token);

  // ---------------------------
  // Basic HTTP helpers
  // ---------------------------
  Future<http.Response> _get(String url, {Map<String, String>? headers}) =>
      http.get(Uri.parse(url), headers: headers);

  Future<http.Response> _post(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) => http.post(
    Uri.parse(url),
    headers: headers,
    body: body is String ? body : json.encode(body),
  );

  Future<http.Response> _patch(
    String url, {
    dynamic body,
    Map<String, String>? headers,
  }) => http.patch(
    Uri.parse(url),
    headers: headers,
    body: body is String ? body : json.encode(body),
  );

  Future<http.Response> _delete(String url, {Map<String, String>? headers}) =>
      http.delete(Uri.parse(url), headers: headers);

  Map<String, String> _commonHeaders({
    bool jsonBody = false,
    bool preferRepresentation = false,
    String? preferResolution, // e.g. 'merge-duplicates'
  }) {
    final headers = <String, String>{
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
    if (jsonBody) headers['Content-Type'] = 'application/json';
    if (preferRepresentation) {
      var pref = 'return=representation';
      if (preferResolution != null && preferResolution.isNotEmpty)
        pref += ',$preferResolution';
      headers['Prefer'] = pref;
    }
    return headers;
  }

  // ---------------------------
  // JWT utilities (used for getUserFarmIds)
  // ---------------------------
  String _decodeBase64Url(String str) {
    var output = str.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 0:
        break;
      case 2:
        output += '==';
        break;
      case 3:
        output += '=';
        break;
      default:
        return '';
    }
    try {
      return utf8.decode(base64.decode(output));
    } catch (e) {
      debugPrint('base64 decode error: $e');
      return '';
    }
  }

  Map<String, dynamic> _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final payload = parts[1];
      final decoded = _decodeBase64Url(payload);
      final Map<String, dynamic> map = json.decode(decoded);
      return map;
    } catch (e) {
      debugPrint('JWT decode error: $e');
      return {};
    }
  }

  String getTelegramIdFromToken() {
    final p = _decodeJwtPayload(token);
    return (p['telegram_id'] ?? p['sub'])?.toString() ?? '';
  }

  bool isTokenExpired() {
    try {
      final p = _decodeJwtPayload(token);
      if (!p.containsKey('exp')) return true;
      final expNum = p['exp'];
      final expSec = expNum is int
          ? expNum
          : int.tryParse(expNum.toString()) ?? 0;
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= expSec;
    } catch (e) {
      debugPrint('isTokenExpired error: $e');
      return true;
    }
  }

  // ---------------------------
  // User / farm / animals helpers
  // ---------------------------
  Future<String?> fetchUserIdForTelegram(String telegramId) async {
    final url =
        '$SUPABASE_URL/rest/v1/app_users?select=id&telegram_id=eq.$telegramId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchUserId status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return null;
    final List data = json.decode(resp.body);
    if (data.isEmpty) return null;
    return (data.first['id'] ?? '').toString();
  }

  Future<List<String>> fetchOwnedFarmIds(String userId) async {
    final url = '$SUPABASE_URL/rest/v1/farms?select=id&owner_id=eq.$userId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchOwnedFarms status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data
        .map<String>((e) => (e['id'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<List<String>> fetchMemberFarmIds(String userId) async {
    final url =
        '$SUPABASE_URL/rest/v1/farm_members?select=farm_id&user_id=eq.$userId';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint(
      'fetchMemberFarms status: ${resp.statusCode} body: ${resp.body}',
    );
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data
        .map<String>((e) => (e['farm_id'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<List<String>> getUserFarmIds() async {
    final telegramId = getTelegramIdFromToken();
    if (telegramId.isEmpty) throw Exception('Invalid token: no telegram_id');
    final userId = await fetchUserIdForTelegram(telegramId);
    if (userId == null || userId.isEmpty)
      throw Exception('No app user found for Telegram ID $telegramId');
    final owned = await fetchOwnedFarmIds(userId);
    final member = await fetchMemberFarmIds(userId);
    final set = <String>{...owned, ...member};
    return set.toList();
  }

  Future<List<Map<String, dynamic>>> fetchAnimalsForFarms(
    List<String> farmIds,
  ) async {
    if (farmIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=in.$encodedList&order=id';
    final resp = await _get(url, headers: _commonHeaders());
    debugPrint('fetchAnimalsForFarms status: ${resp.statusCode}');
    if (resp.statusCode != 200) {
      debugPrint('fetchAnimalsForFarms body: ${resp.body}');
      throw Exception('Failed to fetch animals: ${resp.statusCode}');
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(
      data.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  Future<List<Map<String, dynamic>>> fetchMilkHistory({
    required List<String> animalIds,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    if (animalIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${animalIds.join(',')})');
    String url =
        '$SUPABASE_URL/rest/v1/milk_production?select=*&animal_id=in.$encodedList&order=date.desc';
    if (fromDate != null)
      url += '&date=gte.${fromDate.toIso8601String().split('T')[0]}';
    if (toDate != null)
      url += '&date=lte.${toDate.toIso8601String().split('T')[0]}';
    final resp = await _get(url, headers: _commonHeaders());
    if (resp.statusCode != 200) {
      throw Exception(
        'Failed to fetch milk history: ${resp.statusCode} ${resp.body}',
      );
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(
      data.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  // ---------------------------
  // Milk CRUD operations
  // ---------------------------

  /// Save single milk production entry; uses upsert to avoid unique-constraint failures.
  /// Returns map: { success: bool, statusCode, data (record or null), body, error? }
  Future<Map<String, dynamic>> saveMilkProduction({
    required String animalId,
    required String? farmId,
    required double quantity,
    required DateTime date,
    String entryType = 'per_cow',
    String? note,
  }) async {
    final payload = {
      'animal_id': animalId,
      'farm_id': farmId?.isNotEmpty == true ? farmId : null,
      'quantity': quantity,
      'date': date.toIso8601String().split('T')[0],
      'entry_type': entryType,
      'note': note,
      'source': 'web',
    };

    // upsert on unique (animal_id,date,entry_type)
    final url =
        '$SUPABASE_URL/rest/v1/milk_production?on_conflict=animal_id,date,entry_type';
    try {
      final resp = await _post(
        url,
        body: [payload],
        headers: _commonHeaders(
          jsonBody: true,
          preferRepresentation: true,
          preferResolution: 'merge-duplicates',
        ),
      );

      debugPrint(
        'saveMilkProduction status: ${resp.statusCode} body: ${resp.body}',
      );

      if (resp.body.isNotEmpty) {
        try {
          final parsed = json.decode(resp.body);
          if (parsed is List && parsed.isNotEmpty) {
            final rec = Map<String, dynamic>.from(parsed.first as Map);
            return {
              'success': true,
              'statusCode': resp.statusCode,
              'data': rec,
              'body': resp.body,
            };
          } else if (parsed is Map) {
            return {
              'success': resp.statusCode >= 200 && resp.statusCode < 300,
              'statusCode': resp.statusCode,
              'data': Map<String, dynamic>.from(parsed),
              'body': resp.body,
            };
          }
        } catch (e) {
          debugPrint('saveMilkProduction parse error: $e');
        }
      }

      // 204 or other success without body
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {
          'success': true,
          'statusCode': resp.statusCode,
          'data': null,
          'body': resp.body.isNotEmpty ? resp.body : null,
        };
      }

      return {
        'success': false,
        'statusCode': resp.statusCode,
        'data': null,
        'body': resp.body,
        'error': 'Server returned ${resp.statusCode}',
      };
    } catch (e, st) {
      debugPrint('saveMilkProduction error: $e\n$st');
      return {
        'success': false,
        'statusCode': -1,
        'data': null,
        'body': null,
        'error': e.toString(),
      };
    }
  }

  /// Bulk upsert (array POST) — returns created/updated records or null on failure
  Future<List<Map<String, dynamic>>?> saveMilkProductionBulk(
    List<Map<String, dynamic>> payloads,
  ) async {
    if (payloads.isEmpty) return [];
    final url =
        '$SUPABASE_URL/rest/v1/milk_production?on_conflict=animal_id,date,entry_type';
    try {
      final resp = await _post(
        url,
        body: payloads,
        headers: _commonHeaders(
          jsonBody: true,
          preferRepresentation: true,
          preferResolution: 'merge-duplicates',
        ),
      );
      debugPrint(
        'saveMilkProductionBulk status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          final List data = json.decode(resp.body);
          return data
              .map<Map<String, dynamic>>(
                (e) => Map<String, dynamic>.from(e as Map),
              )
              .toList();
        }
        return [];
      }
      debugPrint(
        'saveMilkProductionBulk unexpected response: ${resp.statusCode} ${resp.body}',
      );
      return null;
    } catch (e) {
      debugPrint('saveMilkProductionBulk error: $e');
      return null;
    }
  }

  /// Update milk entry and return updated record (or null)
  Future<Map<String, dynamic>?> updateMilkEntry(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await _patch(
        url,
        body: payload,
        headers: _commonHeaders(jsonBody: true, preferRepresentation: true),
      );
      debugPrint(
        'updateMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          final List data = json.decode(resp.body);
          if (data.isNotEmpty)
            return Map<String, dynamic>.from(data.first as Map);
        }
        return null;
      }
      debugPrint(
        'updateMilkEntry unexpected response: ${resp.statusCode} ${resp.body}',
      );
      return null;
    } catch (e) {
      debugPrint('updateMilkEntry error: $e');
      return null;
    }
  }

  /// Delete milk entry by id. Returns true if deleted.
  Future<bool> deleteMilkEntry(String id) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await _delete(url, headers: _commonHeaders());
      debugPrint(
        'deleteMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('deleteMilkEntry error: $e');
      return false;
    }
  }
}
*/















/*import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'supabase_config.dart';

class ApiService {
  final String token;
  ApiService(this.token);

  // ---------------- JWT Utilities (unchanged) ----------------
  String _decodeBase64Url(String str) {
    var output = str.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 0:
        break;
      case 2:
        output += '==';
        break;
      case 3:
        output += '=';
        break;
      default:
        return '';
    }
    try {
      return utf8.decode(base64.decode(output));
    } catch (e) {
      debugPrint('base64 decode error: $e');
      return '';
    }
  }

  Map<String, dynamic> _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final payload = parts[1];
      final decoded = _decodeBase64Url(payload);
      final Map<String, dynamic> map = json.decode(decoded);
      return map;
    } catch (e) {
      debugPrint('JWT decode error: $e');
      return {};
    }
  }

  String getTelegramIdFromToken() {
    final p = _decodeJwtPayload(token);
    return (p['telegram_id'] ?? p['sub'])?.toString() ?? '';
  }

  bool isTokenExpired() {
    try {
      final p = _decodeJwtPayload(token);
      if (!p.containsKey('exp')) return true;
      final expNum = p['exp'];
      final expSec = expNum is int
          ? expNum
          : int.tryParse(expNum.toString()) ?? 0;
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= expSec;
    } catch (e) {
      debugPrint('isTokenExpired error: $e');
      return true;
    }
  }

  // ---------------- HTTP helper ----------------
  Map<String, String> _commonHeaders({
    bool jsonBody = false,
    bool preferRepresentation = false,
  }) {
    final headers = <String, String>{
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer $token',
      'Accept': 'application/json',
    };
    if (jsonBody) headers['Content-Type'] = 'application/json';
    if (preferRepresentation) headers['Prefer'] = 'return=representation';
    return headers;
  }

  // Optional: centralised GET with timeout & debug
  Future<http.Response> _get(
    String url, {
    Duration timeout = const Duration(seconds: 15),
  }) {
    debugPrint('GET $url');
    return http.get(Uri.parse(url), headers: _commonHeaders()).timeout(timeout);
  }

  Future<http.Response> _post(
    String url, {
    Object? body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) {
    debugPrint(
      'POST $url body=${body is String ? body : (body != null ? json.encode(body) : null)}',
    );
    return http
        .post(
          Uri.parse(url),
          headers: headers ?? _commonHeaders(jsonBody: true),
          body: body is String
              ? body
              : (body != null ? json.encode(body) : null),
        )
        .timeout(timeout);
  }

  Future<http.Response> _patch(
    String url, {
    Object? body,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) {
    debugPrint(
      'PATCH $url body=${body is String ? body : (body != null ? json.encode(body) : null)}',
    );
    return http
        .patch(
          Uri.parse(url),
          headers: headers ?? _commonHeaders(jsonBody: true),
          body: body is String
              ? body
              : (body != null ? json.encode(body) : null),
        )
        .timeout(timeout);
  }

  Future<http.Response> _delete(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 15),
  }) {
    debugPrint('DELETE $url');
    return http
        .delete(Uri.parse(url), headers: headers ?? _commonHeaders())
        .timeout(timeout);
  }

  // ---------------- Supabase Fetch Helpers (unchanged but robust) ----------------
  Future<String?> fetchUserIdForTelegram(String telegramId) async {
    final url =
        '$SUPABASE_URL/rest/v1/app_users?select=id&telegram_id=eq.$telegramId';
    try {
      final resp = await _get(url);
      debugPrint('fetchUserId status: ${resp.statusCode} body: ${resp.body}');
      if (resp.statusCode != 200) return null;
      final List data = json.decode(resp.body);
      if (data.isEmpty) return null;
      return (data.first['id'] ?? '').toString();
    } catch (e) {
      debugPrint('fetchUserIdForTelegram error: $e');
      return null;
    }
  }

  Future<List<String>> fetchOwnedFarmIds(String userId) async {
    final url = '$SUPABASE_URL/rest/v1/farms?select=id&owner_id=eq.$userId';
    try {
      final resp = await _get(url);
      debugPrint(
        'fetchOwnedFarms status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode != 200) return [];
      final List data = json.decode(resp.body);
      return data
          .map<String>((e) => (e['id'] ?? '').toString())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('fetchOwnedFarmIds error: $e');
      return [];
    }
  }

  Future<List<String>> fetchMemberFarmIds(String userId) async {
    final url =
        '$SUPABASE_URL/rest/v1/farm_members?select=farm_id&user_id=eq.$userId';
    try {
      final resp = await _get(url);
      debugPrint(
        'fetchMemberFarms status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode != 200) return [];
      final List data = json.decode(resp.body);
      return data
          .map<String>((e) => (e['farm_id'] ?? '').toString())
          .where((e) => e.isNotEmpty)
          .toList();
    } catch (e) {
      debugPrint('fetchMemberFarmIds error: $e');
      return [];
    }
  }

  Future<List<Map<String, dynamic>>> fetchAnimalsForFarms(
    List<String> farmIds,
  ) async {
    if (farmIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=in.$encodedList&order=id';
    try {
      final resp = await _get(url);
      debugPrint('fetchAnimalsForFarms status: ${resp.statusCode}');
      if (resp.statusCode != 200) {
        debugPrint('fetchAnimalsForFarms body: ${resp.body}');
        throw Exception('Failed to fetch animals: ${resp.statusCode}');
      }
      final List data = json.decode(resp.body);
      return List<Map<String, dynamic>>.from(
        data.map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (e) {
      debugPrint('fetchAnimalsForFarms error: $e');
      rethrow;
    }
  }

  Future<List<String>> getUserFarmIds() async {
    final telegramId = getTelegramIdFromToken();
    if (telegramId.isEmpty) throw Exception('Invalid token: no telegram_id');
    final userId = await fetchUserIdForTelegram(telegramId);
    if (userId == null || userId.isEmpty) {
      throw Exception('No app user found for Telegram ID $telegramId');
    }
    final owned = await fetchOwnedFarmIds(userId);
    final member = await fetchMemberFarmIds(userId);
    final set = <String>{...owned, ...member};
    return set.toList();
  }

  // ---------------- Milk endpoints ----------------

  /// Fetch milk history (same as before). Consider adding `limit`/`offset` when dataset grows.
  Future<List<Map<String, dynamic>>> fetchMilkHistory({
    required List<String> animalIds,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    if (animalIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${animalIds.join(',')})');
    String url =
        '$SUPABASE_URL/rest/v1/milk_production?select=*&animal_id=in.$encodedList&order=date.desc';
    if (fromDate != null) {
      url += '&date=gte.${fromDate.toIso8601String().split('T')[0]}';
    }
    if (toDate != null) {
      url += '&date=lte.${toDate.toIso8601String().split('T')[0]}';
    }
    try {
      final resp = await _get(url);
      if (resp.statusCode != 200) {
        debugPrint('fetchMilkHistory failed: ${resp.statusCode} ${resp.body}');
        throw Exception('Failed to fetch milk history: ${resp.statusCode}');
      }
      final List data = json.decode(resp.body);
      return List<Map<String, dynamic>>.from(
        data.map((e) => Map<String, dynamic>.from(e as Map)),
      );
    } catch (e) {
      debugPrint('fetchMilkHistory error: $e');
      rethrow;
    }
  }

  /// Save single milk production entry and return the created record (or null).
  /// Uses Prefer: return=representation so the newly created row (with id) is returned.
  /// Returns a map: { "success": bool, "statusCode": int, "data": Map? , "body": String?, "error": String? }
  Future<Map<String, dynamic>> saveMilkProduction({
    required String animalId,
    required String? farmId,
    required double quantity,
    required String session,
    required DateTime date,
  }) async {
    final body = {
      'animal_id': animalId,
      'farm_id': farmId?.isNotEmpty == true ? farmId : null,
      'quantity': quantity,
      'date': date.toIso8601String().split('T')[0],
      'session': session,
      'source': 'web',
    };

    final url = '$SUPABASE_URL/rest/v1/milk_production';
    try {
      final resp = await _post(
        url,
        body: body,
        headers: _commonHeaders(jsonBody: true, preferRepresentation: true),
      );

      debugPrint('saveMilkProduction status: ${resp.statusCode}');
      debugPrint('saveMilkProduction body: ${resp.body}');

      // Try to parse JSON body if present
      if (resp.body.isNotEmpty) {
        try {
          final parsed = json.decode(resp.body);
          // Supabase returns array for return=representation
          if (parsed is List && parsed.isNotEmpty) {
            final rec = Map<String, dynamic>.from(parsed.first as Map);
            return {
              'success': true,
              'statusCode': resp.statusCode,
              'data': rec,
              'body': resp.body,
            };
          }
          if (parsed is Map) {
            // Some backends return object
            return {
              'success': resp.statusCode >= 200 && resp.statusCode < 300,
              'statusCode': resp.statusCode,
              'data': Map<String, dynamic>.from(parsed),
              'body': resp.body,
            };
          }
        } catch (e) {
          debugPrint('saveMilkProduction parse error: $e');
          // continue to return raw body below
        }
      }

      // 204 No Content still can mean success
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        return {
          'success': true,
          'statusCode': resp.statusCode,
          'data': null,
          'body': resp.body.isNotEmpty ? resp.body : null,
        };
      }

      // Non-success - return body as error message when possible
      return {
        'success': false,
        'statusCode': resp.statusCode,
        'data': null,
        'body': resp.body,
        'error': 'Server returned ${resp.statusCode}',
      };
    } catch (e, st) {
      debugPrint('saveMilkProduction network/error: $e\n$st');
      return {
        'success': false,
        'statusCode': -1,
        'data': null,
        'body': null,
        'error': e.toString(),
      };
    }
  }

  /// Bulk insert multiple milk entries.
  /// Accepts a list of payload maps; returns list of created records or null on failure.
  Future<List<Map<String, dynamic>>?> saveMilkProductionBulk(
    List<Map<String, dynamic>> payloads,
  ) async {
    if (payloads.isEmpty) return [];
    final url = '$SUPABASE_URL/rest/v1/milk_production';
    try {
      final resp = await _post(
        url,
        body: payloads,
        headers: _commonHeaders(jsonBody: true, preferRepresentation: true),
      );
      debugPrint(
        'saveMilkProductionBulk status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          final List data = json.decode(resp.body);
          return data
              .map<Map<String, dynamic>>(
                (e) => Map<String, dynamic>.from(e as Map),
              )
              .toList();
        }
        return [];
      }
      debugPrint(
        'saveMilkProductionBulk unexpected response: ${resp.statusCode} ${resp.body}',
      );
      return null;
    } catch (e) {
      debugPrint('saveMilkProductionBulk error: $e');
      return null;
    }
  }

  /// Update milk entry and return updated record (or null)
  Future<Map<String, dynamic>?> updateMilkEntry(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await _patch(
        url,
        body: payload,
        headers: _commonHeaders(jsonBody: true, preferRepresentation: true),
      );
      debugPrint(
        'updateMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        if (resp.body.isNotEmpty) {
          final List data = json.decode(resp.body);
          if (data.isNotEmpty)
            return Map<String, dynamic>.from(data.first as Map);
        }
        return null;
      }
      debugPrint(
        'updateMilkEntry unexpected response: ${resp.statusCode} ${resp.body}',
      );
      return null;
    } catch (e) {
      debugPrint('updateMilkEntry error: $e');
      return null;
    }
  }

  /// Delete milk entry by id. Returns true if deleted.
  Future<bool> deleteMilkEntry(String id) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await _delete(url);
      debugPrint(
        'deleteMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('deleteMilkEntry error: $e');
      return false;
    }
  }
}*/















/*99import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'supabase_config.dart';

class ApiService {
  final String token;

  ApiService(this.token);

  // JWT Utilities
  String _decodeBase64Url(String str) {
    var output = str.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 0:
        break;
      case 2:
        output += '==';
        break;
      case 3:
        output += '=';
        break;
      default:
        return '';
    }
    try {
      return utf8.decode(base64.decode(output));
    } catch (e) {
      debugPrint('base64 decode error: $e');
      return '';
    }
  }

  Map<String, dynamic> _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final payload = parts[1];
      final decoded = _decodeBase64Url(payload);
      final Map<String, dynamic> map = json.decode(decoded);
      return map;
    } catch (e) {
      debugPrint('JWT decode error: $e');
      return {};
    }
  }

  String getTelegramIdFromToken() {
    final p = _decodeJwtPayload(token);
    return (p['telegram_id'] ?? p['sub'])?.toString() ?? '';
  }

  bool isTokenExpired() {
    try {
      final p = _decodeJwtPayload(token);
      if (!p.containsKey('exp')) return true;
      final expNum = p['exp'];
      final expSec = expNum is int
          ? expNum
          : int.tryParse(expNum.toString()) ?? 0;
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= expSec;
    } catch (e) {
      debugPrint('isTokenExpired error: $e');
      return true;
    }
  }

  // Supabase Fetch Helpers
  Future<String?> fetchUserIdForTelegram(String telegramId) async {
    final url =
        '$SUPABASE_URL/rest/v1/app_users?select=id&telegram_id=eq.$telegramId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    debugPrint('fetchUserId status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return null;
    final List data = json.decode(resp.body);
    if (data.isEmpty) return null;
    return (data.first['id'] ?? '').toString();
  }

  Future<List<String>> fetchOwnedFarmIds(String userId) async {
    final url = '$SUPABASE_URL/rest/v1/farms?select=id&owner_id=eq.$userId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    debugPrint('fetchOwnedFarms status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data
        .map<String>((e) => (e['id'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<List<String>> fetchMemberFarmIds(String userId) async {
    final url =
        '$SUPABASE_URL/rest/v1/farm_members?select=farm_id&user_id=eq.$userId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    debugPrint(
      'fetchMemberFarms status: ${resp.statusCode} body: ${resp.body}',
    );
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data
        .map<String>((e) => (e['farm_id'] ?? '').toString())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchAnimalsForFarms(
    List<String> farmIds,
  ) async {
    if (farmIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=in.$encodedList&order=id';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    debugPrint('fetchAnimalsForFarms status: ${resp.statusCode}');
    if (resp.statusCode != 200) {
      debugPrint('fetchAnimalsForFarms body: ${resp.body}');
      throw Exception('Failed to fetch animals: ${resp.statusCode}');
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(
      data.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  Future<List<String>> getUserFarmIds() async {
    final telegramId = getTelegramIdFromToken();
    if (telegramId.isEmpty) throw Exception('Invalid token: no telegram_id');
    final userId = await fetchUserIdForTelegram(telegramId);
    if (userId == null || userId.isEmpty) {
      throw Exception('No app user found for Telegram ID $telegramId');
    }
    final owned = await fetchOwnedFarmIds(userId);
    final member = await fetchMemberFarmIds(userId);
    final set = <String>{...owned, ...member};
    return set.toList();
  }

  Future<List<Map<String, dynamic>>> fetchMilkHistory({
    required List<String> animalIds,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    if (animalIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${animalIds.join(',')})');
    String url =
        '$SUPABASE_URL/rest/v1/milk_production?select=*&animal_id=in.$encodedList&order=date.desc';
    if (fromDate != null) {
      url += '&date=gte.${fromDate.toIso8601String().split('T')[0]}';
    }
    if (toDate != null) {
      url += '&date=lte.${toDate.toIso8601String().split('T')[0]}';
    }
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    if (resp.statusCode != 200) {
      throw Exception('Failed to fetch milk history: ${resp.statusCode}');
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(
      data.map((e) => Map<String, dynamic>.from(e as Map)),
    );
  }

  // POST Operation
  Future<bool> saveMilkProduction({
    required String animalId,
    required String? farmId,
    required double quantity,
    required String session,
    required DateTime date,
  }) async {
    final response = await http.post(
      Uri.parse('$SUPABASE_URL/rest/v1/milk_production'),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
      },
      body: json.encode({
        'animal_id': animalId,
        'farm_id': farmId?.isNotEmpty == true ? farmId : null,
        'quantity': quantity,
        'date': date.toIso8601String().split('T')[0],
        'session': session,
        'source': 'web',
      }),
    );
    debugPrint(
      'saveMilkProduction status: ${response.statusCode} body: ${response.body}',
    );
    return response.statusCode >= 200 && response.statusCode < 300;
  }
}

*/
















/*import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'supabase_config.dart';

class ApiService {
  final String token;

  ApiService(this.token);

  // JWT Utilities
  String _decodeBase64Url(String str) {
    var output = str.replaceAll('-', '+').replaceAll('_', '/');
    switch (output.length % 4) {
      case 0:
        break;
      case 2:
        output += '==';
        break;
      case 3:
        output += '=';
        break;
      default:
        return '';
    }
    try {
      return utf8.decode(base64.decode(output));
    } catch (e) {
      debugPrint('base64 decode error: $e');
      return '';
    }
  }

  Map<String, dynamic> _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final payload = parts[1];
      final decoded = _decodeBase64Url(payload);
      final Map<String, dynamic> map = json.decode(decoded);
      return map;
    } catch (e) {
      debugPrint('JWT decode error: $e');
      return {};
    }
  }

  String getTelegramIdFromToken() {
    final p = _decodeJwtPayload(token);
    return (p['telegram_id'] ?? p['sub'])?.toString() ?? '';
  }

  bool isTokenExpired() {
    try {
      final p = _decodeJwtPayload(token);
      if (!p.containsKey('exp')) return true;
      final expNum = p['exp'];
      final expSec = expNum is int ? expNum : int.tryParse(expNum.toString()) ?? 0;
      final nowSec = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000;
      return nowSec >= expSec;
    } catch (e) {
      debugPrint('isTokenExpired error: $e');
      return true;
    }
  }

  // Supabase Fetch Helpers
  Future<String?> fetchUserIdForTelegram(String telegramId) async {
    final url = '$SUPABASE_URL/rest/v1/app_users?select=id&telegram_id=eq.$telegramId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    debugPrint('fetchUserId status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return null;
    final List data = json.decode(resp.body);
    if (data.isEmpty) return null;
    return (data.first['id'] ?? '').toString();
  }

  Future<List<String>> fetchOwnedFarmIds(String userId) async {
    final url = '$SUPABASE_URL/rest/v1/farms?select=id&owner_id=eq.$userId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    debugPrint('fetchOwnedFarms status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data.map<String>((e) => (e['id'] ?? '').toString()).where((e) => e.isNotEmpty).toList();
  }

  Future<List<String>> fetchMemberFarmIds(String userId) async {
    final url = '$SUPABASE_URL/rest/v1/farm_members?select=farm_id&user_id=eq.$userId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    debugPrint('fetchMemberFarms status: ${resp.statusCode} body: ${resp.body}');
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data.map<String>((e) => (e['farm_id'] ?? '').toString()).where((e) => e.isNotEmpty).toList();
  }

  Future<List<Map<String, dynamic>>> fetchAnimalsForFarms(List<String> farmIds) async {
    if (farmIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url = '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=in.$encodedList&order=id';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
      },
    );
    debugPrint('fetchAnimalsForFarms status: ${resp.statusCode}');
    if (resp.statusCode != 200) {
      debugPrint('fetchAnimalsForFarms body: ${resp.body}');
      throw Exception('Failed to fetch animals: ${resp.statusCode}');
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e as Map)));
  }

  Future<List<String>> getUserFarmIds() async {
    final telegramId = getTelegramIdFromToken();
    if (telegramId.isEmpty) throw Exception('Invalid token: no telegram_id');
    final userId = await fetchUserIdForTelegram(telegramId);
    if (userId == null || userId.isEmpty) {
      throw Exception('No app user found for Telegram ID $telegramId');
    }
    final owned = await fetchOwnedFarmIds(userId);
    final member = await fetchMemberFarmIds(userId);
    final set = <String>{...owned, ...member};
    return set.toList();
  }

  // POST Operation
  Future<bool> saveMilkProduction({
    required String animalId,
    required String? farmId,
    required double quantity,
  }) async {
    final response = await http.post(
      Uri.parse('$SUPABASE_URL/rest/v1/milk_production'),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
        'Prefer': 'return=minimal',
      },
      body: json.encode({
        'animal_id': animalId,
        'farm_id': farmId?.isNotEmpty == true ? farmId : null,
        'quantity': quantity,
        'date': DateTime.now().toIso8601String().split('T')[0],
        'source': 'web',
      }),
    );
    debugPrint('saveMilkProduction status: ${response.statusCode} body: ${response.body}');
    return response.statusCode >= 200 && response.statusCode < 300;
  }
}
*/