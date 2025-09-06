// lib/net_per_animal_page.dart
import 'dart:math';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'api_service.dart' as api_service;
import 'api_fill_net.dart';
import 'api_netperanimal.dart';
import 'supabase_config.dart'; // <-- needed for SUPABASE_URL

class NetPerAnimalPage extends StatefulWidget {
  final api_service.ApiService apiService;
  const NetPerAnimalPage({super.key, required this.apiService});

  @override
  State<NetPerAnimalPage> createState() => _NetPerAnimalPageState();
}

class _NetPerAnimalPageState extends State<NetPerAnimalPage> {
  late final FillNetApi _fillApi;
  late final NetPerAnimalApi _netApi;
  bool _loading = false;

  List<Map<String, dynamic>> _farms = [];
  String? _selectedFarmId;

  List<Map<String, dynamic>> _animals = [];
  DateTime _fromDate = DateTime.now().subtract(const Duration(days: 30));
  DateTime _toDate = DateTime.now();

  // results: computed summary per animal (milkQty, milkIncome, feedCost, net)
  List<Map<String, dynamic>> _results = [];

  // cache for per-animal net timeseries for sparkline
  final Map<String, List<double>> _tsCache = {};

  // UI state
  String _sortBy = 'net'; // net | milkQty | feedCost
  bool _sortDesc = true;
  String _search = '';

  @override
  void initState() {
    super.initState();
    _fillApi = FillNetApi(widget.apiService);
    _netApi = NetPerAnimalApi(widget.apiService);
    _loadFarms();
  }

  Future<void> _loadFarms() async {
    setState(() => _loading = true);
    try {
      final farms = await _fillApi.fetchFarmsForUser();
      setState(() {
        _farms = farms;
        if (_farms.isNotEmpty && _selectedFarmId == null) {
          _selectedFarmId = (_farms.first['id'] ?? '').toString();
        }
      });
      if (_selectedFarmId != null) await _reloadAnimalsAndCompute();
    } catch (e, st) {
      debugPrint('loadFarms error: $e\n$st');
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to load farms')));
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _reloadAnimalsAndCompute() async {
    if (_selectedFarmId == null) return;
    setState(() => _loading = true);
    try {
      final animals = await _fillApi.fetchAnimalsForFarm(_selectedFarmId!);
      setState(() => _animals = animals);
      await _computeAll();
    } catch (e, st) {
      debugPrint('reloadAnimalsAndCompute error: $e\n$st');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _computeAll() async {
    if (_selectedFarmId == null) return;
    setState(() => _loading = true);
    try {
      // fetch milk price for farm (if exists) — use SUPABASE_URL constant
      double milkPrice = 0.0;
      try {
        final fsUrl =
            '$SUPABASE_URL/rest/v1/farm_settings?select=value&farm_id=eq.${_selectedFarmId!}&key=eq.milk_price_per_unit';
        final fsParsed = await widget.apiService.httpGetParsed(fsUrl);
        if (fsParsed is List && fsParsed.isNotEmpty) {
          final v = fsParsed.first['value'];
          milkPrice = double.tryParse(v?.toString() ?? '') ?? 0.0;
        }
      } catch (_) {
        milkPrice = 0.0;
      }

      // get animal ids for farm
      final animalsList = _animals;
      final animalIds = animalsList
          .map((a) => (a['id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList();
      if (animalIds.isEmpty) {
        setState(() => _results = []);
        return;
      }

      // 1) fetch feed transactions for the farm (server-level) and filter by date range locally
      final allFeedTx = await _fillApi.fetchFeedTransactions(
        farmId: _selectedFarmId,
        limit: 5000,
      );

      // 2) fetch milk history for all animals in one call
      final allMilk = await widget.apiService.fetchMilkHistory(
        animalIds: animalIds,
        fromDate: _fromDate,
        toDate: _toDate,
      );

      // pre-group
      final Map<String, List<Map<String, dynamic>>> feedByAnimal = {};
      for (final t in allFeedTx) {
        // filter by date range
        final created = t['created_at']?.toString() ?? t['date']?.toString();
        if (created != null) {
          try {
            final d = DateTime.parse(created).toLocal();
            if (d.isBefore(_fromDate) || d.isAfter(_toDate)) continue;
          } catch (_) {}
        }
        final aid = (t['animal_id'] ?? '').toString();
        if (aid.isEmpty) continue;
        feedByAnimal
            .putIfAbsent(aid, () => [])
            .add(Map<String, dynamic>.from(t));
      }

      final Map<String, List<Map<String, dynamic>>> milkByAnimal = {};
      for (final m in allMilk) {
        final aid = (m['animal_id'] ?? '').toString();
        if (aid.isEmpty) continue;
        milkByAnimal
            .putIfAbsent(aid, () => [])
            .add(Map<String, dynamic>.from(m));
      }

      final results = <Map<String, dynamic>>[];

      for (final a in animalsList) {
        final aid = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? a['name'] ?? aid).toString();

        // feed cost sum
        double feedCost = 0.0;
        final feedTxs = feedByAnimal[aid] ?? [];
        for (final t in feedTxs) {
          final uc = t['unit_cost'] != null
              ? double.tryParse(t['unit_cost'].toString())
              : null;
          final qty =
              double.tryParse((t['quantity'] ?? '0').toString()) ?? 0.0;
          final feedItem = t['feed_item'] ?? <String, dynamic>{};
          final fallback = feedItem['cost_per_unit'] != null
              ? double.tryParse(feedItem['cost_per_unit'].toString())
              : null;
          final usedUnitCost = uc ?? fallback ?? 0.0;
          feedCost += usedUnitCost * qty;
        }

        // milk total & income
        final milkEntries = milkByAnimal[aid] ?? [];
        double milkQty = 0.0;
        for (final m in milkEntries) {
          milkQty +=
              double.tryParse((m['quantity'] ?? '0').toString()) ?? 0.0;
        }
        final milkIncome = milkQty * milkPrice;

        results.add({
          'animalId': aid,
          'tag': tag,
          'milkQty': milkQty,
          'milkIncome': milkIncome,
          'feedCost': feedCost,
          'net': milkIncome - feedCost,
        });
      }

      // sorting
      results.sort((a, b) {
        final av = a[_sortBy] as num? ?? 0;
        final bv = b[_sortBy] as num? ?? 0;
        final cmp = bv.compareTo(av);
        return _sortDesc ? cmp : -cmp;
      });

      // reset ts cache if date range changed (safe to clear)
      _tsCache.clear();

      setState(() => _results = results);
    } catch (e, st) {
      debugPrint('computeAll error: $e\n$st');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to compute net per animal')),
      );
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _pickFromDate() async {
    final pick = await showDatePicker(
      context: context,
      initialDate: _fromDate,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: _toDate,
    );
    if (pick != null) {
      setState(() => _fromDate = pick);
      await _computeAll();
    }
  }

  Future<void> _pickToDate() async {
    final pick = await showDatePicker(
      context: context,
      initialDate: _toDate,
      firstDate: _fromDate,
      lastDate: DateTime.now(),
    );
    if (pick != null) {
      setState(() => _toDate = pick);
      await _computeAll();
    }
  }

  // Lazy fetch timeseries for an animal and cache numeric net values (last N days)
  Future<List<double>> _loadTimeseriesFor(
    String animalId, {
    int days = 30,
  }) async {
    if (_tsCache.containsKey(animalId)) return _tsCache[animalId]!;
    final raw = await _netApi.fetchNetTimeSeries(
      animalId: animalId,
      days: days,
    );
    final values = raw
        .map<double>(
          (m) => (m['net'] ?? 0.0) is num
              ? (m['net'] as num).toDouble()
              : double.tryParse((m['net'] ?? '0').toString()) ?? 0.0,
        )
        .toList();
    _tsCache[animalId] = values;
    return values;
  }

  // Responsive herd summary that works inside flexibleSpace (keeps compact on small widths)
  Widget _buildHeaderContent(BoxConstraints constraints) {
    final totalNet = _results.fold<double>(
      0.0,
      (p, e) => p + (e['net'] as double? ?? 0.0),
    );
    final totalMilk = _results.fold<double>(
      0.0,
      (p, e) => p + (e['milkQty'] as double? ?? 0.0),
    );
    final totalFeed = _results.fold<double>(
      0.0,
      (p, e) => p + (e['feedCost'] as double? ?? 0.0),
    );
    final avgNet = _results.isEmpty ? 0.0 : totalNet / _results.length;

    final isNarrow = constraints.maxWidth < 420;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Material(
        elevation: 2,
        borderRadius: BorderRadius.circular(8),
        color: Theme.of(context).cardColor,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: isNarrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Herd summary',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        IconButton(
                          tooltip: 'Refresh',
                          onPressed: _computeAll,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        _smallMetric('Total milk', totalMilk.toStringAsFixed(1),
                            unit: 'L'),
                        _smallMetric('Total feed', totalFeed.toStringAsFixed(2),
                            unit: '\$'),
                        _smallMetric('Total net', totalNet.toStringAsFixed(2),
                            unit: '\$', highlight: true),
                        _smallMetric('Avg net/cow', avgNet.toStringAsFixed(2),
                            unit: '\$'),
                        _smallMetric('Animals', _results.length.toString()),
                      ],
                    ),
                  ],
                )
              : Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Herd summary',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 20,
                            runSpacing: 6,
                            children: [
                              _smallMetric('Total milk',
                                  totalMilk.toStringAsFixed(1),
                                  unit: 'L'),
                              _smallMetric('Total feed',
                                  totalFeed.toStringAsFixed(2),
                                  unit: '\$'),
                              _smallMetric('Total net', totalNet.toStringAsFixed(2),
                                  unit: '\$', highlight: true),
                              _smallMetric('Avg net/cow', avgNet.toStringAsFixed(2),
                                  unit: '\$'),
                              _smallMetric('Animals', _results.length.toString()),
                            ],
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Refresh',
                      onPressed: _computeAll,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _smallMetric(
    String label,
    String value, {
    String unit = '',
    bool highlight = false,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 12, color: Colors.grey[700]),
            ),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: value,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: highlight ? FontWeight.bold : FontWeight.w600,
                      color: highlight ? Colors.green.shade700 : null,
                    ),
                  ),
                  if (unit.isNotEmpty)
                    TextSpan(
                      text: ' $unit',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.black54,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  // Build animal card with responsive layout
  Widget _buildAnimalCard(Map<String, dynamic> r, int index) {
    final aid = r['animalId'] as String;
    final tag = (r['tag'] as String?) ?? aid;
    final milkQty = (r['milkQty'] as double?) ?? 0.0;
    final milkIncome = (r['milkIncome'] as double?) ?? 0.0;
    final feedCost = (r['feedCost'] as double?) ?? 0.0;
    final net = (r['net'] as double?) ?? 0.0;

    // Use non-nullable shades for color
    final Color color = net >= 0 ? Colors.green.shade700 : Colors.red.shade700;

    final perfScore = _performanceScore(net);

    return LayoutBuilder(builder: (context, constraints) {
      final narrow = constraints.maxWidth < 520;

      Widget leftColumn = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tag,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: FutureBuilder<List<double>>(
              future: _loadTimeseriesFor(aid, days: 30),
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                final vals = snap.data ?? [];
                if (vals.isEmpty) {
                  return const Center(
                    child: Text(
                      'no timeseries',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.black45,
                      ),
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Sparkline(
                    values: vals,
                    lineColor: color,
                    strokeWidth: 2,
                  ),
                );
              },
            ),
          ),
        ],
      );

      Widget mainMetrics = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _smallMetric('Milk', milkQty.toStringAsFixed(1), unit: 'L'),
                    const SizedBox(height: 6),
                    _smallMetric('Milk income', milkIncome.toStringAsFixed(2),
                        unit: '\$'),
                    const SizedBox(height: 6),
                    _smallMetric('Feed', feedCost.toStringAsFixed(2), unit: '\$'),
                  ],
                )
              : Row(
                  children: [
                    _smallMetric('Milk', milkQty.toStringAsFixed(1), unit: 'L'),
                    const SizedBox(width: 12),
                    _smallMetric('Milk income', milkIncome.toStringAsFixed(2),
                        unit: '\$'),
                    const SizedBox(width: 12),
                    _smallMetric('Feed', feedCost.toStringAsFixed(2), unit: '\$'),
                  ],
                ),
          const SizedBox(height: 8),
          Row(
            children: [
              Chip(
                backgroundColor: color.withAlpha((0.12 * 255).round()),
                label: Text(
                  'Net ${net.toStringAsFixed(2)}',
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton(
                onPressed: () {
                  _showAnimalDetail(aid, tag);
                },
                child: const Text('Details'),
              ),
            ],
          ),
        ],
      );

      Widget rightColumn = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            (index + 1).toString(),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 8),
          _netMiniMeter(net),
          const SizedBox(height: 8),
          SizedBox(
            height: 64,
            width: 64,
            child: _RadialScore(value: perfScore, color: color),
          ),
        ],
      );

      return Card(
        elevation: 1,
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    leftColumn,
                    const SizedBox(height: 10),
                    mainMetrics,
                    const SizedBox(height: 10),
                    Align(alignment: Alignment.centerRight, child: rightColumn),
                  ],
                )
              : Row(
                  children: [
                    Flexible(flex: 2, child: leftColumn),
                    const SizedBox(width: 12),
                    Expanded(flex: 5, child: mainMetrics),
                    const SizedBox(width: 12),
                    SizedBox(width: 140, child: rightColumn),
                  ],
                ),
        ),
      );
    });
  }

  // performance score mapping: convert net dollar to a 0..1 score (clamped)
  double _performanceScore(double net) {
    // Simple mapping: -200 -> 0, 0 -> 0.5, +200 -> 1.0
    const negLimit = -200.0;
    const posLimit = 200.0;
    final clamped = net.clamp(negLimit, posLimit);
    final t = (clamped - negLimit) / (posLimit - negLimit); // 0..1
    return t;
  }

  Widget _netMiniMeter(double net) {
    final capped = net.clamp(-1000.0, 1000.0);
    final positive = max(0.0, capped);
    final negative = -min(0.0, capped);
    final maxSide = max(positive, negative);
    final scale = maxSide > 0 ? 100.0 / maxSide : 0.0;

    final posWidth = (positive * scale).clamp(0.0, 100.0);
    final negWidth = (negative * scale).clamp(0.0, 100.0);

    return Row(
      children: [
        // negative (left)
        Expanded(
          child: Container(
            height: 12,
            color: Colors.red.shade50,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Container(width: negWidth, color: Colors.red.shade400),
            ),
          ),
        ),
        const SizedBox(width: 6),
        // positive (right)
        Expanded(
          child: Container(
            height: 12,
            color: Colors.green.shade50,
            child: Align(
              alignment: Alignment.centerRight,
              child: Container(width: posWidth, color: Colors.green.shade400),
            ),
          ),
        ),
      ],
    );
  }

  // simple detail sheet placeholder
  Future<void> _showAnimalDetail(String animalId, String tag) async {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.8,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Details: $tag',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: FutureBuilder<List<Map<String, dynamic>>>(
                    future: _netApi.fetchFeedTransactionsForAnimal(
                      animalId: animalId,
                      fromDate: _fromDate,
                      toDate: _toDate,
                    ),
                    builder: (c, snap) {
                      if (snap.connectionState == ConnectionState.waiting) {
                        return const Center(child: CircularProgressIndicator());
                      }
                      final txs = snap.data ?? [];
                      if (txs.isEmpty)
                        return const Center(
                          child: Text('No feed transactions'),
                        );
                      return ListView.separated(
                        itemCount: txs.length,
                        separatorBuilder: (_, __) => const Divider(),
                        itemBuilder: (ctx, i) {
                          final t = txs[i];
                          final date =
                              t['created_at']?.toString() ??
                              t['date']?.toString() ??
                              '';
                          final qty = (t['quantity'] ?? 0).toString();
                          final unitCost =
                              (t['unit_cost'] ??
                                      t['feed_item']?['cost_per_unit'] ??
                                      'n/a')
                                  .toString();
                          final costVal =
                              (double.tryParse(qty) ?? 0) *
                              (double.tryParse(unitCost) ?? 0);
                          return ListTile(
                            title: Text(
                              '${t['note'] ?? t['tx_type'] ?? 'feed'} • $qty',
                            ),
                            subtitle: Text(
                              'date: $date • unit cost: $unitCost',
                            ),
                            trailing: Text('${costVal.toStringAsFixed(2)}\$'),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // pinned toolbar that holds farm selector, date pickers, search and sort
  Widget _buildPinnedToolbar() {
    return Container(
      color: Theme.of(context).scaffoldBackgroundColor,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          // farm dropdown (flexible)
          Expanded(
            child: DropdownButtonFormField<String>(
              value: _selectedFarmId,
              items: _farms.map((f) {
                final id = (f['id'] ?? '').toString();
                final name = (f['name'] ?? id).toString();
                return DropdownMenuItem(
                  value: id,
                  child: Text(name),
                );
              }).toList(),
              onChanged: (v) {
                setState(() => _selectedFarmId = v);
                _reloadAnimalsAndCompute();
              },
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: 'Select farm',
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _pickFromDate,
            child: Text(
              'From: ${_fromDate.toLocal().toIso8601String().split('T').first}',
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: _pickToDate,
            child: Text(
              'To: ${_toDate.toLocal().toIso8601String().split('T').first}',
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 200,
            child: TextFormField(
              initialValue: _search,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: 'Search tag or name',
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              ),
              onChanged: (v) => setState(() => _search = v.trim().toLowerCase()),
            ),
          ),
          const SizedBox(width: 8),
          PopupMenuButton<String>(
            tooltip: 'Sort',
            icon: const Icon(Icons.sort),
            onSelected: (s) {
              setState(() {
                if (s == _sortBy) _sortDesc = !_sortDesc;
                _sortBy = s;
                _computeAll();
              });
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 'net',
                child: Text(
                  'Sort by Net ${_sortBy == 'net' ? (_sortDesc ? '↓' : '↑') : ''}',
                ),
              ),
              PopupMenuItem(
                value: 'milkQty',
                child: Text(
                  'Sort by Milk ${_sortBy == 'milkQty' ? (_sortDesc ? '↓' : '↑') : ''}',
                ),
              ),
              PopupMenuItem(
                value: 'feedCost',
                child: Text(
                  'Sort by Feed ${_sortBy == 'feedCost' ? (_sortDesc ? '↓' : '↑') : ''}',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _results.where((r) {
      if (_search.isEmpty) return true;
      final tag = (r['tag'] ?? '').toString().toLowerCase();
      return tag.contains(_search);
    }).toList();

    return Scaffold(
      // We use NestedScrollView headers to show herd summary as an expandable / hideable area.
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : NestedScrollView(
              headerSliverBuilder: (ctx, innerBoxScrolled) => [
                SliverAppBar(
                  title: const Text('Net per Animal'),
                  floating: true,
                  snap: true,
                  // summary area shows when expanded and hides when user scrolls down
                  expandedHeight: 160,
                  flexibleSpace: FlexibleSpaceBar(
                    background: LayoutBuilder(
                      builder: (context, constraints) {
                        // constraints.biggest here is the flexibleSpace area
                        return SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.only(top: kToolbarHeight),
                            child: _buildHeaderContent(constraints),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                // pinned toolbar stays accessible (farm, dates, search, sort)
                SliverPersistentHeader(
                  delegate: _PinnedHeaderDelegate(
                    child: _buildPinnedToolbar(),
                    height: 64,
                  ),
                  pinned: true,
                ),
              ],
              body: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: filtered.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.info_outline, size: 48, color: Colors.black38),
                            const SizedBox(height: 8),
                            const Text(
                              'No results — select a farm or widen the date range.',
                              style: TextStyle(fontSize: 16),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            ElevatedButton.icon(
                              onPressed: () {
                                // small helper: refresh everything
                                _reloadAnimalsAndCompute();
                              },
                              icon: const Icon(Icons.refresh),
                              label: const Text('Reload'),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () => _computeAll(),
                        child: ListView.builder(
                          padding: const EdgeInsets.only(bottom: 20),
                          itemCount: filtered.length,
                          itemBuilder: (ctx, i) => _buildAnimalCard(filtered[i], i),
                        ),
                      ),
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _computeAll(),
        tooltip: 'Refresh',
        child: const Icon(Icons.refresh),
      ),
    );
  }
}

// SliverPersistentHeader delegate used for pinned toolbar
class _PinnedHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;
  _PinnedHeaderDelegate({required this.child, required this.height});

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    return Material(
      elevation: overlapsContent ? 1 : 0,
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SizedBox.expand(child: child),
    );
  }

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant _PinnedHeaderDelegate oldDelegate) {
    return oldDelegate.child != child || oldDelegate.height != height;
  }
}

// Small lightweight sparkline CustomPainter (kept from your design)
class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color? lineColor;
  final double strokeWidth;

  const Sparkline({
    super.key,
    required this.values,
    this.lineColor,
    this.strokeWidth = 2,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _SparklinePainter(
        values: values,
        color: lineColor ?? Theme.of(context).primaryColor,
        strokeWidth: strokeWidth,
      ),
      size: Size.infinite,
    );
  }
}

class _SparklinePainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final double strokeWidth;
  _SparklinePainter({
    required this.values,
    required this.color,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color
      ..strokeCap = StrokeCap.round;

    final minV = values.reduce(min);
    final maxV = values.reduce(max);
    final range = (maxV - minV) == 0 ? 1.0 : (maxV - minV);

    final gap = size.width / max(1, values.length - 1);
    final path = Path();

    for (int i = 0; i < values.length; i++) {
      final x = i * gap;
      final y = size.height - ((values[i] - minV) / range) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _SparklinePainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// Small radial score: value 0..1, color (non-nullable)
class _RadialScore extends StatelessWidget {
  final double value; // 0..1
  final Color color;
  const _RadialScore({required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    final bg = color.withAlpha((0.12 * 255).round());
    return CustomPaint(
      painter: _RadialPainter(
        value: value.clamp(0.0, 1.0),
        baseColor: bg,
        fillColor: color,
      ),
      child: Center(
        child: Text(
          (value * 100).toStringAsFixed(0) + '%',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
      ),
    );
  }
}

class _RadialPainter extends CustomPainter {
  final double value;
  final Color baseColor;
  final Color fillColor;
  _RadialPainter({
    required this.value,
    required this.baseColor,
    required this.fillColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = min(size.width, size.height) / 2 - 4;
    final basePaint = Paint()
      ..color = baseColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round;
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round;

    // background circle
    canvas.drawCircle(center, radius, basePaint);

    // arc for value
    final start = -pi / 2;
    final sweep = 2 * pi * value;
    final rect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(rect, start, sweep, false, fillPaint);
  }

  @override
  bool shouldRepaint(covariant _RadialPainter old) {
    return old.value != value ||
        old.baseColor != baseColor ||
        old.fillColor != fillColor;
  }
}
