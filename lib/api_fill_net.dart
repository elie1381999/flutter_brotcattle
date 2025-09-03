// lib/api_fill_net.dart
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'api_service.dart';
import 'supabase_config.dart';

class FillNetApi {
  final ApiService api;
  FillNetApi(this.api);

  // --- Helper to build the same headers ApiService would build ---
  Map<String, String> _buildHeaders({
    bool jsonBody = false,
    bool preferRepresentation = false,
    String? preferResolution,
  }) {
    final headers = <String, String>{
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer ${api.token}',
      'Accept': 'application/json',
    };
    if (jsonBody) headers['Content-Type'] = 'application/json';
    if (preferRepresentation) {
      var pref = 'return=representation';
      if (preferResolution != null && preferResolution.isNotEmpty) {
        pref += ',$preferResolution';
      }
      headers['Prefer'] = pref;
    }
    return headers;
  }

  // Fetch farms the current user can access
  Future<List<Map<String, dynamic>>> fetchFarmsForUser() async {
    final farms = <Map<String, dynamic>>[];
    try {
      final farmIds = await api.getUserFarmIds();
      if (farmIds.isEmpty) return farms;
      final enc = Uri.encodeComponent('(${farmIds.join(",")})');
      final url =
          '$SUPABASE_URL/rest/v1/farms?select=id,name&order=name&id=in.$enc';
      final parsed = await api.httpGetParsed(url);
      if (parsed is List) {
        return parsed
            .map<Map<String, dynamic>>(
              (e) => Map<String, dynamic>.from(e as Map),
            )
            .toList();
      }
    } catch (e) {
      debugPrint('fetchFarmsForUser error: $e');
    }
    return farms;
  }

  // Fetch animals for given farm id
  Future<List<Map<String, dynamic>>> fetchAnimalsForFarm(String farmId) async {
    if (farmId.isEmpty) return [];
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=id,tag,name,weight,sex,stage&farm_id=eq.$farmId&order=tag';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // Fetch all feed items for farm (or global)
  // include meta so formulas can be inspected
  Future<List<Map<String, dynamic>>> fetchFeedItems({String? farmId}) async {
    final url = farmId == null || farmId.isEmpty
        ? '$SUPABASE_URL/rest/v1/feed_items?select=id,name,unit,cost_per_unit,meta&order=name'
        : '$SUPABASE_URL/rest/v1/feed_items?select=id,name,unit,cost_per_unit,meta&farm_id=eq.$farmId&order=name';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // Create feed item (catalog). Accept optional meta (used for formulas/recipes).
  Future<Map<String, dynamic>?> createFeedItem({
    required String farmId,
    required String name,
    String unit = 'kg',
    double? costPerUnit,
    Map<String, dynamic>? meta, // optional meta for formulas
  }) async {
    final body = {
      'farm_id': farmId,
      'name': name,
      'unit': unit,
      if (costPerUnit != null) 'cost_per_unit': costPerUnit,
      if (meta != null) 'meta': meta,
    };
    final url = '$SUPABASE_URL/rest/v1/feed_items';
    try {
      debugPrint('createFeedItem body: ${json.encode([body])}');
      final resp = await http.post(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
        body: json.encode([body]),
      );
      debugPrint('createFeedItem status: ${resp.statusCode} body: ${resp.body}');
      if (resp.statusCode >= 200 && resp.statusCode < 300 && resp.body.isNotEmpty) {
        final parsed = json.decode(resp.body);
        if (parsed is List && parsed.isNotEmpty) return Map<String, dynamic>.from(parsed.first as Map);
        if (parsed is Map) return Map<String, dynamic>.from(parsed);
      }
    } catch (e) {
      debugPrint('createFeedItem error: $e');
    }
    return null;
  }

  /// Fetch a single feed_item by id (includes meta).
  Future<Map<String, dynamic>?> fetchFeedItemById(String id) async {
    try {
      final url = '$SUPABASE_URL/rest/v1/feed_items?id=eq.$id&select=*';
      final parsed = await api.httpGetParsed(url);
      if (parsed is List && parsed.isNotEmpty) {
        return Map<String, dynamic>.from(parsed.first as Map);
      }
    } catch (e) {
      debugPrint('fetchFeedItemById error: $e');
    }
    return null;
  }

  /// Simple unit conversion helper (very small set). Extend as needed.
  /// Returns converted amount in targetUnit, or null if cannot convert.
  double? _convertUnit(double amount, String fromUnit, String toUnit) {
    if (fromUnit == toUnit) return amount;
    // grams <-> kg
    if (fromUnit == 'g' && toUnit == 'kg') return amount / 1000.0;
    if (fromUnit == 'kg' && toUnit == 'g') return amount * 1000.0;
    // liters <-> ml
    if (fromUnit == 'l' && toUnit == 'ml') return amount * 1000.0;
    if (fromUnit == 'ml' && toUnit == 'l') return amount / 1000.0;
    // Add conversions as needed
    return null; // unknown conversion
  }

  /// Decompose a formula (feed_item with meta.components) and decrement each
  /// ingredient from feed_inventory proportionally based on desired `amount`.
  /// Returns true when all decrements are successful (best-effort).
  Future<bool> consumeFormulaInventory({
    required String farmId,
    required String formulaFeedItemId,
    required double amount, // amount of finished formula (in formula unit)
  }) async {
    try {
      final formula = await fetchFeedItemById(formulaFeedItemId);
      if (formula == null) {
        debugPrint('consumeFormulaInventory: formula not found id=$formulaFeedItemId');
        return false;
      }
      final meta = formula['meta'];
      if (meta == null || meta is! Map || meta['components'] == null) {
        // Not a formula — fallback to decrementing the single item
        return await decrementFeedInventory(farmId: farmId, feedItemId: formulaFeedItemId, amount: amount);
      }

      final List components = (meta['components'] as List);
      if (components.isEmpty) {
        debugPrint('consumeFormulaInventory: no components found in meta for $formulaFeedItemId');
        return false;
      }

      // Determine formula yield (units of recipe). Prefer explicit meta['yield'].
      double formulaYield = 0.0;
      if (meta['yield'] != null) {
        try {
          formulaYield = (meta['yield'] as num).toDouble();
        } catch (_) {
          formulaYield = 0.0;
        }
      } else {
        // sum component quantities
        for (final c in components) {
          try {
            final q = (c['quantity'] as num).toDouble();
            formulaYield += q;
          } catch (_) {}
        }
      }
      if (formulaYield <= 0) {
        debugPrint('consumeFormulaInventory: invalid formula yield for $formulaFeedItemId');
        return false;
      }

      // multiplier: how many recipe-yields we are consuming
      final multiplier = amount / formulaYield;

      // Attempt to decrement each component proportional to multiplier
      bool allOk = true;
      for (final comp in components) {
        final compFeedId = (comp['feed_item_id'] ?? '').toString();
        if (compFeedId.isEmpty) {
          debugPrint('consumeFormulaInventory: component missing feed_item_id: $comp');
          allOk = false;
          continue;
        }
        final compQtyRaw = comp['quantity'];
        if (compQtyRaw == null) {
          debugPrint('consumeFormulaInventory: component missing quantity: $comp');
          allOk = false;
          continue;
        }
        final compQty = (compQtyRaw as num).toDouble();
        final compUnit = (comp['unit'] ?? formula['unit'] ?? 'kg').toString();

        // required amount of this ingredient to consume
        double required = compQty * multiplier;

        // Inventory is stored with some unit; we need to fetch inventory row to know inventory unit.
        final invRow = await fetchInventoryRow(farmId: farmId, feedItemId: compFeedId);
        if (invRow == null) {
          debugPrint('consumeFormulaInventory: no inventory row for ingredient $compFeedId');
          // best-effort: still try to patch (will likely fail)
          final ok = await decrementFeedInventory(farmId: farmId, feedItemId: compFeedId, amount: required);
          if (!ok) allOk = false;
          continue;
        }
        final invUnit = (invRow['unit'] ?? compUnit ?? 'kg').toString();

        double amountToDecrement = required;
        if (compUnit != invUnit) {
          final conv = _convertUnit(required, compUnit, invUnit);
          if (conv == null) {
            debugPrint('consumeFormulaInventory: cannot convert unit from $compUnit to $invUnit for comp $compFeedId');
            // try to decrement using requested unit anyway (likely wrong)
            amountToDecrement = required;
          } else {
            amountToDecrement = conv;
          }
        }

        final ok = await decrementFeedInventory(
          farmId: farmId,
          feedItemId: compFeedId,
          amount: amountToDecrement,
        );
        if (!ok) {
          debugPrint('consumeFormulaInventory: failed to decrement ingredient $compFeedId by $amountToDecrement $invUnit');
          allOk = false;
        }
      }

      return allOk;
    } catch (e) {
      debugPrint('consumeFormulaInventory error: $e');
      return false;
    }
  }

  /// Patch arbitrary fields on a feed_items record (convenience wrapper).
  Future<bool> patchFeedItemFields({
    required String feedItemId,
    required Map<String, dynamic> fields,
  }) async {
    final url = '$SUPABASE_URL/rest/v1/feed_items?id=eq.$feedItemId';
    try {
      final resp = await http.patch(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
        body: json.encode(fields),
      );
      debugPrint('patchFeedItemFields status: ${resp.statusCode} body: ${resp.body}');
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('patchFeedItemFields error: $e');
      return false;
    }
  }

  /// Update feed_item record's meta (patch). Returns true on success.
  Future<bool> updateFeedItemMeta({
    required String feedItemId,
    required Map<String, dynamic> meta,
  }) async {
    final url = '$SUPABASE_URL/rest/v1/feed_items?id=eq.$feedItemId';
    try {
      final resp = await http.patch(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
        body: json.encode({'meta': meta}),
      );
      debugPrint('updateFeedItemMeta status: ${resp.statusCode} body: ${resp.body}');
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('updateFeedItemMeta error: $e');
      return false;
    }
  }

  // Fetch feed inventory for a farm (joins feed_items where possible)
  Future<List<Map<String, dynamic>>> fetchFeedInventory({String? farmId}) async {
    final url = (farmId == null || farmId.isEmpty)
        ? '$SUPABASE_URL/rest/v1/feed_inventory?select=*,feed_item:feed_items(name,unit,cost_per_unit)&order=updated_at.desc'
        : '$SUPABASE_URL/rest/v1/feed_inventory?select=*,feed_item:feed_items(name,unit,cost_per_unit)&farm_id=eq.$farmId&order=updated_at.desc';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // Fetch a single inventory row for farm+feed_item
  Future<Map<String, dynamic>?> fetchInventoryRow({
    required String farmId,
    required String feedItemId,
  }) async {
    final url =
        '$SUPABASE_URL/rest/v1/feed_inventory?select=*&farm_id=eq.$farmId&feed_item_id=eq.$feedItemId';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List && parsed.isNotEmpty) {
      return Map<String, dynamic>.from(parsed.first as Map);
    }
    return null;
  }

  // Upsert inventory row for a feed item (update if exists for farm+feed_item, else insert)
  Future<bool> upsertFeedInventory({
    required String farmId,
    required String feedItemId,
    required double quantity,
    String unit = 'kg',
    DateTime? expiry,
    String? quality,
    Map<String, dynamic>? meta,
  }) async {
    try {
      // Check for existing row
      final checkUrl =
          '$SUPABASE_URL/rest/v1/feed_inventory?select=id&farm_id=eq.$farmId&feed_item_id=eq.$feedItemId';
      final checkParsed = await api.httpGetParsed(checkUrl);
      if (checkParsed is List && checkParsed.isNotEmpty) {
        // update existing
        final url =
            '$SUPABASE_URL/rest/v1/feed_inventory?farm_id=eq.$farmId&feed_item_id=eq.$feedItemId';
        final body = {
          'quantity': quantity,
          'unit': unit,
          if (expiry != null) 'expiry_date': expiry.toIso8601String().split('T')[0],
          if (quality != null) 'quality': quality,
          if (meta != null) 'meta': meta,
        };
        debugPrint('upsertFeedInventory patch body: ${json.encode(body)}');
        final resp = await http.patch(
          Uri.parse(url),
          headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
          body: json.encode(body),
        );
        debugPrint('upsertFeedInventory patch status: ${resp.statusCode} body: ${resp.body}');
        return resp.statusCode >= 200 && resp.statusCode < 300;
      } else {
        // insert
        final url = '$SUPABASE_URL/rest/v1/feed_inventory';
        final body = {
          'farm_id': farmId,
          'feed_item_id': feedItemId,
          'quantity': quantity,
          'unit': unit,
          if (expiry != null) 'expiry_date': expiry.toIso8601String().split('T')[0],
          if (quality != null) 'quality': quality,
          if (meta != null) 'meta': meta,
        };
        debugPrint('upsertFeedInventory post body: ${json.encode([body])}');
        final resp = await http.post(
          Uri.parse(url),
          headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
          body: json.encode([body]),
        );
        debugPrint('upsertFeedInventory post status: ${resp.statusCode} body: ${resp.body}');
        return resp.statusCode >= 200 && resp.statusCode < 300;
      }
    } catch (e) {
      debugPrint('upsertFeedInventory error: $e');
      return false;
    }
  }

  // Decrement inventory quantity for a feed item (best-effort).
  // Assumes the units are compatible (you should ensure consistent units).
  Future<bool> decrementFeedInventory({
    required String farmId,
    required String feedItemId,
    required double amount,
  }) async {
    try {
      final row = await fetchInventoryRow(farmId: farmId, feedItemId: feedItemId);
      if (row == null) {
        debugPrint('decrementFeedInventory: no inventory row found for feed_item $feedItemId on farm $farmId');
        return false;
      }
      final current = double.tryParse((row['quantity'] ?? '0').toString()) ?? 0.0;
      final newQty = (current - amount);
      // Allow negative? clamp at 0 (here we clamp to 0)
      final finalQty = newQty < 0 ? 0.0 : newQty;

      final url = '$SUPABASE_URL/rest/v1/feed_inventory?id=eq.${row['id']}';
      final body = {'quantity': finalQty};
      debugPrint('decrementFeedInventory patch id=${row['id']} body: ${json.encode(body)}');
      final resp = await http.patch(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true, preferRepresentation: false),
        body: json.encode(body),
      );
      debugPrint('decrementFeedInventory status: ${resp.statusCode} body: ${resp.body}');
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('decrementFeedInventory error: $e');
      return false;
    }
  }

  // Create feed transaction (returns created record map or null)
  Future<Map<String, dynamic>?> createFeedTransaction({
    required String farmId,
    required String feedItemId,
    required double quantity,
    String unit = '',
    String? singleAnimalId,
    double? unitCost,
    String? createdByUserId,
    String? note,
    Map<String, dynamic>? meta,
  }) async {
    final body = {
      'farm_id': farmId,
      'feed_item_id': feedItemId,
      'quantity': quantity,
      if (unit.isNotEmpty) 'unit': unit,
      if (singleAnimalId != null && singleAnimalId.isNotEmpty)
        'animal_id': singleAnimalId,
      if (unitCost != null) 'unit_cost': unitCost,
      if (createdByUserId != null) 'created_by': createdByUserId,
      if (note != null) 'note': note,
      if (meta != null) 'meta': meta,
    };

    final url = '$SUPABASE_URL/rest/v1/feed_transactions';
    try {
      final resp = await http.post(
        Uri.parse(url),
        headers: _buildHeaders(
          jsonBody: true,
          preferRepresentation: true,
          preferResolution: 'merge-duplicates',
        ),
        body: json.encode([body]), // Supabase expects array for insert
      );

      debugPrint(
        'createFeedTransaction status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          resp.body.isNotEmpty) {
        final parsed = json.decode(resp.body);
        if (parsed is List && parsed.isNotEmpty) {
          return Map<String, dynamic>.from(parsed.first as Map);
        } else if (parsed is Map) {
          return Map<String, dynamic>.from(parsed);
        }
      }
    } catch (e) {
      debugPrint('createFeedTransaction error: $e');
    }
    return null;
  }

  // Fetch feed transactions (optionally by farm and/or animal)
  Future<List<Map<String, dynamic>>> fetchFeedTransactions({
    String? farmId,
    String? animalId,
    int limit = 500,
  }) async {
    final parts = <String>[];
    if (farmId != null && farmId.isNotEmpty) parts.add('farm_id=eq.$farmId');
    if (animalId != null && animalId.isNotEmpty) parts.add('animal_id=eq.$animalId');
    final where = parts.isNotEmpty ? '&' + parts.join('&') : '';
    final url =
        '$SUPABASE_URL/rest/v1/feed_transactions?select=*,feed_item:feed_items(name,unit,cost_per_unit)&order=created_at.desc&limit=$limit$where';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // Convenience wrapper for recording single-animal feed.
  // This now tries to detect formulas and consume ingredients proportionally.
  Future<Map<String, dynamic>?> recordAnimalFeed({
    required String farmId,
    required String animalId,
    required String feedItemId,
    required double quantity,
    String unit = 'kg',
    double? unitCost,
    String? note,
  }) async {
    // 1) create feed transaction
    final tx = await createFeedTransaction(
      farmId: farmId,
      feedItemId: feedItemId,
      quantity: quantity,
      unit: unit,
      singleAnimalId: animalId,
      unitCost: unitCost,
      note: note,
    );

    if (tx == null) {
      debugPrint('recordAnimalFeed: failed to create feed transaction');
      return null;
    }

    // 2) try to decrement inventory (best-effort; don't fail TX if inventory not found)
    try {
      // check if feed_item is a formula
      final feedItem = await fetchFeedItemById(feedItemId);
      final meta = feedItem != null ? feedItem['meta'] : null;
      if (meta is Map && meta['is_formula'] == true) {
        // consume ingredients proportionally
        final ok = await consumeFormulaInventory(
          farmId: farmId,
          formulaFeedItemId: feedItemId,
          amount: quantity,
        );
        if (!ok) {
          debugPrint('recordAnimalFeed: formula consumption failed for feedItemId=$feedItemId farmId=$farmId');
        }
      } else {
        final ok = await decrementFeedInventory(
          farmId: farmId,
          feedItemId: feedItemId,
          amount: quantity,
        );
        if (!ok) {
          debugPrint('recordAnimalFeed: inventory decrement failed for feedItemId=$feedItemId farmId=$farmId');
        }
      }
    } catch (e) {
      debugPrint('recordAnimalFeed: inventory decrement error: $e');
    }

    // return created tx
    return tx;
  }

  // Call RPC allocate_feed_transaction via Supabase REST RPC endpoint
  Future<bool> allocateFeedTransaction({
    required String feedTxId,
    required String method,
    List<String>? animalIds,
    List<double>? manualProps,
  }) async {
    final url = '$SUPABASE_URL/rest/v1/rpc/allocate_feed_transaction';
    final body = <String, dynamic>{
      'p_feed_tx_id': feedTxId,
      'p_method': method,
    };
    if (animalIds != null && animalIds.isNotEmpty) {
      body['p_animal_ids'] = animalIds;
    }
    if (manualProps != null && manualProps.isNotEmpty) {
      body['p_manual_props'] = manualProps;
    }

    try {
      final resp = await http.post(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true),
        body: json.encode(body),
      );
      debugPrint(
        'allocateFeedTransaction status: ${resp.statusCode} body: ${resp.body}',
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('allocateFeedTransaction error: $e');
      return false;
    }
  }

  // Create a financial record (expense/income)
  Future<Map<String, dynamic>?> createFinancialRecord({
    required String farmId,
    required String type,
    required double amount,
    String currency = 'USD',
    String? description,
    String? animalId,
    String? createdBy,
    Map<String, dynamic>? meta,
  }) async {
    final body = {
      'farm_id': farmId,
      'type': type,
      'amount': amount,
      'currency': currency,
      if (description != null) 'vendor': description,
      if (animalId != null) 'animal_id': animalId,
      if (createdBy != null) 'created_by': createdBy,
      if (meta != null) 'meta': meta,
    };

    final url = '$SUPABASE_URL/rest/v1/financial_records';
    try {
      final resp = await http.post(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
        body: json.encode([body]),
      );
      debugPrint('createFinancialRecord request body: ${json.encode([body])}');

      debugPrint(
        'createFinancialRecord status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          resp.body.isNotEmpty) {
        final parsed = json.decode(resp.body);
        if (parsed is List && parsed.isNotEmpty)
          return Map<String, dynamic>.from(parsed.first as Map);
        if (parsed is Map) return Map<String, dynamic>.from(parsed);
      }
    } catch (e) {
      debugPrint('createFinancialRecord error: $e');
    }
    return null;
  }

  // Upsert farm milk price using farm_settings
  Future<bool> setFarmMilkPrice(String farmId, double price) async {
    try {
      final checkUrl =
          '$SUPABASE_URL/rest/v1/farm_settings?select=id&farm_id=eq.$farmId&key=eq.milk_price_per_unit';
      final checkParsed = await api.httpGetParsed(checkUrl);
      if (checkParsed is List && checkParsed.isNotEmpty) {
        // update
        final url =
            '$SUPABASE_URL/rest/v1/farm_settings?farm_id=eq.$farmId&key=eq.milk_price_per_unit';
        final body = {'value': price};
        final resp = await http.patch(
          Uri.parse(url),
          headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
          body: json.encode(body),
        );
        debugPrint(
          'setFarmMilkPrice update status: ${resp.statusCode} body: ${resp.body}',
        );
        return resp.statusCode >= 200 && resp.statusCode < 300;
      } else {
        // insert
        final url = '$SUPABASE_URL/rest/v1/farm_settings';
        final body = {
          'farm_id': farmId,
          'key': 'milk_price_per_unit',
          'value': price,
        };
        final resp = await http.post(
          Uri.parse(url),
          headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
          body: json.encode([body]),
        );
        debugPrint(
          'setFarmMilkPrice insert status: ${resp.statusCode} body: ${resp.body}',
        );
        return resp.statusCode >= 200 && resp.statusCode < 300;
      }
    } catch (e) {
      debugPrint('setFarmMilkPrice error: $e');
      return false;
    }
  }

  // Fetch a single animal by tag or ID
  Future<Map<String, dynamic>?> fetchAnimalByTag(
    String farmId,
    String tag,
  ) async {
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=eq.$farmId&tag=eq.$tag';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List && parsed.isNotEmpty) {
      return Map<String, dynamic>.from(parsed.first as Map);
    }
    return null;
  }
}















/*
// lib/api_fill_net.dart
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;

import 'api_service.dart';
import 'supabase_config.dart';

class FillNetApi {
  final ApiService api;
  FillNetApi(this.api);

  // --- Helper to build the same headers ApiService would build ---
  Map<String, String> _buildHeaders({
    bool jsonBody = false,
    bool preferRepresentation = false,
    String? preferResolution,
  }) {
    final headers = <String, String>{
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer ${api.token}',
      'Accept': 'application/json',
    };
    if (jsonBody) headers['Content-Type'] = 'application/json';
    if (preferRepresentation) {
      var pref = 'return=representation';
      if (preferResolution != null && preferResolution.isNotEmpty) {
        pref += ',$preferResolution';
      }
      headers['Prefer'] = pref;
    }
    return headers;
  }

  // Fetch farms the current user can access
  Future<List<Map<String, dynamic>>> fetchFarmsForUser() async {
    final farms = <Map<String, dynamic>>[];
    try {
      final farmIds = await api.getUserFarmIds();
      if (farmIds.isEmpty) return farms;
      final enc = Uri.encodeComponent('(${farmIds.join(",")})');
      final url =
          '$SUPABASE_URL/rest/v1/farms?select=id,name&order=name&id=in.$enc';
      final parsed = await api.httpGetParsed(url);
      if (parsed is List) {
        return parsed
            .map<Map<String, dynamic>>(
              (e) => Map<String, dynamic>.from(e as Map),
            )
            .toList();
      }
    } catch (e) {
      debugPrint('fetchFarmsForUser error: $e');
    }
    return farms;
  }

  // Fetch animals for given farm id
  Future<List<Map<String, dynamic>>> fetchAnimalsForFarm(String farmId) async {
    if (farmId.isEmpty) return [];
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=id,tag,name,weight&farm_id=eq.$farmId&order=tag';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // Fetch all feed items for farm (or global)
  Future<List<Map<String, dynamic>>> fetchFeedItems({String? farmId}) async {
    final url = farmId == null || farmId.isEmpty
        ? '$SUPABASE_URL/rest/v1/feed_items?select=id,name,unit,cost_per_unit&order=name'
        : '$SUPABASE_URL/rest/v1/feed_items?select=id,name,unit,cost_per_unit&farm_id=eq.$farmId&order=name';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // Create feed item (catalog)
  Future<Map<String, dynamic>?> createFeedItem({
    required String farmId,
    required String name,
    String unit = 'kg',
    double? costPerUnit,
  }) async {
    final body = {
      'farm_id': farmId,
      'name': name,
      'unit': unit,
      if (costPerUnit != null) 'cost_per_unit': costPerUnit,
    };
    final url = '$SUPABASE_URL/rest/v1/feed_items';
    try {
      debugPrint('createFeedItem body: ${json.encode([body])}');
      final resp = await http.post(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
        body: json.encode([body]),
      );
      debugPrint('createFeedItem status: ${resp.statusCode} body: ${resp.body}');
      if (resp.statusCode >= 200 && resp.statusCode < 300 && resp.body.isNotEmpty) {
        final parsed = json.decode(resp.body);
        if (parsed is List && parsed.isNotEmpty) return Map<String, dynamic>.from(parsed.first as Map);
        if (parsed is Map) return Map<String, dynamic>.from(parsed);
      }
    } catch (e) {
      debugPrint('createFeedItem error: $e');
    }
    return null;
  }

  // Fetch feed inventory for a farm (joins feed_items where possible)
  Future<List<Map<String, dynamic>>> fetchFeedInventory({String? farmId}) async {
    final url = (farmId == null || farmId.isEmpty)
        ? '$SUPABASE_URL/rest/v1/feed_inventory?select=*,feed_item:feed_items(name,unit,cost_per_unit)&order=updated_at.desc'
        : '$SUPABASE_URL/rest/v1/feed_inventory?select=*,feed_item:feed_items(name,unit,cost_per_unit)&farm_id=eq.$farmId&order=updated_at.desc';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // Fetch a single inventory row for farm+feed_item
  Future<Map<String, dynamic>?> fetchInventoryRow({
    required String farmId,
    required String feedItemId,
  }) async {
    final url =
        '$SUPABASE_URL/rest/v1/feed_inventory?select=*&farm_id=eq.$farmId&feed_item_id=eq.$feedItemId';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List && parsed.isNotEmpty) {
      return Map<String, dynamic>.from(parsed.first as Map);
    }
    return null;
  }

  // Upsert inventory row for a feed item (update if exists for farm+feed_item, else insert)
  Future<bool> upsertFeedInventory({
    required String farmId,
    required String feedItemId,
    required double quantity,
    String unit = 'kg',
    DateTime? expiry,
    String? quality,
    Map<String, dynamic>? meta,
  }) async {
    try {
      // Check for existing row
      final checkUrl =
          '$SUPABASE_URL/rest/v1/feed_inventory?select=id&farm_id=eq.$farmId&feed_item_id=eq.$feedItemId';
      final checkParsed = await api.httpGetParsed(checkUrl);
      if (checkParsed is List && checkParsed.isNotEmpty) {
        // update existing
        final url =
            '$SUPABASE_URL/rest/v1/feed_inventory?farm_id=eq.$farmId&feed_item_id=eq.$feedItemId';
        final body = {
          'quantity': quantity,
          'unit': unit,
          if (expiry != null) 'expiry_date': expiry.toIso8601String().split('T')[0],
          if (quality != null) 'quality': quality,
          if (meta != null) 'meta': meta,
        };
        debugPrint('upsertFeedInventory patch body: ${json.encode(body)}');
        final resp = await http.patch(
          Uri.parse(url),
          headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
          body: json.encode(body),
        );
        debugPrint('upsertFeedInventory patch status: ${resp.statusCode} body: ${resp.body}');
        return resp.statusCode >= 200 && resp.statusCode < 300;
      } else {
        // insert
        final url = '$SUPABASE_URL/rest/v1/feed_inventory';
        final body = {
          'farm_id': farmId,
          'feed_item_id': feedItemId,
          'quantity': quantity,
          'unit': unit,
          if (expiry != null) 'expiry_date': expiry.toIso8601String().split('T')[0],
          if (quality != null) 'quality': quality,
          if (meta != null) 'meta': meta,
        };
        debugPrint('upsertFeedInventory post body: ${json.encode([body])}');
        final resp = await http.post(
          Uri.parse(url),
          headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
          body: json.encode([body]),
        );
        debugPrint('upsertFeedInventory post status: ${resp.statusCode} body: ${resp.body}');
        return resp.statusCode >= 200 && resp.statusCode < 300;
      }
    } catch (e) {
      debugPrint('upsertFeedInventory error: $e');
      return false;
    }
  }

  // Decrement inventory quantity for a feed item (best-effort).
  // Assumes the units are compatible (you should ensure consistent units).
  Future<bool> decrementFeedInventory({
    required String farmId,
    required String feedItemId,
    required double amount,
  }) async {
    try {
      final row = await fetchInventoryRow(farmId: farmId, feedItemId: feedItemId);
      if (row == null) {
        debugPrint('decrementFeedInventory: no inventory row found for feed_item $feedItemId on farm $farmId');
        return false;
      }
      final current = double.tryParse((row['quantity'] ?? '0').toString()) ?? 0.0;
      final newQty = (current - amount);
      // Allow negative? clamp at 0 (here we clamp to 0)
      final finalQty = newQty < 0 ? 0.0 : newQty;

      final url = '$SUPABASE_URL/rest/v1/feed_inventory?id=eq.${row['id']}';
      final body = {'quantity': finalQty};
      debugPrint('decrementFeedInventory patch id=${row['id']} body: ${json.encode(body)}');
      final resp = await http.patch(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true, preferRepresentation: false),
        body: json.encode(body),
      );
      debugPrint('decrementFeedInventory status: ${resp.statusCode} body: ${resp.body}');
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('decrementFeedInventory error: $e');
      return false;
    }
  }

  // Create feed transaction (returns created record map or null)
  Future<Map<String, dynamic>?> createFeedTransaction({
    required String farmId,
    required String feedItemId,
    required double quantity,
    String unit = '',
    String? singleAnimalId,
    double? unitCost,
    String? createdByUserId,
    String? note,
    Map<String, dynamic>? meta,
  }) async {
    final body = {
      'farm_id': farmId,
      'feed_item_id': feedItemId,
      'quantity': quantity,
      if (unit.isNotEmpty) 'unit': unit,
      if (singleAnimalId != null && singleAnimalId.isNotEmpty)
        'animal_id': singleAnimalId,
      if (unitCost != null) 'unit_cost': unitCost,
      if (createdByUserId != null) 'created_by': createdByUserId,
      if (note != null) 'note': note,
      if (meta != null) 'meta': meta,
    };

    final url = '$SUPABASE_URL/rest/v1/feed_transactions';
    try {
      final resp = await http.post(
        Uri.parse(url),
        headers: _buildHeaders(
          jsonBody: true,
          preferRepresentation: true,
          preferResolution: 'merge-duplicates',
        ),
        body: json.encode([body]), // Supabase expects array for insert
      );

      debugPrint(
        'createFeedTransaction status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          resp.body.isNotEmpty) {
        final parsed = json.decode(resp.body);
        if (parsed is List && parsed.isNotEmpty) {
          return Map<String, dynamic>.from(parsed.first as Map);
        } else if (parsed is Map) {
          return Map<String, dynamic>.from(parsed);
        }
      }
    } catch (e) {
      debugPrint('createFeedTransaction error: $e');
    }
    return null;
  }

  // Fetch feed transactions (optionally by farm and/or animal)
  Future<List<Map<String, dynamic>>> fetchFeedTransactions({
    String? farmId,
    String? animalId,
    int limit = 500,
  }) async {
    final parts = <String>[];
    if (farmId != null && farmId.isNotEmpty) parts.add('farm_id=eq.$farmId');
    if (animalId != null && animalId.isNotEmpty) parts.add('animal_id=eq.$animalId');
    final where = parts.isNotEmpty ? '&' + parts.join('&') : '';
    final url =
        '$SUPABASE_URL/rest/v1/feed_transactions?select=*,feed_item:feed_items(name,unit,cost_per_unit)&order=created_at.desc&limit=$limit$where';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List) {
      return parsed
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    return [];
  }

  // Convenience wrapper for recording single-animal feed.
  // This now also tries to decrement farm inventory for the feed_item (best-effort).
  Future<Map<String, dynamic>?> recordAnimalFeed({
    required String farmId,
    required String animalId,
    required String feedItemId,
    required double quantity,
    String unit = 'kg',
    double? unitCost,
    String? note,
  }) async {
    // 1) create feed transaction
    final tx = await createFeedTransaction(
      farmId: farmId,
      feedItemId: feedItemId,
      quantity: quantity,
      unit: unit,
      singleAnimalId: animalId,
      unitCost: unitCost,
      note: note,
    );

    if (tx == null) {
      debugPrint('recordAnimalFeed: failed to create feed transaction');
      return null;
    }

    // 2) try to decrement inventory (best-effort; don't fail TX if inventory not found)
    try {
      final ok = await decrementFeedInventory(
        farmId: farmId,
        feedItemId: feedItemId,
        amount: quantity,
      );
      if (!ok) {
        debugPrint('recordAnimalFeed: inventory decrement failed for feedItemId=$feedItemId farmId=$farmId');
      }
    } catch (e) {
      debugPrint('recordAnimalFeed: inventory decrement error: $e');
    }

    // return created tx
    return tx;
  }

  // Call RPC allocate_feed_transaction via Supabase REST RPC endpoint
  Future<bool> allocateFeedTransaction({
    required String feedTxId,
    required String method,
    List<String>? animalIds,
    List<double>? manualProps,
  }) async {
    final url = '$SUPABASE_URL/rest/v1/rpc/allocate_feed_transaction';
    final body = <String, dynamic>{
      'p_feed_tx_id': feedTxId,
      'p_method': method,
    };
    if (animalIds != null && animalIds.isNotEmpty) {
      body['p_animal_ids'] = animalIds;
    }
    if (manualProps != null && manualProps.isNotEmpty) {
      body['p_manual_props'] = manualProps;
    }

    try {
      final resp = await http.post(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true),
        body: json.encode(body),
      );
      debugPrint(
        'allocateFeedTransaction status: ${resp.statusCode} body: ${resp.body}',
      );
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('allocateFeedTransaction error: $e');
      return false;
    }
  }

  // Create a financial record (expense/income)
  Future<Map<String, dynamic>?> createFinancialRecord({
    required String farmId,
    required String type,
    required double amount,
    String currency = 'USD',
    String? description,
    String? animalId,
    String? createdBy,
    Map<String, dynamic>? meta,
  }) async {
    final body = {
      'farm_id': farmId,
      'type': type,
      'amount': amount,
      'currency': currency,
      if (description != null) 'vendor': description,
      if (animalId != null) 'animal_id': animalId,
      if (createdBy != null) 'created_by': createdBy,
      if (meta != null) 'meta': meta,
    };

    final url = '$SUPABASE_URL/rest/v1/financial_records';
    try {
      final resp = await http.post(
        Uri.parse(url),
        headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
        body: json.encode([body]),
      );
      debugPrint('createFinancialRecord request body: ${json.encode([body])}');

      debugPrint(
        'createFinancialRecord status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 &&
          resp.statusCode < 300 &&
          resp.body.isNotEmpty) {
        final parsed = json.decode(resp.body);
        if (parsed is List && parsed.isNotEmpty)
          return Map<String, dynamic>.from(parsed.first as Map);
        if (parsed is Map) return Map<String, dynamic>.from(parsed);
      }
    } catch (e) {
      debugPrint('createFinancialRecord error: $e');
    }
    return null;
  }

  // Upsert farm milk price using farm_settings
  Future<bool> setFarmMilkPrice(String farmId, double price) async {
    try {
      final checkUrl =
          '$SUPABASE_URL/rest/v1/farm_settings?select=id&farm_id=eq.$farmId&key=eq.milk_price_per_unit';
      final checkParsed = await api.httpGetParsed(checkUrl);
      if (checkParsed is List && checkParsed.isNotEmpty) {
        // update
        final url =
            '$SUPABASE_URL/rest/v1/farm_settings?farm_id=eq.$farmId&key=eq.milk_price_per_unit';
        final body = {'value': price};
        final resp = await http.patch(
          Uri.parse(url),
          headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
          body: json.encode(body),
        );
        debugPrint(
          'setFarmMilkPrice update status: ${resp.statusCode} body: ${resp.body}',
        );
        return resp.statusCode >= 200 && resp.statusCode < 300;
      } else {
        // insert
        final url = '$SUPABASE_URL/rest/v1/farm_settings';
        final body = {
          'farm_id': farmId,
          'key': 'milk_price_per_unit',
          'value': price,
        };
        final resp = await http.post(
          Uri.parse(url),
          headers: _buildHeaders(jsonBody: true, preferRepresentation: true),
          body: json.encode([body]),
        );
        debugPrint(
          'setFarmMilkPrice insert status: ${resp.statusCode} body: ${resp.body}',
        );
        return resp.statusCode >= 200 && resp.statusCode < 300;
      }
    } catch (e) {
      debugPrint('setFarmMilkPrice error: $e');
      return false;
    }
  }

  // Fetch a single animal by tag or ID
  Future<Map<String, dynamic>?> fetchAnimalByTag(
    String farmId,
    String tag,
  ) async {
    final url =
        '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=eq.$farmId&tag=eq.$tag';
    final parsed = await api.httpGetParsed(url);
    if (parsed is List && parsed.isNotEmpty) {
      return Map<String, dynamic>.from(parsed.first as Map);
    }
    return null;
  }
}
*/