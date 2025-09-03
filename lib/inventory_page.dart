// lib/inventory_page.dart
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';

import 'api_service.dart' as api_service;
import 'api_fill_net.dart';

class InventoryPage extends StatefulWidget {
  final api_service.ApiService apiService;
  const InventoryPage({super.key, required this.apiService});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _RecipeRow {
  String? feedItemId;
  double quantity;
  String unit;
  _RecipeRow({this.feedItemId, this.quantity = 0.0, this.unit = 'kg'});
}

class _InventoryPageState extends State<InventoryPage> {
  late final FillNetApi _api;
  bool _loading = false;

  List<Map<String, dynamic>> _farms = [];
  String? _selectedFarmId;

  // feed items (catalog) - used for selecting ingredients in recipe
  List<Map<String, dynamic>> _feedItems = [];

  // inventory rows for farm
  List<Map<String, dynamic>> _inventory = [];

  // --- Add Ingredient controls (purchase) ---
  final TextEditingController _ingNameCtl = TextEditingController();
  final TextEditingController _ingQtyCtl = TextEditingController();
  final TextEditingController _ingUnitCtl = TextEditingController(text: 'kg');
  final TextEditingController _ingTotalCostCtl = TextEditingController();

  // --- Formula builder controls ---
  final TextEditingController _formulaNameCtl = TextEditingController();
  final List<_RecipeRow> _recipe = [];

  // Inventory edit controls
  String? _selectedInventoryFeedItemId;
  final TextEditingController _invQtyCtl = TextEditingController();
  final TextEditingController _invUnitCtl = TextEditingController(text: 'kg');
  final TextEditingController _invQualityCtl = TextEditingController();
  final TextEditingController _invPriceCtl = TextEditingController(); // price per unit for edit

  @override
  void initState() {
    super.initState();
    _api = FillNetApi(widget.apiService);
    _loadFarmsAndData();
  }

  Future<void> _loadFarmsAndData() async {
    setState(() => _loading = true);
    try {
      final farms = await _api.fetchFarmsForUser();
      setState(() {
        _farms = farms;
        if (_farms.isNotEmpty && _selectedFarmId == null) {
          _selectedFarmId = (_farms.first['id'] ?? '').toString();
        }
      });
      await _reloadData();
    } catch (e) {
      debugPrint('loadFarms error: $e');
      _showSnack('Failed to load farms', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _reloadData() async {
    if (_selectedFarmId == null) return;
    setState(() => _loading = true);
    try {
      final items = await _api.fetchFeedItems(farmId: _selectedFarmId);
      final inv = await _api.fetchFeedInventory(farmId: _selectedFarmId);
      setState(() {
        _feedItems = items;
        _inventory = inv;
        if (_feedItems.isNotEmpty && _selectedInventoryFeedItemId == null) {
          _selectedInventoryFeedItemId = (_feedItems.first['id'] ?? '').toString();
        }
      });
    } catch (e) {
      debugPrint('reloadData error: $e');
      _showSnack('Failed to reload data', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  // ---------------- Add Ingredient (purchase) ----------------
  double? _computedUnitPrice() {
    final qty = double.tryParse(_ingQtyCtl.text.trim());
    final total = double.tryParse(_ingTotalCostCtl.text.trim());
    if (qty == null || qty <= 0 || total == null) return null;
    return total / qty;
  }

  Future<void> _saveIngredient() async {
    if (_selectedFarmId == null) {
      _showSnack('Select a farm first', error: true);
      return;
    }

    final name = _ingNameCtl.text.trim();
    final qty = double.tryParse(_ingQtyCtl.text.trim());
    final unit = _ingUnitCtl.text.trim().isEmpty ? 'kg' : _ingUnitCtl.text.trim();
    final totalCost = double.tryParse(_ingTotalCostCtl.text.trim());

    if (name.isEmpty || qty == null || qty <= 0 || totalCost == null) {
      _showSnack('Provide name, quantity (>0) and total cost', error: true);
      return;
    }

    final unitPrice = totalCost / qty;

    setState(() => _loading = true);
    try {
      // If an item with same name exists (case-insensitive) -> update price and upsert inventory
      final existing = _feedItems.firstWhere(
        (f) => (f['name'] ?? '').toString().toLowerCase() == name.toLowerCase(),
        orElse: () => {},
      );
      String feedItemId;
      if (existing.isNotEmpty && existing['id'] != null) {
        feedItemId = existing['id'].toString();
        // update price if different
        final prevPrice = existing['cost_per_unit'];
        final prevNum = prevPrice != null ? double.tryParse(prevPrice.toString()) ?? 0.0 : 0.0;
        if ((prevNum - unitPrice).abs() > 0.00001) {
          await _api.patchFeedItemFields(feedItemId: feedItemId, fields: {'cost_per_unit': unitPrice});
        }
      } else {
        final rec = await _api.createFeedItem(
          farmId: _selectedFarmId!,
          name: name,
          unit: unit,
          costPerUnit: unitPrice,
        );
        if (rec == null || rec['id'] == null) {
          _showSnack('Failed to create ingredient', error: true);
          return;
        }
        feedItemId = rec['id'].toString();
      }

      // add to inventory (quantity)
      final ok = await _api.upsertFeedInventory(
        farmId: _selectedFarmId!,
        feedItemId: feedItemId,
        quantity: qty,
        unit: unit,
        meta: {'purchased_total_cost': totalCost},
      );

      if (!ok) {
        _showSnack('Ingredient saved but failed to add to inventory', error: true);
      } else {
        _showSnack('Ingredient added', success: true);
      }

      _ingNameCtl.clear();
      _ingQtyCtl.clear();
      _ingUnitCtl.text = 'kg';
      _ingTotalCostCtl.clear();

      await _reloadData();
    } catch (e) {
      debugPrint('saveIngredient error: $e');
      _showSnack('Error saving ingredient', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  // ---------------- Formula builder ----------------
  void _addRecipeRow() => setState(() => _recipe.add(_RecipeRow()));

  void _removeRecipeRow(int idx) => setState(() => _recipe.removeAt(idx));

  // Compute formula cost per unit (kg)
  double? _computeFormulaCostPerUnit() {
    if (_recipe.isEmpty) return null;
    double totalQty = 0.0;
    double totalCost = 0.0;
    for (final r in _recipe) {
      if (r.feedItemId == null || r.feedItemId!.isEmpty || r.quantity <= 0) return null;
      final item = _feedItems.firstWhere(
        (f) => (f['id'] ?? '').toString() == r.feedItemId,
        orElse: () => {},
      );
      if (item.isEmpty) return null;
      final costVal = item['cost_per_unit'];
      if (costVal == null) return null;
      final cost = double.tryParse(costVal.toString()) ?? 0.0;
      totalQty += r.quantity;
      totalCost += cost * r.quantity;
    }
    if (totalQty <= 0) return null;
    return totalCost / totalQty;
  }

  Future<void> _saveFormula() async {
    if (_selectedFarmId == null) {
      _showSnack('Select a farm first', error: true);
      return;
    }

    final name = _formulaNameCtl.text.trim();
    if (name.isEmpty) {
      _showSnack('Provide a formula name', error: true);
      return;
    }
    if (_recipe.isEmpty) {
      _showSnack('Add at least one ingredient to the formula', error: true);
      return;
    }
    // validate recipe rows
    double totalQty = 0.0;
    final comps = <Map<String, dynamic>>[];
    for (final r in _recipe) {
      if (r.feedItemId == null || r.feedItemId!.isEmpty || r.quantity <= 0) {
        _showSnack('Each component needs an ingredient and positive qty', error: true);
        return;
      }
      comps.add({
        'feed_item_id': r.feedItemId,
        'quantity': r.quantity,
        'unit': r.unit,
      });
      totalQty += r.quantity;
    }
    if (totalQty <= 0) {
      _showSnack('Total formula quantity must be > 0', error: true);
      return;
    }
    final costPerUnit = _computeFormulaCostPerUnit();
    if (costPerUnit == null) {
      _showSnack('Cannot compute formula cost (missing ingredient prices)', error: true);
      return;
    }

    final meta = {
      'is_formula': true,
      'components': comps,
      'yield': totalQty,
    };

    setState(() => _loading = true);
    try {
      // If a formula with same name exists -> patch meta/price, else create.
      final existingFormula = _feedItems.firstWhere(
        (f) => (f['name'] ?? '').toString().toLowerCase() == name.toLowerCase(),
        orElse: () => {},
      );

      if (existingFormula.isNotEmpty && existingFormula['id'] != null) {
        final feedId = existingFormula['id'].toString();
        await _api.patchFeedItemFields(feedItemId: feedId, fields: {
          'cost_per_unit': costPerUnit,
          'unit': 'kg',
          'meta': meta,
        });
      } else {
        final rec = await _api.createFeedItem(
          farmId: _selectedFarmId!,
          name: name,
          unit: 'kg', // formula unit default
          costPerUnit: costPerUnit,
          meta: meta,
        );

        if (rec == null) {
          _showSnack('Failed to create formula', error: true);
          return;
        }
      }

      _formulaNameCtl.clear();
      _recipe.clear();
      await _reloadData();
      _showSnack('Formula saved', success: true);
    } catch (e) {
      debugPrint('saveFormula error: $e');
      _showSnack('Error saving formula', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  // ---------------- Inventory edit/delete ----------------
  Future<void> _openEditInventoryDialog(Map<String, dynamic> row) async {
    final feedItem = row['feed_item'] ?? {};
    final feedId = (feedItem['id'] ?? '').toString();
    final currentQty = row['quantity']?.toString() ?? '0';
    final currentUnit = (row['unit'] ?? 'kg').toString();
    final currentPrice = feedItem['cost_per_unit']?.toString() ?? '';

    _invQtyCtl.text = currentQty;
    _invUnitCtl.text = currentUnit;
    _invQualityCtl.text = (row['quality'] ?? '').toString();
    _invPriceCtl.text = currentPrice;
    _selectedInventoryFeedItemId = feedId;

    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text('Edit inventory: ${feedItem['name'] ?? 'item'}'),
          content: SingleChildScrollView(
            child: Column(
              children: [
                TextFormField(
                  controller: _invQtyCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _invUnitCtl,
                  decoration: const InputDecoration(labelText: 'Unit'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _invPriceCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Price per unit'),
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _invQualityCtl,
                  decoration: const InputDecoration(labelText: 'Quality (opt)'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () async {
                final newQty = double.tryParse(_invQtyCtl.text.trim());
                final newUnit = _invUnitCtl.text.trim().isEmpty ? 'kg' : _invUnitCtl.text.trim();
                final newPrice = double.tryParse(_invPriceCtl.text.trim());
                final newQuality = _invQualityCtl.text.trim().isEmpty ? null : _invQualityCtl.text.trim();

                if (newQty == null) {
                  _showSnack('Provide a valid quantity', error: true);
                  return;
                }

                setState(() => _loading = true);
                Navigator.of(ctx).pop();

                try {
                  // update price on feed_item if provided
                  if (newPrice != null) {
                    await _api.patchFeedItemFields(feedItemId: feedId, fields: {'cost_per_unit': newPrice});
                  }

                  // upsert inventory quantity/unit/quality
                  final ok = await _api.upsertFeedInventory(
                    farmId: _selectedFarmId ?? '',
                    feedItemId: feedId,
                    quantity: newQty,
                    unit: newUnit,
                    quality: newQuality,
                  );

                  if (ok) {
                    _showSnack('Inventory updated', success: true);
                    await _reloadData();
                  } else {
                    _showSnack('Failed to update inventory', error: true);
                  }
                } catch (e) {
                  debugPrint('editInventory error: $e');
                  _showSnack('Error updating inventory', error: true);
                } finally {
                  setState(() => _loading = false);
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDeleteInventory(Map<String, dynamic> row) async {
    final feedItem = row['feed_item'] ?? {};
    final feedId = (feedItem['id'] ?? '').toString();
    final name = (feedItem['name'] ?? 'item').toString();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Delete inventory'),
          content: Text('Set inventory for "$name" to 0? This will remove quantity but keep feed item.'),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Delete')),
          ],
        );
      },
    );

    if (ok != true) return;

    setState(() => _loading = true);
    try {
      final did = await _api.upsertFeedInventory(
        farmId: _selectedFarmId!,
        feedItemId: feedId,
        quantity: 0.0,
        unit: row['unit'] ?? 'kg',
      );
      if (did) {
        _showSnack('Inventory removed', success: true);
        await _reloadData();
      } else {
        _showSnack('Failed to remove inventory', error: true);
      }
    } catch (e) {
      debugPrint('deleteInventory error: $e');
      _showSnack('Error deleting inventory', error: true);
    } finally {
      setState(() => _loading = false);
    }
  }

  // ---------------- UI helpers ----------------
  void _showSnack(String msg, {bool error = false, bool success = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red : (success ? Colors.green : null),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  void dispose() {
    _ingNameCtl.dispose();
    _ingQtyCtl.dispose();
    _ingUnitCtl.dispose();
    _ingTotalCostCtl.dispose();
    _formulaNameCtl.dispose();
    _invQtyCtl.dispose();
    _invUnitCtl.dispose();
    _invQualityCtl.dispose();
    _invPriceCtl.dispose();
    super.dispose();
  }

  Widget _buildFarmSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Farm', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: _selectedFarmId,
          items: _farms.map((f) {
            final id = (f['id'] ?? '').toString();
            final name = (f['name'] ?? id).toString();
            return DropdownMenuItem(value: id, child: Text(name));
          }).toList(),
          onChanged: (v) {
            setState(() {
              _selectedFarmId = v;
            });
            _reloadData();
          },
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Select farm',
          ),
        ),
      ],
    );
  }

  Widget _buildAddIngredientSection() {
    final unitPrice = _computedUnitPrice();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Add purchased ingredient', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _ingNameCtl,
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Name'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: TextFormField(
                controller: _ingQtyCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Quantity'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 100,
              child: TextFormField(
                controller: _ingUnitCtl,
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Unit'),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 140,
              child: TextFormField(
                controller: _ingTotalCostCtl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Total cost'),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _saveIngredient, child: const Text('Save')),
          ],
        ),
        const SizedBox(height: 8),
        Text('Computed unit price: ${unitPrice == null ? '—' : unitPrice.toStringAsFixed(4)} per ${_ingUnitCtl.text}'),
      ],
    );
  }

  Widget _buildRecipeBuilderSection() {
    final costPerUnit = _computeFormulaCostPerUnit();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Create formula (recipe)', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextFormField(
                controller: _formulaNameCtl,
                decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Formula name'),
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _addRecipeRow, child: const Text('Add ingredient')),
            const SizedBox(width: 8),
            ElevatedButton(onPressed: _saveFormula, child: const Text('Save formula')),
          ],
        ),
        const SizedBox(height: 12),
        Column(
          children: _recipe.asMap().entries.map((entry) {
            final idx = entry.key;
            final row = entry.value;
            return Padding(
              key: ValueKey(idx),
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: row.feedItemId,
                      items: _feedItems.isEmpty
                          ? [
                              const DropdownMenuItem(value: null, child: Text('No ingredients available — add inventory first'))
                            ]
                          : _feedItems.map((f) {
                              final id = (f['id'] ?? '').toString();
                              final name = (f['name'] ?? '').toString();
                              final price = f['cost_per_unit'];
                              return DropdownMenuItem(
                                value: id,
                                child: Text('$name${price != null ? ' • ${price.toString()}' : ''}'),
                              );
                            }).toList(),
                      onChanged: (v) => setState(() => row.feedItemId = v),
                      decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Ingredient'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 120,
                    child: TextFormField(
                      initialValue: row.quantity == 0.0 ? '' : row.quantity.toString(),
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Qty'),
                      onChanged: (v) => row.quantity = double.tryParse(v) ?? 0.0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: TextFormField(
                      initialValue: row.unit,
                      decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Unit'),
                      onChanged: (v) => row.unit = v.trim().isEmpty ? 'kg' : v.trim(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _removeRecipeRow(idx)),
                ],
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        Text('Formula cost per unit: ${costPerUnit == null ? 'n/a (missing prices or components)' : costPerUnit.toStringAsFixed(4)}'),
      ],
    );
  }

  Widget _buildInventoryTable() {
    final rows = _inventory;
    double totalValue = 0.0;
    for (final r in rows) {
      final feedItem = r['feed_item'] ?? {};
      final price = feedItem['cost_per_unit'];
      final qty = double.tryParse((r['quantity'] ?? '0').toString()) ?? 0.0;
      final p = price != null ? double.tryParse(price.toString()) ?? 0.0 : 0.0;
      totalValue += p * qty;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Inventory (current)', style: TextStyle(fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (rows.isEmpty) const Text('No inventory rows yet.'),
        if (rows.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Name')),
                DataColumn(label: Text('Qty')),
                DataColumn(label: Text('Unit')),
                DataColumn(label: Text('Price/unit')),
                DataColumn(label: Text('Total value')),
                DataColumn(label: Text('Quality')),
                DataColumn(label: Text('Actions')),
              ],
              rows: rows.map((i) {
                final feedItem = i['feed_item'] ?? {};
                (feedItem['id'] ?? '').toString();
                final name = (feedItem['name'] ?? 'unknown').toString();
                final qty = i['quantity']?.toString() ?? '0';
                final unit = (i['unit'] ?? '').toString();
                final price = feedItem['cost_per_unit'];
                final priceNum = price != null ? double.tryParse(price.toString()) ?? 0.0 : 0.0;
                final total = priceNum * (double.tryParse(qty) ?? 0.0);
                final quality = i['quality'] ?? '';
                return DataRow(cells: [
                  DataCell(Text(name)),
                  DataCell(Text(qty)),
                  DataCell(Text(unit)),
                  DataCell(Text(price != null ? priceNum.toStringAsFixed(4) : 'n/a')),
                  DataCell(Text(total.toStringAsFixed(2))),
                  DataCell(Text(quality?.toString() ?? '')),
                  DataCell(Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit, size: 20),
                        onPressed: () => _openEditInventoryDialog(i),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => _confirmDeleteInventory(i),
                      ),
                    ],
                  )),
                ]);
              }).toList(),
            ),
          ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [Text('Inventory total value: ${totalValue.toStringAsFixed(2)}')],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory & Formula Builder'),
        actions: [
          IconButton(onPressed: _reloadData, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(12),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildFarmSelector(),
                    const SizedBox(height: 12),
                    _buildAddIngredientSection(),
                    const SizedBox(height: 18),
                    _buildRecipeBuilderSection(),
                    const SizedBox(height: 18),
                    _buildInventoryTable(),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
    );
  }
}
