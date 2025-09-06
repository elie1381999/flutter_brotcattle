// lib/cow_feed_page.dart
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'api_service.dart' as api_service;
import 'api_fill_net.dart';

class CowFeedPage extends StatefulWidget {
  final api_service.ApiService apiService;
  const CowFeedPage({super.key, required this.apiService});

  @override
  State<CowFeedPage> createState() => _CowFeedPageState();
}

class _FeedRow {
  String? animalId;
  String? feedItemId;
  double quantity;
  _FeedRow({this.animalId, this.feedItemId, this.quantity = 0.0});
}

class _CowFeedPageState extends State<CowFeedPage> {
  late final FillNetApi _api;
  bool _loading = false;

  List<Map<String, dynamic>> _farms = [];
  String? _selectedFarmId;

  List<Map<String, dynamic>> _animals = [];
  List<Map<String, dynamic>> _feedItems = [];

  // rows map animalId -> row (for UI)
  final Map<String, _FeedRow> _rows = {};

  // controllers for per-row quantity input (keeps UI responsive)
  final Map<String, TextEditingController> _qtyControllers = {};

  // top-level unit (applies to inputs; note: this app does not convert units)
  String _unit = 'kg';
  final TextEditingController _unitController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _api = FillNetApi(widget.apiService);
    _unitController.text = _unit;
    _loadFarmsAndData();
  }

  @override
  void dispose() {
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    _unitController.dispose();
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
      await _reloadForFarm();
    } catch (e, st) {
      debugPrint('loadFarms error: $e\n$st');
      _showSnack('Failed to load farms', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _reloadForFarm() async {
    if (_selectedFarmId == null) return;
    setState(() => _loading = true);
    try {
      final animals = await _api.fetchAnimalsForFarm(_selectedFarmId!);
      final feedItems = await _api.fetchFeedItems(farmId: _selectedFarmId);
      if (!mounted) return;
      setState(() {
        _animals = animals;
        _feedItems = feedItems;
      });

      // initialize rows and controllers for each animal (preserve previous quantities if present)
      for (final a in _animals) {
        final aid = (a['id'] ?? '').toString();
        final existing = _rows[aid];
        _rows.putIfAbsent(
          aid,
          () => _FeedRow(
            animalId: aid,
            feedItemId: _feedItems.isNotEmpty
                ? (_feedItems.first['id'] ?? '').toString()
                : null,
            quantity: existing?.quantity ?? 0.0,
          ),
        );

        // create controller if missing
        _qtyControllers.putIfAbsent(aid, () {
          final c = TextEditingController();
          final q = _rows[aid]?.quantity ?? 0.0;
          c.text = q == 0.0 ? '' : q.toString();
          return c;
        });
      }

      // remove controllers for animals that no longer exist
      final existingAids = _animals
          .map((e) => (e['id'] ?? '').toString())
          .toSet();
      final toRemove = _qtyControllers.keys
          .where((k) => !existingAids.contains(k))
          .toList();
      for (final k in toRemove) {
        _qtyControllers[k]?.dispose();
        _qtyControllers.remove(k);
        _rows.remove(k);
      }
    } catch (e, st) {
      debugPrint('reloadForFarm error: $e\n$st');
      _showSnack('Failed to load farm data', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Public single-record entry point: handles both normal items and formulas.
  Future<bool> _recordFeedForRow(_FeedRow row) async {
    // returns true on success
    if (_selectedFarmId == null ||
        row.animalId == null ||
        row.feedItemId == null)
      return false;

    // ensure quantity comes from controller (latest)
    final controller = _qtyControllers[row.animalId!];
    final qty = controller != null
        ? double.tryParse(controller.text) ?? 0.0
        : row.quantity;
    if (qty <= 0) return false;
    row.quantity = qty; // sync

    final selected = _feedItems.firstWhere(
      (f) => (f['id'] ?? '').toString() == row.feedItemId,
      orElse: () => {},
    );
    if (selected.isEmpty) {
      debugPrint('Selected feed item not found in cache');
      return false;
    }

    final meta = selected['meta'];
    final isFormula = (meta is Map && meta['is_formula'] == true);

    // 1) If not a formula -> just record normally (api.recordAnimalFeed will also try to decrement inventory for the feed item)
    if (!isFormula) {
      final rec = await _api.recordAnimalFeed(
        farmId: _selectedFarmId!,
        animalId: row.animalId!,
        feedItemId: row.feedItemId!,
        quantity: row.quantity,
        unit: _unit,
        unitCost: selected['cost_per_unit'] != null
            ? double.tryParse(selected['cost_per_unit'].toString())
            : null,
      );
      return rec != null;
    }

    // 2) If it is a formula: try to record against finished product inventory first
    try {
      // Attempt to fetch inventory for the formula feed_item
      final invRow = await _api.fetchInventoryRow(
        farmId: _selectedFarmId!,
        feedItemId: row.feedItemId!,
      );

      final availableFormulaQty = invRow != null
          ? double.tryParse((invRow['quantity'] ?? '0').toString()) ?? 0.0
          : 0.0;

      if (availableFormulaQty >= row.quantity) {
        // there is enough finished product in inventory -> record against formula item (single transaction)
        final rec = await _api.recordAnimalFeed(
          farmId: _selectedFarmId!,
          animalId: row.animalId!,
          feedItemId: row.feedItemId!,
          quantity: row.quantity,
          unit: _unit,
          unitCost: selected['cost_per_unit'] != null
              ? double.tryParse(selected['cost_per_unit'].toString())
              : null,
          note: 'Recorded from finished formula',
        );
        return rec != null;
      }

      // 3) Not enough finished product inventory -> decompose into components and record each component
      final components = meta['components'];
      if (components == null || components is! List || components.isEmpty) {
        debugPrint('Formula has no components to decompose');
        return false;
      }

      // Determine recipe yield (if stored) or compute by summing component quantities
      double recipeYield = 0.0;
      if (meta.containsKey('yield')) {
        final y = meta['yield'];
        if (y is num) recipeYield = y.toDouble();
      }
      if (recipeYield <= 0) {
        // sum components quantities as fallback
        for (final c in components) {
          final q = c['quantity'];
          if (q is num) recipeYield += q.toDouble();
        }
      }
      if (recipeYield <= 0) {
        debugPrint('Cannot determine formula yield');
        return false;
      }

      final multiplier = row.quantity / recipeYield;

      // For each component create a recordAnimalFeed (this will also decrement the component inventory)
      int succeeded = 0;
      int failed = 0;

      for (final c in components) {
        try {
          final compFeedItemId = (c['feed_item_id'] ?? '').toString();
          final compQtyPerYield = (c['quantity'] is num)
              ? (c['quantity'] as num).toDouble()
              : double.tryParse((c['quantity'] ?? '0').toString()) ?? 0.0;
          final qtyToUse = compQtyPerYield * multiplier;
          if (compFeedItemId.isEmpty || qtyToUse <= 0) {
            failed++;
            continue;
          }

          final rec = await _api.recordAnimalFeed(
            farmId: _selectedFarmId!,
            animalId: row.animalId!,
            feedItemId: compFeedItemId,
            quantity: qtyToUse,
            unit: _unit,
            note: 'Decomposed from formula ${row.feedItemId}',
            unitCost: null,
          );

          if (rec != null) {
            succeeded++;
          } else {
            failed++;
          }
        } catch (e) {
          debugPrint('component record error: $e');
          failed++;
        }
      }

      // success if at least one component recorded and failures are zero (or you can relax)
      return succeeded > 0 && failed == 0;
    } catch (e, st) {
      debugPrint('formula handling error: $e\n$st');
      return false;
    }
  }

  Future<void> _recordAll() async {
    if (_selectedFarmId == null) {
      _showSnack('Select a farm first', error: true);
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Record all feeds?'),
        content: const Text(
          'This will record the entered quantities for all animals. Proceed?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Yes'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _loading = true);
    int success = 0;
    int failed = 0;
    try {
      // iterate rows snapshot to avoid mutation issues
      final rows = List<_FeedRow>.from(_rows.values);
      for (final row in rows) {
        if (row.animalId == null || row.feedItemId == null) continue;
        // read latest quantity from controller
        final controller = _qtyControllers[row.animalId!];
        final qty = controller != null
            ? double.tryParse(controller.text) ?? 0.0
            : row.quantity;
        if (qty <= 0) continue;
        row.quantity = qty;

        final ok = await _recordFeedForRow(row);
        if (ok)
          success++;
        else
          failed++;
      }
      _showSnack(
        'Recorded: $success succeeded, $failed failed',
        success: failed == 0,
      );
      // refresh inventory and feed txs
      await _reloadForFarm();
    } catch (e, st) {
      debugPrint('recordAll error: $e\n$st');
      _showSnack('Error recording feed', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _recordSingle(_FeedRow r) async {
    if (_selectedFarmId == null || r.animalId == null || r.feedItemId == null) {
      _showSnack('Select farm/animal/feed', error: true);
      return;
    }
    // ensure latest qty from controller
    final controller = _qtyControllers[r.animalId!];
    final qty = controller != null
        ? double.tryParse(controller.text) ?? 0.0
        : r.quantity;
    if (qty <= 0) {
      _showSnack('Enter a positive quantity', error: true);
      return;
    }
    r.quantity = qty;

    setState(() => _loading = true);
    try {
      final ok = await _recordFeedForRow(r);
      if (ok) {
        _showSnack('Recorded', success: true);
        await _reloadForFarm();
      } else {
        _showSnack('Failed to record (see debug)', error: true);
      }
    } catch (e, st) {
      debugPrint('recordSingle error: $e\n$st');
      _showSnack('Error recording feed', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

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

  Widget _buildTopControls(double maxWidth) {
    final narrow = maxWidth < 560;
    final farmDropdown = Expanded(
      child: DropdownButtonFormField<String>(
        value: _selectedFarmId,
        items: _farms.map((f) {
          final id = (f['id'] ?? '').toString();
          final name = (f['name'] ?? id).toString();
          return DropdownMenuItem(value: id, child: Text(name));
        }).toList(),
        onChanged: (v) {
          setState(() => _selectedFarmId = v);
          _reloadForFarm();
        },
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          hintText: 'Select farm',
        ),
      ),
    );

    final unitField = SizedBox(
      width: 120,
      child: TextFormField(
        controller: _unitController,
        decoration: const InputDecoration(
          border: OutlineInputBorder(),
          labelText: 'Unit (top)',
        ),
        onChanged: (v) =>
            setState(() => _unit = v.trim().isEmpty ? 'kg' : v.trim()),
      ),
    );

    final actions = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton(onPressed: _recordAll, child: const Text('Record All')),
        const SizedBox(width: 8),
        IconButton(onPressed: _reloadForFarm, icon: const Icon(Icons.refresh)),
      ],
    );

    return narrow
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [farmDropdown]),
              const SizedBox(height: 8),
              Row(children: [unitField, const SizedBox(width: 8), actions]),
            ],
          )
        : Row(
            children: [
              farmDropdown,
              const SizedBox(width: 8),
              unitField,
              const SizedBox(width: 8),
              actions,
            ],
          );
  }

  Widget _buildAnimalRow(Map<String, dynamic> a) {
    final aid = (a['id'] ?? '').toString();
    final tag = (a['tag'] ?? a['name'] ?? aid).toString();
    final row = _rows.putIfAbsent(
      aid,
      () => _FeedRow(
        animalId: aid,
        feedItemId: _feedItems.isNotEmpty
            ? (_feedItems.first['id'] ?? '').toString()
            : null,
        quantity: 0.0,
      ),
    );

    final controller = _qtyControllers.putIfAbsent(
      aid,
      () => TextEditingController(
        text: row.quantity == 0.0 ? '' : row.quantity.toString(),
      ),
    );

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                tag,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: DropdownButtonFormField<String>(
                value: row.feedItemId,
                items: _feedItems.isEmpty
                    ? [
                        const DropdownMenuItem(
                          value: null,
                          child: Text('No feeds/formulas — add inventory'),
                        ),
                      ]
                    : _feedItems.map((f) {
                        final id = (f['id'] ?? '').toString();
                        final name = (f['name'] ?? '').toString();
                        final meta = f['meta'];
                        final isFormula =
                            (meta is Map && meta['is_formula'] == true);
                        return DropdownMenuItem(
                          value: id,
                          child: Text(name + (isFormula ? ' (formula)' : '')),
                        );
                      }).toList(),
                onChanged: (v) => setState(() => row.feedItemId = v),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: 'Feed / Formula',
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 120,
              child: TextFormField(
                controller: controller,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: 'Qty ($_unit)',
                ),
                onChanged: (v) => row.quantity = double.tryParse(v) ?? 0.0,
              ),
            ),
            const SizedBox(width: 8),
            ElevatedButton(
              onPressed: () => _recordSingle(row),
              child: const Text('Record'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Feed Animals (per-animal quick)')),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: [
                    LayoutBuilder(
                      builder: (c, constraints) =>
                          _buildTopControls(constraints.maxWidth),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: _animals.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(
                                    Icons.pets,
                                    size: 48,
                                    color: Colors.black26,
                                  ),
                                  SizedBox(height: 8),
                                  Text('No animals (select farm)'),
                                ],
                              ),
                            )
                          : RefreshIndicator(
                              onRefresh: _reloadForFarm,
                              child: ListView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                itemCount: _animals.length,
                                itemBuilder: (ctx, i) =>
                                    _buildAnimalRow(_animals[i]),
                              ),
                            ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
