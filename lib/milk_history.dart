// lib/milk_history.dart
// Full MilkHistoryPage — chart + table + edit/delete/export CSV.
// Depends on: api_service.dart, fl_chart, intl.
//
// Add to pubspec.yaml if not present:
//   fl_chart: ^0.60.0
//   intl: ^0.18.0

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

import 'api_service.dart';

class MilkHistoryPage extends StatefulWidget {
  final ApiService api;
  const MilkHistoryPage({super.key, required this.api});

  @override
  State<MilkHistoryPage> createState() => _MilkHistoryPageState();
}

class _MilkHistoryPageState extends State<MilkHistoryPage> {
  List<Map<String, dynamic>> _milkHistory = [];
  Map<String, String> _animalNames = {}; // animalId -> label (tag or name)
  bool _loadingHistory = true;

  final ScrollController _verticalController = ScrollController();

  // UI filters
  String _historyFilter = 'last_30_days';
  final List<String> _filterOptions = [
    'last_7_days',
    'last_30_days',
    'last_90_days',
    'all',
  ];

  @override
  void initState() {
    super.initState();
    _fetchHistory();
  }

  @override
  void dispose() {
    _verticalController.dispose();
    super.dispose();
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _loadingHistory = true;
    });

    try {
      // compute fromDate based on filter
      final now = DateTime.now();
      DateTime? from;
      if (_historyFilter == 'last_7_days') {
        from = now.subtract(const Duration(days: 7));
      } else if (_historyFilter == 'last_30_days') {
        from = now.subtract(const Duration(days: 30));
      } else if (_historyFilter == 'last_90_days') {
        from = now.subtract(const Duration(days: 90));
      } else {
        from = null;
      }

      // gather farm ids and animals to build animal name map
      final farmIds = await widget.api.getUserFarmIds();
      if (farmIds.isEmpty) {
        setState(() {
          _milkHistory = [];
          _animalNames = {};
          _loadingHistory = false;
        });
        return;
      }

      final animals = await widget.api.fetchAnimalsForFarms(farmIds);
      _animalNames = {
        for (final a in animals) (a['id'] ?? '').toString(): _labelForAnimal(a),
      };

      final animalIds = animals
          .map((a) => (a['id'] ?? '').toString())
          .where((s) => s.isNotEmpty)
          .toList();

      final history = await widget.api.fetchMilkHistory(
        animalIds: animalIds,
        fromDate: from,
      );

      setState(() {
        _milkHistory = history;
        _loadingHistory = false;
      });
    } catch (e, st) {
      debugPrint('fetchHistory error: $e\n$st');
      setState(() {
        _milkHistory = [];
        _animalNames = {};
        _loadingHistory = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to load history')));
    }
  }

  String _labelForAnimal(Map<String, dynamic> a) {
    final tag = (a['tag'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    if (tag.isNotEmpty && name.isNotEmpty) return '$tag — $name';
    if (tag.isNotEmpty) return tag;
    if (name.isNotEmpty) return name;
    return (a['id'] ?? '').toString();
  }

  Future<void> _showEditEntrySheet(Map<String, dynamic> entry) async {
    final qCtl = TextEditingController(
      text: (entry['quantity'] ?? '').toString(),
    );
    DateTime entryDate;
    try {
      entryDate = DateTime.parse(
        (entry['date'] ?? DateTime.now().toIso8601String()).toString(),
      );
    } catch (_) {
      entryDate = DateTime.now();
    }

    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: MediaQuery.of(c).viewInsets,
        child: DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.9,
          builder: (_, controller) {
            return SingleChildScrollView(
              controller: controller,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      'Edit milk entry',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Form(
                      key: formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: qCtl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Quantity (L)',
                            ),
                            validator: (v) {
                              final val = double.tryParse(v ?? '');
                              if (val == null || val <= 0)
                                return 'Enter a valid quantity';
                              return null;
                            },
                          ),
                          const SizedBox(height: 12),
                          InkWell(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: entryDate,
                                firstDate: DateTime(2000),
                                lastDate: DateTime.now(),
                              );
                              if (picked != null) {
                                entryDate = picked;
                                // rebuild to show picked date
                                (context as Element).markNeedsBuild();
                              }
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Date',
                              ),
                              child: Text(
                                DateFormat('yyyy-MM-dd').format(entryDate),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: () async {
                                    if (!formKey.currentState!.validate())
                                      return;
                                    final newQty = double.parse(
                                      qCtl.text.trim(),
                                    );
                                    final payload = {
                                      'quantity': newQty,
                                      'date': DateFormat(
                                        'yyyy-MM-dd',
                                      ).format(entryDate),
                                    };
                                    Navigator.pop(context);
                                    final updated = await widget.api
                                        .updateMilkEntry(
                                          entry['id'].toString(),
                                          payload,
                                        );
                                    if (updated != null) {
                                      ScaffoldMessenger.of(
                                        this.context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Updated'),
                                        ),
                                      );
                                      _fetchHistory();
                                    } else {
                                      ScaffoldMessenger.of(
                                        this.context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Failed to update'),
                                        ),
                                      );
                                    }
                                  },
                                  child: const Text('Save'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Cancel'),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

    qCtl.dispose();
  }

  Future<void> _confirmDeleteEntry(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete entry'),
        content: const Text('Are you sure you want to delete this entry?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final ok = await widget.api.deleteMilkEntry(id);
      if (ok) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Deleted')));
        _fetchHistory();
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to delete')));
      }
    }
  }

  Future<void> _exportHistoryCsv() async {
    if (_milkHistory.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No history to export')));
      return;
    }
    final rows = <List<String>>[];
    rows.add([
      'date',
      'animal_id',
      'animal_tag',
      'animal_name',
      'quantity',
      'note',
    ]);
    for (final e in _milkHistory) {
      rows.add([
        e['date']?.toString() ?? '',
        (e['animal_id'] ?? '').toString(),
        (e['animal_tag'] ?? '').toString(),
        _animalNames[(e['animal_id'] ?? '').toString()] ??
            (e['animal_tag'] ?? e['animal_name'] ?? '').toString(),
        (e['quantity']?.toString() ?? ''),
        (e['note']?.toString() ?? ''),
      ]);
    }
    final csv = rows
        .map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(','))
        .join('\n');

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Export CSV'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(child: SelectableText(csv)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Widget _buildWhenEmpty() {
    return Center(
      child: Card(
        elevation: 2,
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.history, size: 48),
              const SizedBox(height: 8),
              const Text('No history available.'),
              const SizedBox(height: 8),
              ElevatedButton(
                onPressed: _fetchHistory,
                child: const Text('Refresh'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingHistory)
      return const Center(child: CircularProgressIndicator());
    if (_milkHistory.isEmpty) return _buildWhenEmpty();

    // aggregate daily totals for chart
    final Map<DateTime, double> dailyTotals = {};
    for (final entry in _milkHistory) {
      final dateStr = entry['date'] as String?;
      if (dateStr != null && dateStr.isNotEmpty) {
        try {
          final d = DateTime.parse(dateStr);
          final key = DateTime(d.year, d.month, d.day);
          final qty = (entry['quantity'] as num?)?.toDouble() ?? 0.0;
          dailyTotals[key] = (dailyTotals[key] ?? 0) + qty;
        } catch (_) {
          // ignore parse errors
        }
      }
    }

    final sortedDates = dailyTotals.keys.toList()
      ..sort((a, b) => a.compareTo(b));
    const maxPoints = 60;
    var chartDates = sortedDates;
    if (sortedDates.length > maxPoints) {
      chartDates = sortedDates.sublist(sortedDates.length - maxPoints);
    }

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < chartDates.length; i++) {
      final date = chartDates[i];
      final total = dailyTotals[date] ?? 0.0;
      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [BarChartRodData(toY: total)],
        ),
      );
    }

    final overallTotal = dailyTotals.values.fold<double>(0.0, (p, e) => p + e);
    final avg = dailyTotals.isEmpty ? 0.0 : overallTotal / dailyTotals.length;

    return RefreshIndicator(
      onRefresh: _fetchHistory,
      child: NotificationListener<OverscrollIndicatorNotification>(
        onNotification: (overscroll) {
          overscroll.disallowIndicator();
          return true;
        },
        child: SingleChildScrollView(
          controller: _verticalController,
          physics: const ClampingScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height,
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      DropdownButton<String>(
                        value: _historyFilter,
                        items: _filterOptions.map((f) {
                          var label = f.replaceAll('_', ' ');
                          label = label[0].toUpperCase() + label.substring(1);
                          return DropdownMenuItem(value: f, child: Text(label));
                        }).toList(),
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _historyFilter = v);
                          _fetchHistory();
                        },
                      ),
                      const SizedBox(width: 16),
                      IconButton(
                        onPressed: _fetchHistory,
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Refresh History',
                      ),
                      const Spacer(),
                      Text('Total: ${overallTotal.toStringAsFixed(1)} L'),
                      const SizedBox(width: 12),
                      Text('Avg/day: ${avg.toStringAsFixed(2)} L'),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Daily Milk Production Chart',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 320,
                    child: BarChart(
                      BarChartData(
                        barGroups: barGroups,
                        titlesData: FlTitlesData(
                          show: true,
                          bottomTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 32,
                              getTitlesWidget: (double value, TitleMeta meta) {
                                final idx = value.toInt();
                                if (idx >= 0 && idx < chartDates.length) {
                                  return Padding(
                                    padding: const EdgeInsets.only(top: 8.0),
                                    child: Text(
                                      DateFormat(
                                        'MM-dd',
                                      ).format(chartDates[idx]),
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                  );
                                }
                                return const SizedBox();
                              },
                            ),
                          ),
                          leftTitles: AxisTitles(
                            sideTitles: SideTitles(
                              showTitles: true,
                              reservedSize: 40,
                              getTitlesWidget: (double value, TitleMeta meta) =>
                                  Text(
                                    value.toStringAsFixed(0),
                                    style: const TextStyle(fontSize: 10),
                                  ),
                            ),
                          ),
                          topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                          rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false),
                          ),
                        ),
                        borderData: FlBorderData(show: false),
                        gridData: const FlGridData(
                          show: true,
                          drawVerticalLine: false,
                        ),
                        barTouchData: BarTouchData(
                          enabled: true,
                          touchTooltipData: BarTouchTooltipData(
                            getTooltipItem: (group, groupIndex, rod, rodIndex) {
                              if (groupIndex >= 0 &&
                                  groupIndex < chartDates.length) {
                                final date = DateFormat(
                                  'MM-dd',
                                ).format(chartDates[groupIndex]);
                                return BarTooltipItem(
                                  '$date\n${rod.toY.toStringAsFixed(1)} L',
                                  const TextStyle(color: Colors.white),
                                );
                              }
                              return null;
                            },
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Production History Table',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    elevation: 2,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: DataTable(
                        columnSpacing: 12,
                        columns: const [
                          DataColumn(label: Text('Date')),
                          DataColumn(label: Text('Animal')),
                          DataColumn(label: Text('Quantity (L)')),
                          DataColumn(label: Text('Note')),
                          DataColumn(label: Text('Actions')),
                        ],
                        rows: _milkHistory.map((entry) {
                          final id = (entry['id'] ?? '').toString();
                          final date = entry['date']?.toString() ?? 'N/A';
                          final animalId = (entry['animal_id'] ?? '')
                              .toString();
                          final animalName =
                              _animalNames[animalId] ??
                              (entry['animal_tag'] ??
                                      entry['animal_name'] ??
                                      'Unknown')
                                  .toString();
                          final quantity = (entry['quantity'] ?? '').toString();
                          final note = (entry['note'] ?? '').toString();
                          return DataRow(
                            cells: [
                              DataCell(Text(date)),
                              DataCell(Text(animalName)),
                              DataCell(Text(quantity)),
                              DataCell(Text(note)),
                              DataCell(
                                Row(
                                  children: [
                                    IconButton(
                                      tooltip: 'Edit',
                                      icon: const Icon(Icons.edit, size: 20),
                                      onPressed: () =>
                                          _showEditEntrySheet(entry),
                                    ),
                                    IconButton(
                                      tooltip: 'Delete',
                                      icon: const Icon(
                                        Icons.delete_outline,
                                        size: 20,
                                      ),
                                      onPressed: () => _confirmDeleteEntry(id),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ElevatedButton.icon(
                        onPressed: _exportHistoryCsv,
                        icon: const Icon(Icons.download),
                        label: const Text('Export CSV'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
