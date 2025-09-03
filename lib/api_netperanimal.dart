// lib/api_netperanimal.dart
import 'package:flutter/foundation.dart' show debugPrint;
import 'api_service.dart';
import 'supabase_config.dart';

class NetPerAnimalApi {
  final ApiService api;
  NetPerAnimalApi(this.api);

  /// Fetch animals the user can access and merge with animal_financial_summary view.
  Future<List<Map<String, dynamic>>> fetchAnimalsWithFinancials() async {
    final farmIds = await api.getUserFarmIds();
    if (farmIds.isEmpty) return [];

    final animals = await api.fetchAnimalsForFarms(farmIds);
    final animalIds = animals
        .map((a) => (a['id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toList();
    if (animalIds.isEmpty) return List<Map<String, dynamic>>.from(animals);

    final encodedList = Uri.encodeComponent('(${animalIds.join(",")})');
    final url =
        '$SUPABASE_URL/rest/v1/animal_financial_summary?select=*&animal_id=in.$encodedList';
    final parsed = await api.httpGetParsed(url);

    final summaryByAnimal = <String, Map<String, dynamic>>{};
    if (parsed is List) {
      for (final s in parsed) {
        final map = Map<String, dynamic>.from(s as Map);
        final id = (map['animal_id'] ?? '').toString();
        if (id.isNotEmpty) summaryByAnimal[id] = map;
      }
    } else {
      debugPrint('fetchAnimalsWithFinancials: no summary parsed (url=$url)');
    }

    final out = <Map<String, dynamic>>[];
    for (final a in animals) {
      final id = (a['id'] ?? '').toString();
      final merged = Map<String, dynamic>.from(a);
      final s = summaryByAnimal[id];
      merged['finance_total_income'] = _toNum(s?['total_income']);
      merged['finance_feed_expense'] = _toNum(s?['feed_expense']);
      merged['finance_other_expense'] = _toNum(s?['other_expense']);
      merged['finance_net'] = _toNum(s?['net']);
      out.add(merged);
    }
    return out;
  }

  /// Fetch single animal summary
  Future<Map<String, dynamic>?> fetchSingleAnimalSummary(
    String animalId,
  ) async {
    final idEncoded = Uri.encodeComponent('($animalId)');
    final url =
        '$SUPABASE_URL/rest/v1/animal_financial_summary?select=*&animal_id=in.$idEncoded';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List && parsed.isNotEmpty)
      return Map<String, dynamic>.from(parsed.first as Map);
    return null;
  }

  /// Milk history wrapper
  Future<List<Map<String, dynamic>>> fetchMilkHistory({
    required String animalId,
    DateTime? fromDate,
    DateTime? toDate,
  }) => api.fetchMilkHistory(
    animalIds: [animalId],
    fromDate: fromDate,
    toDate: toDate,
  );

  /// Feed transactions for a single animal (direct entries only)
  Future<List<Map<String, dynamic>>> fetchFeedTransactionsForAnimal({
    required String animalId,
    DateTime? fromDate,
    DateTime? toDate,
  }) async {
    final enc = Uri.encodeComponent('($animalId)');
    var url =
        '$SUPABASE_URL/rest/v1/feed_transactions?select=*&animal_id=in.$enc&order=created_at.desc';
    if (fromDate != null)
      url += '&created_at=gte.${fromDate.toIso8601String()}';
    if (toDate != null) url += '&created_at=lte.${toDate.toIso8601String()}';

    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  /// Try to fetch precomputed timeseries from view animal_financial_timeseries (if exists).
  /// If not found, fallback to computing a daily net from milk + direct feed transactions for the last [days].
  /// Returns list of { 'date': 'YYYY-MM-DD', 'net': double } ordered ascending by date.
  Future<List<Map<String, dynamic>>> fetchNetTimeSeries({
    required String animalId,
    int days = 30,
  }) async {
    // 1) Try dedicated timeseries view (you can create this later for better performance)
    try {
      final enc = Uri.encodeComponent('($animalId)');
      final url =
          '$SUPABASE_URL/rest/v1/animal_financial_timeseries?select=date,net&animal_id=in.$enc&order=date.asc&date=gte.${DateTime.now().subtract(Duration(days: days)).toIso8601String().split("T")[0]}';
      final parsed = await api.httpGetParsed(url);
      if (parsed is List && parsed.isNotEmpty) {
        return parsed.map<Map<String, dynamic>>((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return {
            'date': (m['date'] ?? '').toString(),
            'net': _toNum(m['net']),
          };
        }).toList();
      }
    } catch (e) {
      debugPrint('fetchNetTimeSeries: timeseries view missing or error: $e');
      // fallback below
    }

    // 2) Fallback: compute from milk + direct feed txs
    final endDate = DateTime.now().toUtc();
    final startDate = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
    ).subtract(Duration(days: days - 1));
    final dateList = List<DateTime>.generate(
      days,
      (i) => startDate.add(Duration(days: i)),
    );

    // Fetch milk entries in range
    final milkEntries = await fetchMilkHistory(
      animalId: animalId,
      fromDate: startDate,
      toDate: endDate,
    );
    // Fetch feed transactions in range (direct animal feed entries)
    final feedEntries = await fetchFeedTransactionsForAnimal(
      animalId: animalId,
      fromDate: startDate,
      toDate: endDate,
    );

    // Build maps by date string
    final milkByDate = <String, double>{};
    for (final m in milkEntries) {
      final dateStr = _dateOnlyString(m['date'] ?? m['created_at'] ?? '');
      final qty = _toNum(m['quantity']);
      milkByDate.update(dateStr, (v) => v + qty, ifAbsent: () => qty);
    }

    // For feed we need cost_per_unit from feed_items; batch-fetch feed_items
    final feedItemIds = feedEntries
        .map((f) => (f['feed_item_id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    final feedItemCosts = await _fetchFeedItemsCostMap(feedItemIds);

    final feedCostByDate = <String, double>{};
    for (final f in feedEntries) {
      final dateStr = _dateOnlyString(f['created_at'] ?? f['date'] ?? '');
      final qty = _toNum(f['quantity']);
      final feedItemId = (f['feed_item_id'] ?? '').toString();
      final unitCost = _toNum(feedItemCosts[feedItemId]);
      final cost = qty * unitCost;
      feedCostByDate.update(dateStr, (v) => v + cost, ifAbsent: () => cost);
    }

    // Try to get milk price per unit: from farm_settings if available
    double milkPrice = await _fetchMilkPriceForAnimal(animalId) ?? 0.0;

    // Build timeseries: net = milkIncome - feedCost (only direct feed)
    final out = <Map<String, dynamic>>[];
    for (final dt in dateList) {
      final dstr = _dateOnlyString(dt.toIso8601String());
      final milkQty = milkByDate[dstr] ?? 0.0;
      final milkIncome = milkQty * milkPrice;
      final feedCost = feedCostByDate[dstr] ?? 0.0;
      final net = milkIncome - feedCost;
      out.add({'date': dstr, 'net': net});
    }
    return out;
  }

  // --- Helper functions ---

  double _toNum(dynamic v) {
    if (v == null) return 0.0;
    if (v is num) return v.toDouble();
    try {
      return double.parse(v.toString());
    } catch (_) {
      return 0.0;
    }
  }

  String _dateOnlyString(dynamic dateLike) {
    try {
      if (dateLike == null) return '';
      if (dateLike is DateTime) {
        return '${dateLike.year.toString().padLeft(4, '0')}-${dateLike.month.toString().padLeft(2, '0')}-${dateLike.day.toString().padLeft(2, '0')}';
      }
      final s = dateLike.toString();
      if (s.contains('T')) return s.split('T')[0];
      if (s.contains(' ')) return s.split(' ')[0];
      return s;
    } catch (e) {
      return dateLike.toString();
    }
  }

  /// Batch fetch feed_items and return map feed_item_id -> cost_per_unit
  Future<Map<String, double>> _fetchFeedItemsCostMap(
    List<String> feedItemIds,
  ) async {
    final map = <String, double>{};
    if (feedItemIds.isEmpty) return map;
    final enc = Uri.encodeComponent('(${feedItemIds.join(",")})');
    final url =
        '$SUPABASE_URL/rest/v1/feed_items?select=id,cost_per_unit&id=in.$enc';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      for (final e in parsed) {
        final m = Map<String, dynamic>.from(e as Map);
        final id = (m['id'] ?? '').toString();
        final cost = _toNum(m['cost_per_unit']);
        if (id.isNotEmpty) map[id] = cost;
      }
    }
    return map;
  }

  /// Try to get milk price for the farm the animal belongs to.
  /// Attempts to read farm_id from animal record then farm_settings 'milk_price_per_unit'.
  Future<double?> _fetchMilkPriceForAnimal(String animalId) async {
    try {
      // fetch animal to get farm_id
      final aUrl =
          '$SUPABASE_URL/rest/v1/animals?id=eq.$animalId&select=farm_id';
      final aParsed = await api.httpGetParsed(aUrl);
      if (aParsed is List && aParsed.isNotEmpty) {
        final farmId = (aParsed.first['farm_id'] ?? '').toString();
        if (farmId.isEmpty) return null;
        final enc = Uri.encodeComponent('($farmId)');
        final url =
            '$SUPABASE_URL/rest/v1/farm_settings?select=value&farm_id=in.$enc&key=eq.milk_price_per_unit';
        final parsed = await api.httpGetParsed(url);
        if (parsed is List && parsed.isNotEmpty) {
          final v = parsed.first['value'];
          // value might be stored as JSON like {"milk_price_per_unit":"0.36"} or as numeric in SQL
          if (v is Map && v.containsKey('milk_price_per_unit')) {
            return _toNum((v['milk_price_per_unit']).toString());
          }
          // if value is a scalar
          return _toNum(v);
        }
      }
    } catch (e) {
      debugPrint('_fetchMilkPriceForAnimal error: $e');
    }
    return null;
  }
}
