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
  final TextEditingController qtyCtl = TextEditingController();

  _RecipeRow({this.feedItemId, this.quantity = 0.0, this.unit = 'kg'}) {
    qtyCtl.text = quantity == 0.0 ? '' : quantity.toString();
  }

  void dispose() => qtyCtl.dispose();
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

  // UI helpers
  String _inventorySearch = '';
  String _sortColumn = 'name'; // name | qty | price | value
  bool _sortAsc = true;

  @override
  void initState() {
    super.initState();
    _api = FillNetApi(widget.apiService);
    _loadFarmsAndData();
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
    for (final r in _recipe) r.dispose();
    super.dispose();
  }

  Future<void> _loadFarmsAndData() async {
    setState(() => _loading = true);
    try {
      final farms = await _api.fetchFarmsForUser();
      if (!mounted) return;
      setState(() {
        _farms = farms;
        if (_farms.isNotEmpty && _selectedFarmId == null) {
          _selectedFarmId = (_farms.first['id'] ?? '').toString();
        }
      });
      await _reloadData();
    } catch (e, st) {
      debugPrint('loadFarms error: $e\n$st');
      _showSnack('Failed to load farms', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reloadData() async {
    if (_selectedFarmId == null) return;
    setState(() => _loading = true);
    try {
      final items = await _api.fetchFeedItems(farmId: _selectedFarmId);
      final inv = await _api.fetchFeedInventory(farmId: _selectedFarmId);
      if (!mounted) return;
      setState(() {
        _feedItems = items;
        _inventory = inv;
        if (_feedItems.isNotEmpty && _selectedInventoryFeedItemId == null) {
          _selectedInventoryFeedItemId = (_feedItems.first['id'] ?? '').toString();
        }
      });
    } catch (e, st) {
      debugPrint('reloadData error: $e\n$st');
      _showSnack('Failed to reload data', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
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

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm purchase'),
        content: Text('Add $qty $unit of "$name" for total cost $totalCost ?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Add')),
        ],
      ),
    );

    if (confirm != true) return;

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
    } catch (e, st) {
      debugPrint('saveIngredient error: $e\n$st');
      _showSnack('Error saving ingredient', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------- Formula builder ----------------
  void _addRecipeRow() => setState(() => _recipe.add(_RecipeRow()));

  void _removeRecipeRow(int idx) {
    setState(() {
      _recipe[idx].dispose();
      _recipe.removeAt(idx);
    });
  }

  // Compute formula cost per unit (kg)
  double? _computeFormulaCostPerUnit() {
    if (_recipe.isEmpty) return null;
    double totalQty = 0.0;
    double totalCost = 0.0;
    for (final r in _recipe) {
      if (r.feedItemId == null || r.feedItemId!.isEmpty) return null;
      final item = _feedItems.firstWhere(
        (f) => (f['id'] ?? '').toString() == r.feedItemId,
        orElse: () => {},
      );
      if (item.isEmpty) return null;
      final costVal = item['cost_per_unit'];
      if (costVal == null) return null;
      final cost = double.tryParse(costVal.toString()) ?? 0.0;
      final qty = double.tryParse(r.qtyCtl.text.trim()) ?? 0.0;
      if (qty <= 0) return null;
      totalQty += qty;
      totalCost += cost * qty;
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
      final qty = double.tryParse(r.qtyCtl.text.trim()) ?? 0.0;
      if (r.feedItemId == null || r.feedItemId!.isEmpty || qty <= 0) {
        _showSnack('Each component needs an ingredient and positive qty', error: true);
        return;
      }
      comps.add({'feed_item_id': r.feedItemId, 'quantity': qty, 'unit': r.unit});
      totalQty += qty;
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

    final meta = {'is_formula': true, 'components': comps, 'yield': totalQty};

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save formula'),
        content: Text('Save formula "$name" with ${comps.length} components and cost/unit ${costPerUnit.toStringAsFixed(4)} ?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Save')),
        ],
      ),
    );

    if (confirm != true) return;

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
      for (final r in _recipe) r.dispose();
      _recipe.clear();
      await _reloadData();
      _showSnack('Formula saved', success: true);
    } catch (e, st) {
      debugPrint('saveFormula error: $e\n$st');
      _showSnack('Error saving formula', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
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
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _invQtyCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
                const SizedBox(height: 8),
                TextFormField(controller: _invUnitCtl, decoration: const InputDecoration(labelText: 'Unit')),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _invPriceCtl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Price per unit'),
                ),
                const SizedBox(height: 8),
                TextFormField(controller: _invQualityCtl, decoration: const InputDecoration(labelText: 'Quality (opt)')),
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
                } catch (e, st) {
                  debugPrint('editInventory error: $e\n$st');
                  _showSnack('Error updating inventory', error: true);
                } finally {
                  if (mounted) setState(() => _loading = false);
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
    } catch (e, st) {
      debugPrint('deleteInventory error: $e\n$st');
      _showSnack('Error deleting inventory', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------------- Helpers / UI ----------------
  void _showSnack(String msg, {bool error = false, bool success = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: error ? Colors.red : (success ? Colors.green : null),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _onSort(String column) {
    setState(() {
      if (_sortColumn == column) _sortAsc = !_sortAsc;
      _sortColumn = column;
    });
  }

  List<Map<String, dynamic>> get _filteredInventory {
    final q = _inventorySearch.trim().toLowerCase();
    var rows = _inventory.where((r) {
      final name = (r['feed_item']?['name'] ?? '').toString().toLowerCase();
      return name.contains(q);
    }).toList();

    rows.sort((a, b) {
      switch (_sortColumn) {
        case 'qty':
          final av = double.tryParse(a['quantity']?.toString() ?? '0') ?? 0.0;
          final bv = double.tryParse(b['quantity']?.toString() ?? '0') ?? 0.0;
          return _sortAsc ? av.compareTo(bv) : bv.compareTo(av);
        case 'price':
          final ap = double.tryParse(a['feed_item']?['cost_per_unit']?.toString() ?? '0') ?? 0.0;
          final bp = double.tryParse(b['feed_item']?['cost_per_unit']?.toString() ?? '0') ?? 0.0;
          return _sortAsc ? ap.compareTo(bp) : bp.compareTo(ap);
        case 'value':
          final av = (double.tryParse(a['feed_item']?['cost_per_unit']?.toString() ?? '0') ?? 0.0) * (double.tryParse(a['quantity']?.toString() ?? '0') ?? 0.0);
          final bv = (double.tryParse(b['feed_item']?['cost_per_unit']?.toString() ?? '0') ?? 0.0) * (double.tryParse(b['quantity']?.toString() ?? '0') ?? 0.0);
          return _sortAsc ? av.compareTo(bv) : bv.compareTo(av);
        case 'name':
        default:
          final an = (a['feed_item']?['name'] ?? '').toString().toLowerCase();
          final bn = (b['feed_item']?['name'] ?? '').toString().toLowerCase();
          return _sortAsc ? an.compareTo(bn) : bn.compareTo(an);
      }
    });

    return rows;
  }

  String _generateCsv() {
    final buf = StringBuffer();
    buf.writeln('name,qty,unit,price_per_unit,total_value,quality');
    for (final r in _filteredInventory) {
      final name = '"${(r['feed_item']?['name'] ?? '').toString().replaceAll('"', '""')}"';
      final qty = r['quantity']?.toString() ?? '0';
      final unit = (r['unit'] ?? '').toString();
      final price = r['feed_item']?['cost_per_unit']?.toString() ?? '';
      final total = (double.tryParse(price) ?? 0.0) * (double.tryParse(qty) ?? 0.0);
      final quality = (r['quality'] ?? '').toString();
      buf.writeln('$name,$qty,$unit,$price,${total.toStringAsFixed(2)},$quality');
    }
    return buf.toString();
  }

  Future<void> _showCsvDialog() async {
    final csv = _generateCsv();
    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Export CSV (copy)'),
        content: SingleChildScrollView(child: SelectableText(csv)),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('Close')),
        ],
      ),
    );
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
          decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Select farm'),
        ),
      ],
    );
  }

  Widget _buildAddIngredientSection(double maxWidth) {
    final unitPrice = _computedUnitPrice();
    final narrow = maxWidth < 700;
    final controls = [
      Expanded(
        child: TextFormField(controller: _ingNameCtl, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Name')),
      ),
      const SizedBox(width: 8),
      SizedBox(width: 120, child: TextFormField(controller: _ingQtyCtl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Quantity'))),
      const SizedBox(width: 8),
      SizedBox(width: 100, child: TextFormField(controller: _ingUnitCtl, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Unit'))),
      const SizedBox(width: 8),
      SizedBox(width: 140, child: TextFormField(controller: _ingTotalCostCtl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Total cost'))),
      const SizedBox(width: 8),
      ElevatedButton(onPressed: _saveIngredient, child: const Text('Save')),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Add purchased ingredient', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        narrow
            ? Column(children: controls)
            : Row(children: controls),
        const SizedBox(height: 8),
        Text('Computed unit price: ${unitPrice == null ? '—' : unitPrice.toStringAsFixed(4)} per ${_ingUnitCtl.text}'),
      ],
    );
  }

  Widget _buildRecipeBuilderSection(double maxWidth) {
    final costPerUnit = _computeFormulaCostPerUnit();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Create formula (recipe)', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: TextFormField(controller: _formulaNameCtl, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Formula name'))),
          const SizedBox(width: 8),
          ElevatedButton(onPressed: _addRecipeRow, child: const Text('Add ingredient')),
          const SizedBox(width: 8),
          ElevatedButton(onPressed: _saveFormula, child: const Text('Save formula')),
        ]),
        const SizedBox(height: 12),
        Column(children: _recipe.asMap().entries.map((entry) {
          final idx = entry.key;
          final row = entry.value;
          return Padding(
            key: ValueKey(idx),
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: row.feedItemId,
                  items: _feedItems.isEmpty
                      ? [const DropdownMenuItem(value: null, child: Text('No ingredients available — add inventory first'))]
                      : _feedItems.map((f) {
                          final id = (f['id'] ?? '').toString();
                          final name = (f['name'] ?? '').toString();
                          final price = f['cost_per_unit'];
                          return DropdownMenuItem(value: id, child: Text('$name${price != null ? ' • ${price.toString()}' : ''}'));
                        }).toList(),
                  onChanged: (v) => setState(() => row.feedItemId = v),
                  decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Ingredient'),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(width: 120, child: TextFormField(controller: row.qtyCtl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Qty'))),
              const SizedBox(width: 8),
              SizedBox(width: 90, child: TextFormField(initialValue: row.unit, decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Unit'), onChanged: (v) => row.unit = v.trim().isEmpty ? 'kg' : v.trim())),
              const SizedBox(width: 8),
              IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _removeRecipeRow(idx)),
            ]),
          );
        }).toList()),
        const SizedBox(height: 8),
        Text('Formula cost per unit: ${costPerUnit == null ? 'n/a (missing prices or components)' : costPerUnit.toStringAsFixed(4)}'),
      ],
    );
  }

  Widget _buildInventoryTable(double maxWidth) {
    final rows = _filteredInventory;
    double totalValue = 0.0;
    for (final r in rows) {
      final feedItem = r['feed_item'] ?? {};
      final price = feedItem['cost_per_unit'];
      final qty = double.tryParse((r['quantity'] ?? '0').toString()) ?? 0.0;
      final p = price != null ? double.tryParse(price.toString()) ?? 0.0 : 0.0;
      totalValue += p * qty;
    }


    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        const Text('Inventory (current)', style: TextStyle(fontWeight: FontWeight.bold)),
        Row(children: [
          SizedBox(
            width: 220,
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search inventory', border: OutlineInputBorder()),
              onChanged: (v) => setState(() => _inventorySearch = v),
            ),
          ),
          const SizedBox(width: 8),
          IconButton(onPressed: _showCsvDialog, icon: const Icon(Icons.download_outlined), tooltip: 'Export CSV'),
          IconButton(onPressed: _reloadData, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
        ])
      ]),
      const SizedBox(height: 8),
      if (rows.isEmpty) const Text('No inventory rows yet.'),
      if (rows.isNotEmpty)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            sortColumnIndex: _sortColumn == 'name'
                ? 0
                : _sortColumn == 'qty'
                    ? 1
                    : _sortColumn == 'price'
                        ? 3
                        : 4,
            sortAscending: _sortAsc,
            columns: [
              DataColumn(label: InkWell(onTap: () => _onSort('name'), child: const Text('Name'))),
              DataColumn(label: InkWell(onTap: () => _onSort('qty'), child: const Text('Qty'))),
              const DataColumn(label: Text('Unit')),
              DataColumn(label: InkWell(onTap: () => _onSort('price'), child: const Text('Price/unit'))),
              DataColumn(label: InkWell(onTap: () => _onSort('value'), child: const Text('Total value'))),
              const DataColumn(label: Text('Quality')),
              const DataColumn(label: Text('Actions')),
            ],
            rows: rows.map((i) {
              final feedItem = i['feed_item'] ?? {};
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
                DataCell(Row(children: [
                  IconButton(icon: const Icon(Icons.edit, size: 20), onPressed: () => _openEditInventoryDialog(i)),
                  IconButton(icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => _confirmDeleteInventory(i)),
                ])),
              ]);
            }).toList(),
          ),
        ),
      const SizedBox(height: 8),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [Text('Inventory total value: ${totalValue.toStringAsFixed(2)}')]),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Inventory & Formula Builder — Best Edition'),
          actions: [
            IconButton(onPressed: _reloadData, icon: const Icon(Icons.refresh)),
            IconButton(onPressed: _showCsvDialog, icon: const Icon(Icons.download_outlined)),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Inventory'), Tab(text: 'Add'), Tab(text: 'Formulas')]),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(12),
                child: LayoutBuilder(builder: (context, constraints) {
                  final maxWidth = constraints.maxWidth;
                  return TabBarView(children: [
                    // Inventory tab
                    RefreshIndicator(
                      onRefresh: _reloadData,
                      child: SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          _buildFarmSelector(),
                          const SizedBox(height: 12),
                          _buildInventoryTable(maxWidth),
                          const SizedBox(height: 24),
                        ]),
                      ),
                    ),

                    // Add ingredient tab
                    SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _buildFarmSelector(),
                        const SizedBox(height: 12),
                        _buildAddIngredientSection(maxWidth),
                        const SizedBox(height: 18),
                        const Text('Quick add recent items (from catalog)', style: TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: _feedItems.take(30).map((f) {
                            (f['id'] ?? '').toString();
                            final name = (f['name'] ?? '').toString();
                            return ActionChip(label: Text(name), onPressed: () {
                              _ingNameCtl.text = name;
                              _ingUnitCtl.text = (f['unit'] ?? 'kg').toString();
                              _ingTotalCostCtl.text = (f['cost_per_unit'] != null) ? (f['cost_per_unit'].toString()) : '';
                            });
                          }).toList(),
                        ),
                        const SizedBox(height: 24),
                      ]),
                    ),

                    // Formulas tab
                    SingleChildScrollView(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        _buildFarmSelector(),
                        const SizedBox(height: 12),
                        _buildRecipeBuilderSection(maxWidth),
                        const SizedBox(height: 24),
                      ]),
                    ),
                  ]);
                }),
              ),
      ),
    );
  }
}
