import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'api_service.dart';
import 'milk_history.dart';

class MilkProductionPage extends StatefulWidget {
  final ApiService api;
  const MilkProductionPage({
    super.key,
    required this.api,
    required String token,
  });

  @override
  State<MilkProductionPage> createState() => _MilkProductionPageState();
}

class _MilkProductionPageState extends State<MilkProductionPage> {
  // All animals fetched from the API (we'll filter to female cows)
  List<Map<String, dynamic>> _allAnimals = [];
  List<Map<String, dynamic>> get _cowAnimals => _allAnimals.where((a) {
    final sex = (a['sex'] ?? '').toString().toLowerCase();
    final stage = (a['stage'] ?? '').toString().toLowerCase();
    return sex == 'female' && stage == 'cow';
  }).toList();

  bool _loadingAnimals = true;
  String? _selectedAnimalId;
  final TextEditingController _quantityController = TextEditingController();
  DateTime _selectedDate = DateTime.now();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _fetchAnimals();
  }

  @override
  void dispose() {
    _quantityController.dispose();
    super.dispose();
  }

  /// Fetch animals for the user's farms and keep them in memory.
  /// We do not modify server-side data here — only filter locally to show female cows.
  Future<void> _fetchAnimals() async {
    setState(() => _loadingAnimals = true);
    try {
      final farmIds = await widget.api.getUserFarmIds();
      if (farmIds.isEmpty) {
        setState(() {
          _allAnimals = [];
          _selectedAnimalId = null;
          _loadingAnimals = false;
        });
        return;
      }

      final animals = await widget.api.fetchAnimalsForFarms(farmIds);

      // Normalize and index label
      final normalized = animals.map((a) {
        final m = Map<String, dynamic>.from(a);
        // Prefer 'tag — name' label if available
        final tag = (m['tag'] ?? '').toString();
        final name = (m['name'] ?? '').toString();
        m['__label'] = tag.isNotEmpty && name.isNotEmpty
            ? '$tag — $name'
            : (tag.isNotEmpty
                  ? tag
                  : (name.isNotEmpty ? name : (m['id'] ?? '').toString()));
        return m;
      }).toList();

      setState(() {
        _allAnimals = normalized;
        // Default selected to first female cow (if any)
        final cows = _cowAnimals;
        _selectedAnimalId ??= cows.isNotEmpty
            ? (cows.first['id'] ?? '').toString()
            : null;
        _loadingAnimals = false;
      });
    } catch (e, st) {
      debugPrint('fetchAnimals error: $e\n$st');
      setState(() {
        _allAnimals = [];
        _selectedAnimalId = null;
        _loadingAnimals = false;
      });
    }
  }

  Future<void> _saveSingleProduction(String? existingId) async {
    if (_selectedAnimalId == null || _selectedAnimalId!.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Please select a cow')));
      return;
    }
    final q = double.tryParse(_quantityController.text.trim());
    if (q == null || q <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Enter a valid quantity')));
      return;
    }

    setState(() => _saving = true);
    try {
      // Find the animal object to extract farm_id
      final animalObj = _allAnimals.firstWhere(
        (a) => (a['id'] ?? '').toString() == _selectedAnimalId,
        orElse: () => {},
      );
      final farmId = (animalObj['farm_id'] ?? '').toString();
      final res = await widget.api.saveMilkProduction(
        animalId: _selectedAnimalId!,
        farmId: farmId.isNotEmpty ? farmId : null,
        quantity: q,
        date: _selectedDate,
        entryType: 'per_cow',
      );

      if (res['success'] == true) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved')));
        _quantityController.clear();
        // History page will re-fetch when opened
      } else {
        debugPrint('save error: ${res['error'] ?? res['body']}');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to save production')),
        );
      }
    } catch (e) {
      debugPrint('save production exception: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to save production')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildAddTab(BuildContext context) {
    final cows = _cowAnimals;
    if (_loadingAnimals) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_allAnimals.isEmpty) {
      return Center(
        child: Card(
          elevation: 2,
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.warning, size: 48, color: Colors.orange),
                const SizedBox(height: 8),
                const Text('No animals found for your farms.'),
                const SizedBox(height: 8),
                ElevatedButton(
                  onPressed: _fetchAnimals,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    if (cows.isEmpty) {
      return Center(
        child: Card(
          elevation: 2,
          margin: const EdgeInsets.all(16),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.pets, size: 48, color: Colors.grey),
                const SizedBox(height: 8),
                const Text('No female cows available to record milk.'),
                const SizedBox(height: 8),
                const Text(
                  'Only animals with sex = Female and stage = Cow are shown here.',
                ),
                const SizedBox(height: 12),
                ElevatedButton(
                  onPressed: _fetchAnimals,
                  child: const Text('Refresh'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchAnimals,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add Milk Production Entry',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Card(
              elevation: 2,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select a Cow',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const ClampingScrollPhysics(),
                      child: DataTable(
                        columnSpacing: 12,
                        columns: const [
                          DataColumn(label: Text('Tag')),
                          DataColumn(label: Text('Name')),
                          DataColumn(label: Text('Action')),
                        ],
                        rows: cows.map((a) {
                          final id = (a['id'] ?? '').toString();
                          final tag = (a['tag'] ?? '').toString();
                          final name = (a['name'] ?? '').toString();
                          final isSelected = id == _selectedAnimalId;
                          return DataRow(
                            cells: [
                              DataCell(Text(tag.isEmpty ? 'N/A' : tag)),
                              DataCell(Text(name.isEmpty ? 'N/A' : name)),
                              DataCell(
                                ElevatedButton(
                                  onPressed: () =>
                                      setState(() => _selectedAnimalId = id),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: isSelected
                                        ? Theme.of(
                                            context,
                                          ).colorScheme.primary.withOpacity(0.2)
                                        : null,
                                  ),
                                  child: Text(
                                    isSelected ? 'Selected' : 'Select',
                                  ),
                                ),
                              ),
                            ],
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _quantityController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: const InputDecoration(
                        labelText: 'Quantity (L)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: InkWell(
                            onTap: () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: _selectedDate,
                                firstDate: DateTime(2000),
                                lastDate: DateTime.now(),
                              );
                              if (picked != null) {
                                setState(() => _selectedDate = picked);
                              }
                            },
                            child: InputDecorator(
                              decoration: const InputDecoration(
                                labelText: 'Date',
                                border: OutlineInputBorder(),
                              ),
                              child: Text(
                                DateFormat('yyyy-MM-dd').format(_selectedDate),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton(
                          onPressed: _saving
                              ? null
                              : () => _saveSingleProduction(null),
                          child: _saving
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('Save'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Milk Production'),
          actions: [
            IconButton(
              onPressed: _fetchAnimals,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Add Production'),
              Tab(text: 'History & Chart'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _buildAddTab(context),
            MilkHistoryPage(api: widget.api),
          ],
        ),
      ),
    );
  }
}

/*
//the best
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'api_service.dart';

class MilkProductionPage extends StatefulWidget {
  final String token;
  const MilkProductionPage({super.key, required this.token});

  @override
  State<MilkProductionPage> createState() => _MilkProductionPageState();
}

class _MilkProductionPageState extends State<MilkProductionPage> {
  final List<Map<String, dynamic>> _animals = [];
  final List<Map<String, dynamic>> _milkHistory = [];
  final Map<String, String> _animalNames = {};

  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, String> _rowStatus = {};
  final Map<String, bool> _savingRows = {};

  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  bool _loading = true;
  bool _loadingHistory = false;
  bool _savingAll = false;
  String? _error;
  late ApiService _apiService;

  DateTime _selectedDate = DateTime.now();
  bool _bulkMode = false;
  final TextEditingController _bulkQtyController = TextEditingController();

  String _historyFilter = 'all';
  final List<String> _filterOptions = [
    'all',
    'last_week',
    'last_month',
    'last_year',
  ];

  String _session = 'morning';
  final List<String> _sessionOptions = [
    'morning',
    'afternoon',
    'evening',
    'night',
  ];

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAnimals();
  }

  @override
  void dispose() {
    _bulkQtyController.dispose();
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  Future<void> _fetchAnimals() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals.clear();
      _animalNames.clear();
      _qtyControllers.clear();
      _rowStatus.clear();
      _savingRows.clear();
    });

    try {
      final farmIds = await _fetchUserFarmIds();
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }

      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      for (final a in animals) {
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        if (id.isNotEmpty) {
          _animalNames[id] = '$tag — $name';
          _qtyControllers[id] = _qtyControllers[id] ?? TextEditingController();
          _savingRows[id] = false;
        }
        _animals.add(a);
      }

      setState(() {
        _loading = false;
      });

      await _fetchHistory();
    } catch (e) {
      debugPrint('Error fetching animals: $e');
      setState(() {
        _error = 'Failed to load animals. Please check your connection.';
        _loading = false;
      });
    }
  }

  Future<List<String>> _fetchUserFarmIds() async {
    try {
      return await _apiService.getUserFarmIds();
    } catch (e) {
      debugPrint('getUserFarmIds error: $e');
      return [];
    }
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _loadingHistory = true;
      _milkHistory.clear();
    });

    try {
      DateTime? fromDate;
      final toDate = DateTime.now();

      switch (_historyFilter) {
        case 'last_week':
          fromDate = toDate.subtract(const Duration(days: 7));
          break;
        case 'last_month':
          fromDate = toDate.subtract(const Duration(days: 30));
          break;
        case 'last_year':
          fromDate = toDate.subtract(const Duration(days: 365));
          break;
        default:
          fromDate = null;
      }

      final animalIds = _animals
          .map((a) => (a['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      final history = await _apiService.fetchMilkHistory(
        animalIds: animalIds,
        fromDate: fromDate,
        toDate: toDate,
      );

      if (!mounted) return;
      setState(() {
        _milkHistory.addAll(history);
        for (final e in _milkHistory) {
          final aid = (e['animal_id'] ?? '').toString();
          if (aid.isNotEmpty && !_animalNames.containsKey(aid)) {
            final tag = (e['animal_tag'] ?? '').toString();
            final name = (e['animal_name'] ?? '').toString();
            if (tag.isNotEmpty || name.isNotEmpty) {
              _animalNames[aid] =
                  '${tag.isNotEmpty ? tag : ''}${tag.isNotEmpty && name.isNotEmpty ? ' — ' : ''}$name';
            }
          }
        }
        _loadingHistory = false;
      });
    } catch (e) {
      debugPrint('Error fetching history: $e');
      if (!mounted) return;
      setState(() => _loadingHistory = false);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to load history: $e')));
      }
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _selectedDate && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  double _currentEntriesTotal() {
    double sum = 0.0;
    for (final id in _qtyControllers.keys) {
      final text = _qtyControllers[id]!.text.trim();
      final number = double.tryParse(text.replaceAll(',', '.')) ?? 0.0;
      sum += number;
    }
    return sum;
  }

  Future<void> _saveSingleProduction(String animalId) async {
    final qtyStr = _qtyControllers[animalId]?.text.trim() ?? '';
    if (qtyStr.isEmpty) {
      setState(() => _rowStatus[animalId] = 'error: empty');
      return;
    }
    final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
    if (qty == null || qty <= 0) {
      setState(() => _rowStatus[animalId] = 'error: invalid');
      return;
    }

    final a = _animals.firstWhere(
      (e) => (e['id'] ?? '').toString() == animalId,
      orElse: () => {},
    );
    final farmId = (a['farm_id'] ?? '').toString();

    setState(() {
      _savingRows[animalId] = true;
      _rowStatus[animalId] = 'saving';
    });

    try {
      final res = await _apiService.saveMilkProduction(
        animalId: animalId,
        farmId: farmId.isNotEmpty ? farmId : null,
        quantity: qty,
        date: _selectedDate,
        entryType: 'per_cow', // Explicitly set entryType
        session: _session.isNotEmpty
            ? _session
            : null, // Handle optional session
      );

      debugPrint('saveSingleProduction result: $res');
      if (!mounted) return;
      final success = res['success'] == true;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = success ? 'saved' : 'error';
      });
      if (success) {
        final data = res['data'] as Map<String, dynamic>?;
        if (data != null) {
          setState(() {
            _milkHistory.removeWhere(
              (m) =>
                  (m['animal_id'] ?? '').toString() ==
                      (data['animal_id'] ?? '').toString() &&
                  (m['date'] ?? '').toString() ==
                      (data['date'] ?? '').toString() &&
                  (m['entry_type'] ?? 'per_cow') ==
                      (data['entry_type'] ?? 'per_cow') &&
                  (m['session'] ?? '') == (data['session'] ?? ''),
            );
            _milkHistory.insert(0, data);
          });
        } else {
          await _fetchHistory();
        }
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Saved')));
        }
      } else {
        final err = res['body'] ?? res['error'] ?? 'Save failed';
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Save failed: $err')));
        }
      }
    } catch (e) {
      debugPrint('saveSingleProduction error: $e');
      if (!mounted) return;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = 'error: network';
      });
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Network error: $e')));
      }
    }
  }

  Future<void> _saveProduction() async {
    if (_bulkMode) {
      final qtyStr = _bulkQtyController.text.trim();
      if (qtyStr.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please enter quantity for bulk.')),
          );
        }
        return;
      }
      final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
      if (qty == null || qty <= 0) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Invalid quantity.')));
        }
        return;
      }

      setState(() => _savingAll = true);
      final payloads = <Map<String, dynamic>>[];
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final farmId = (a['farm_id'] ?? '').toString();
        payloads.add({
          'animal_id': id,
          'farm_id': farmId.isNotEmpty ? farmId : null,
          'quantity': qty,
          'date': dateStr,
          'entry_type': 'per_cow',
          'session': _session.isNotEmpty
              ? _session
              : null, // Handle optional session
          'source': 'web',
        });
      }

      final created = await _apiService.saveMilkProductionBulk(payloads);
      setState(() => _savingAll = false);
      if (created == null) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Bulk save failed')));
        }
      } else {
        setState(() {
          final incomingIds = created
              .map((c) => (c['animal_id'] ?? '').toString())
              .toSet();
          _milkHistory.removeWhere(
            (m) =>
                incomingIds.contains((m['animal_id'] ?? '').toString()) &&
                (m['date'] ?? '').toString() == dateStr &&
                (m['entry_type'] ?? 'per_cow') == 'per_cow' &&
                (m['session'] ?? '') == (_session.isNotEmpty ? _session : ''),
          );
          _milkHistory.insertAll(0, created);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Bulk saved: ${created.length} entries')),
          );
        }
      }
    } else {
      final entries = <String>[];
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final qtyStr = _qtyControllers[id]?.text.trim() ?? '';
        if (qtyStr.isNotEmpty) {
          entries.add(id);
        }
      }
      if (entries.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('No entries to save.')));
        }
        return;
      }

      setState(() => _savingAll = true);
      int successCount = 0;
      for (final id in entries) {
        await _saveSingleProduction(id);
        if (_rowStatus[id] == 'saved') {
          successCount++;
        }
      }
      setState(() => _savingAll = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              successCount == entries.length
                  ? 'All saved.'
                  : 'Saved $successCount/${entries.length} entries.',
            ),
          ),
        );
      }
    }

    await _fetchHistory();
  }

  void _clearAllInputs() {
    for (final c in _qtyControllers.values) {
      c.clear();
    }
    setState(() => _rowStatus.clear());
  }

  Future<void> _exportEntriesCsv() async {
    final rows = <List<String>>[];
    rows.add(['animal_id', 'date', 'quantity', 'session']);
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    for (final id in _qtyControllers.keys) {
      final val = _qtyControllers[id]?.text.trim() ?? '';
      if (val.isEmpty) continue;
      rows.add([id, dateStr, val, _session]);
    }
    if (rows.length <= 1) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No entries to export')));
      }
      return;
    }
    final csv = rows
        .map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(','))
        .join('\n');
    await Clipboard.setData(ClipboardData(text: csv));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('CSV copied to clipboard')));
    }
  }

  Future<void> _exportHistoryCsv() async {
    if (_milkHistory.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No history to export')));
      }
      return;
    }
    final rows = <List<String>>[];
    rows.add(['date', 'animal_id', 'animal_name', 'quantity', 'session']);
    for (final e in _milkHistory) {
      final date = e['date']?.toString() ?? '';
      final aid = e['animal_id']?.toString() ?? '';
      final aname = _animalNames[aid] ?? '';
      final q = e['quantity']?.toString() ?? '';
      final s = (e['session'] ?? '').toString();
      rows.add([date, aid, aname, q, s]);
    }
    final csv = rows
        .map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(','))
        .join('\n');
    await Clipboard.setData(ClipboardData(text: csv));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('History CSV copied to clipboard')),
      );
    }
  }

  Future<void> _showEditEntrySheet(Map<String, dynamic> entry) async {
    final id = (entry['id'] ?? '').toString();
    final dateStr = (entry['date'] ?? '').toString();
    DateTime parsedDate;
    try {
      parsedDate = DateTime.parse(dateStr);
    } catch (_) {
      parsedDate = DateTime.now();
    }
    final qtyCtl = TextEditingController(
      text: (entry['quantity'] ?? '').toString(),
    );
    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: MediaQuery.of(context).viewInsets,
        child: DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.95,
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
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    final picked = await showDatePicker(
                                      context: context,
                                      initialDate: parsedDate,
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime.now(),
                                    );
                                    if (picked != null) {
                                      setState(() => parsedDate = picked);
                                    }
                                  },
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'Date',
                                      border: OutlineInputBorder(),
                                    ),
                                    child: Text(
                                      DateFormat(
                                        'yyyy-MM-dd',
                                      ).format(parsedDate),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: InputDecorator(
                                  decoration: const InputDecoration(
                                    labelText: 'Entry type',
                                    border: OutlineInputBorder(),
                                  ),
                                  child: const Text('per_cow'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: qtyCtl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Quantity (L)',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) {
                              final t = (v ?? '').trim();
                              if (t.isEmpty) return 'Required';
                              final n = double.tryParse(t.replaceAll(',', '.'));
                              if (n == null || n <= 0) return 'Invalid';
                              return null;
                            },
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
                                      qtyCtl.text.trim().replaceAll(',', '.'),
                                    );
                                    final payload = {
                                      'quantity': newQty,
                                      'date': DateFormat(
                                        'yyyy-MM-dd',
                                      ).format(parsedDate),
                                    };
                                    Navigator.pop(context);
                                    final updated = await _apiService
                                        .updateMilkEntry(id, payload);
                                    if (updated != null) {
                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('Entry updated'),
                                          ),
                                        );
                                      }
                                      await _fetchHistory();
                                    } else {
                                      if (mounted) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Failed to update entry',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  child: const Text('Save changes'),
                                ),
                              ),
                              const SizedBox(width: 8),
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

    qtyCtl.dispose();
  }

  Future<void> _confirmDeleteEntry(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete milk entry'),
        content: const Text(
          'Are you sure you want to delete this milk record? This action cannot be undone.',
        ),
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
      final ok = await _apiService.deleteMilkEntry(id);
      if (ok) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Entry deleted')));
        }
        await _fetchHistory();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to delete entry')),
          );
        }
      }
    }
  }

  Widget _buildAddTab(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _buildCardMessage(
        icon: Icons.error_outline,
        message: _error!,
        color: Colors.red,
      );
    }
    if (_animals.isEmpty) {
      return _buildCardMessage(
        icon: Icons.pets,
        message: 'No animals available.',
      );
    }

    final total = _currentEntriesTotal();

    return RefreshIndicator(
      onRefresh: _fetchAnimals,
      child: NotificationListener<OverscrollIndicatorNotification>(
        onNotification: (OverscrollIndicatorNotification overscroll) {
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
                      ElevatedButton.icon(
                        onPressed: () => _selectDate(context),
                        icon: const Icon(Icons.calendar_today),
                        label: Text(
                          DateFormat('yyyy-MM-dd').format(_selectedDate),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        width: 140,
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Session',
                          ),
                          child: DropdownButtonHideUnderline(
                            child: DropdownButton<String>(
                              value: _session,
                              items: _sessionOptions
                                  .map(
                                    (s) => DropdownMenuItem(
                                      value: s,
                                      child: Text(
                                        s[0].toUpperCase() + s.substring(1),
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (v) {
                                if (v != null && mounted) {
                                  setState(() => _session = v);
                                }
                              },
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Checkbox(
                        value: _bulkMode,
                        onChanged: (v) =>
                            setState(() => _bulkMode = v ?? false),
                      ),
                      const Text('Bulk Mode'),
                      const Spacer(),
                      Text(
                        'Total: ${total.toStringAsFixed(2)} L',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_bulkMode)
                    Row(
                      children: [
                        SizedBox(
                          width: MediaQuery.of(context).size.width < 700
                              ? 160
                              : 260,
                          child: TextField(
                            controller: _bulkQtyController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Bulk Quantity (L)',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _savingAll ? null : _saveProduction,
                          icon: _savingAll
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_alt),
                          label: Text(_savingAll ? 'Saving...' : 'Save Bulk'),
                        ),
                      ],
                    )
                  else ...[
                    MediaQuery.of(context).size.width < 700
                        ? _buildCardListView(context)
                        : _buildDataTableView(context),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: _savingAll ? null : _saveProduction,
                          icon: _savingAll
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_alt),
                          label: Text(
                            _savingAll ? 'Saving...' : 'Save Production',
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: () => _clearAllInputs(),
                          icon: const Icon(Icons.clear),
                          label: const Text('Clear inputs'),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _exportEntriesCsv,
                          icon: const Icon(Icons.download),
                          label: const Text('Copy CSV'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDataTableView(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: Scrollbar(
        controller: _verticalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _verticalController,
          scrollDirection: Axis.vertical,
          physics: const ClampingScrollPhysics(),
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            physics: const ClampingScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.of(context).size.width - 32,
              ),
              child: DataTable(
                columnSpacing: 16,
                dataRowMinHeight: 64,
                headingTextStyle: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                columns: const [
                  DataColumn(label: Text('Tag / Name')),
                  DataColumn(label: Text('Quantity (L)')),
                  DataColumn(label: Text('Actions')),
                  DataColumn(label: Text('Status')),
                ],
                rows: _animals.map((a) {
                  final id = (a['id'] ?? '').toString();
                  final tag = (a['tag'] ?? '').toString();
                  final name = (a['name'] ?? '').toString();
                  final controller = _qtyControllers[id]!;
                  final statusText = _rowStatus[id] ?? '';
                  final saving = _savingRows[id] ?? false;

                  return DataRow(
                    cells: [
                      DataCell(Text('$tag — $name')),
                      DataCell(
                        SizedBox(
                          width: 160,
                          child: TextField(
                            controller: controller,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 10,
                              ),
                              hintText: 'e.g. 3.2',
                              border: OutlineInputBorder(),
                              errorText: statusText.startsWith('error')
                                  ? 'Invalid'
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      DataCell(
                        Row(
                          children: [
                            IconButton(
                              onPressed: saving
                                  ? null
                                  : () => _saveSingleProduction(id),
                              icon: saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.save_alt),
                            ),
                            IconButton(
                              onPressed: () {
                                controller.clear();
                                setState(() => _rowStatus[id] = '');
                              },
                              icon: const Icon(Icons.clear),
                            ),
                          ],
                        ),
                      ),
                      DataCell(
                        Text(
                          statusText == 'saved'
                              ? 'Saved'
                              : statusText.startsWith('error')
                              ? 'Error'
                              : '',
                          style: TextStyle(
                            color: statusText.startsWith('error')
                                ? Colors.red
                                : (statusText == 'saved'
                                      ? Colors.green
                                      : Colors.black87),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardListView(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _animals.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        final a = _animals[i];
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        final controller = _qtyControllers[id]!;
        final statusText = _rowStatus[id] ?? '';
        final saving = _savingRows[id] ?? false;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(child: Text('$tag — $name')),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      hintText: 'e.g. 3.2',
                      border: OutlineInputBorder(),
                      errorText: statusText.startsWith('error')
                          ? 'Invalid'
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: saving ? null : () => _saveSingleProduction(id),
                  child: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHistoryTab(BuildContext context) {
    if (_loadingHistory)
      return const Center(child: CircularProgressIndicator());
    if (_milkHistory.isEmpty) {
      return _buildCardMessage(
        icon: Icons.history,
        message: 'No history available.',
      );
    }

    final Map<DateTime, double> dailyTotals = {};
    for (final entry in _milkHistory) {
      final dateStr = entry['date'] as String?;
      if (dateStr != null) {
        final date = DateTime.parse(dateStr);
        final qty = (entry['quantity'] as num?)?.toDouble() ?? 0.0;
        final key = DateTime(date.year, date.month, date.day);
        dailyTotals[key] = (dailyTotals[key] ?? 0) + qty;
      }
    }

    final sortedDates = dailyTotals.keys.toList()
      ..sort((a, b) => a.compareTo(b));
    const maxPoints = 60;
    List<DateTime> chartDates = sortedDates;
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
          barRods: [
            BarChartRodData(
              toY: total,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      );
    }

    final overallTotal = dailyTotals.values.fold<double>(0, (p, e) => p + e);
    final avg = dailyTotals.isEmpty ? 0.0 : overallTotal / dailyTotals.length;

    return RefreshIndicator(
      onRefresh: _fetchHistory,
      child: NotificationListener<OverscrollIndicatorNotification>(
        onNotification: (OverscrollIndicatorNotification overscroll) {
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
                          if (v != null && mounted) {
                            setState(() => _historyFilter = v);
                          }
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
                          return DataRow(
                            cells: [
                              DataCell(Text(date)),
                              DataCell(Text(animalName)),
                              DataCell(Text(quantity)),
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
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardMessage({
    required IconData icon,
    required String message,
    Color? color,
  }) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color ?? Colors.black54),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Milk Production'),
          actions: [
            IconButton(
              onPressed: _fetchAnimals,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
            IconButton(
              onPressed: _exportHistoryCsv,
              icon: const Icon(Icons.download),
              tooltip: 'Copy history CSV',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Add Production'),
              Tab(text: 'History & Chart'),
            ],
          ),
        ),
        body: TabBarView(
          children: [_buildAddTab(context), _buildHistoryTab(context)],
        ),
      ),
    );
  }
}
*/







/*the best
// lib/milk_production.dart
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'api_service.dart';

class MilkProductionPage extends StatefulWidget {
  final String token;
  const MilkProductionPage({super.key, required this.token});

  @override
  State<MilkProductionPage> createState() => _MilkProductionPageState();
}

class _MilkProductionPageState extends State<MilkProductionPage> {
  final List<Map<String, dynamic>> _animals = [];
  final List<Map<String, dynamic>> _milkHistory = [];
  final Map<String, String> _animalNames = {};

  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, String> _rowStatus = {};
  final Map<String, bool> _savingRows = {};

  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  bool _loading = true;
  bool _loadingHistory = false;
  bool _savingAll = false;
  String? _error;
  late ApiService _apiService;

  DateTime _selectedDate = DateTime.now();
  bool _bulkMode = false;
  final TextEditingController _bulkQtyController = TextEditingController();

  String _historyFilter = 'all';
  final List<String> _filterOptions = ['all', 'last_week', 'last_month', 'last_year'];

  // SESSION support
  String _session = 'morning';
  final List<String> _sessionOptions = ['morning', 'afternoon', 'evening', 'night'];

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAnimals();
  }

  @override
  void dispose() {
    _bulkQtyController.dispose();
    for (final c in _qtyControllers.values) c.dispose();
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  Future<void> _fetchAnimals() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals.clear();
      _animalNames.clear();
      _qtyControllers.clear();
      _rowStatus.clear();
      _savingRows.clear();
    });

    try {
      final farmIds = await _api_service_getUserFarmIds();
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }

      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      for (final a in animals) {
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        if (id.isNotEmpty) {
          _animalNames[id] = '$tag — $name';
          _qtyControllers[id] = _qtyControllers[id] ?? TextEditingController();
          _savingRows[id] = false;
        }
        _animals.add(a);
      }

      setState(() {
        _loading = false;
      });

      await _fetchHistory();
    } catch (e) {
      debugPrint('Error fetching animals: $e');
      setState(() {
        _error = 'Failed to load animals. Please check your connection.';
        _loading = false;
      });
    }
  }

  Future<List<String>> _api_service_getUserFarmIds() async {
    try {
      return await _apiService.getUserFarmIds();
    } catch (e) {
      debugPrint('getUserFarmIds error: $e');
      return [];
    }
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _loadingHistory = true;
      _milkHistory.clear();
    });

    try {
      DateTime? fromDate;
      final toDate = DateTime.now();

      switch (_historyFilter) {
        case 'last_week':
          fromDate = toDate.subtract(const Duration(days: 7));
          break;
        case 'last_month':
          fromDate = toDate.subtract(const Duration(days: 30));
          break;
        case 'last_year':
          fromDate = toDate.subtract(const Duration(days: 365));
          break;
        default:
          fromDate = null;
      }

      final animalIds = _animals.map((a) => (a['id'] ?? '').toString()).where((id) => id.isNotEmpty).toList();
      final history = await _apiService.fetchMilkHistory(animalIds: animalIds, fromDate: fromDate, toDate: toDate);

      if (!mounted) return;
      setState(() {
        _milkHistory.addAll(history);
        for (final e in _milkHistory) {
          final aid = (e['animal_id'] ?? '').toString();
          if (aid.isNotEmpty && !_animalNames.containsKey(aid)) {
            final tag = (e['animal_tag'] ?? '').toString();
            final name = (e['animal_name'] ?? '').toString();
            if (tag.isNotEmpty || name.isNotEmpty) _animalNames[aid] = '${tag.isNotEmpty ? tag : ''}${tag.isNotEmpty && name.isNotEmpty ? ' — ' : ''}$name';
          }
        }
        _loadingHistory = false;
      });
    } catch (e) {
      debugPrint('Error fetching history: $e');
      if (!mounted) return;
      setState(() => _loadingHistory = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load history: $e')));
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final picked = await showDatePicker(context: context, initialDate: _selectedDate, firstDate: DateTime(2000), lastDate: DateTime.now());
    if (picked != null && picked != _selectedDate && mounted) setState(() => _selectedDate = picked);
  }

  double _currentEntriesTotal() {
    double sum = 0.0;
    for (final id in _qtyControllers.keys) {
      final text = _qtyControllers[id]!.text.trim();
      final number = double.tryParse(text.replaceAll(',', '.')) ?? 0.0;
      sum += number;
    }
    return sum;
  }

  Future<void> _saveSingleProduction(String animalId) async {
    final qtyStr = _qtyControllers[animalId]?.text.trim() ?? '';
    if (qtyStr.isEmpty) {
      setState(() => _rowStatus[animalId] = 'error: empty');
      return;
    }
    final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
    if (qty == null || qty <= 0) {
      setState(() => _rowStatus[animalId] = 'error: invalid');
      return;
    }

    final a = _animals.firstWhere((e) => (e['id'] ?? '').toString() == animalId, orElse: () => {});
    final farmId = (a['farm_id'] ?? '').toString();

    setState(() {
      _savingRows[animalId] = true;
      _rowStatus[animalId] = 'saving';
    });

    try {
      final res = await _apiService.saveMilkProduction(
        animalId: animalId,
        farmId: farmId.isNotEmpty ? farmId : null,
        quantity: qty,
        date: _selectedDate,
        session: _session, // send session
      );

      debugPrint('saveSingleProduction result: $res');
      if (!mounted) return;
      final success = res['success'] == true;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = success ? 'saved' : 'error';
      });
      if (success) {
        final data = res['data'] as Map<String, dynamic>?;
        if (data != null) {
          setState(() {
            _milkHistory.removeWhere((m) =>
                (m['animal_id'] ?? '').toString() == (data['animal_id'] ?? '').toString() &&
                (m['date'] ?? '').toString() == (data['date'] ?? '').toString() &&
                (m['entry_type'] ?? 'per_cow') == (data['entry_type'] ?? 'per_cow') &&
                (m['session'] ?? '') == (data['session'] ?? ''));
            _milkHistory.insert(0, data);
          });
        } else {
          await _fetchHistory();
        }
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
      } else {
        final err = res['body'] ?? res['error'] ?? 'Save failed';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $err')));
      }
    } catch (e) {
      debugPrint('saveSingleProduction error: $e');
      if (!mounted) return;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = 'error: network';
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Network error: $e')));
    }
  }

  Future<void> _saveProduction() async {
    if (_bulkMode) {
      final qtyStr = _bulkQtyController.text.trim();
      if (qtyStr.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter quantity for bulk.')));
        return;
      }
      final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
      if (qty == null || qty <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid quantity.')));
        return;
      }

      setState(() => _savingAll = true);
      final payloads = <Map<String, dynamic>>[];
      final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final farmId = (a['farm_id'] ?? '').toString();
        payloads.add({
          'animal_id': id,
          'farm_id': farmId.isNotEmpty ? farmId : null,
          'quantity': qty,
          'date': dateStr,
          'entry_type': 'per_cow',
          'session': _session,
          'source': 'web',
        });
      }

      final created = await _apiService.saveMilkProductionBulk(payloads);
      setState(() => _savingAll = false);
      if (created == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bulk save failed')));
      } else {
        setState(() {
          final incomingIds = created.map((c) => (c['animal_id'] ?? '').toString()).toSet();
          _milkHistory.removeWhere((m) =>
              incomingIds.contains((m['animal_id'] ?? '').toString()) &&
              (m['date'] ?? '').toString() == dateStr &&
              (m['entry_type'] ?? 'per_cow') == 'per_cow' &&
              (m['session'] ?? '') == _session);
          _milkHistory.insertAll(0, created);
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk saved: ${created.length} entries')));
      }
    } else {
      final entries = <String>[];
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final qtyStr = _qtyControllers[id]?.text.trim() ?? '';
        if (qtyStr.isNotEmpty) entries.add(id);
      }
      if (entries.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No entries to save.')));
        return;
      }

      setState(() => _savingAll = true);
      int successCount = 0;
      for (final id in entries) {
        await _saveSingleProduction(id);
        if (_rowStatus[id] == 'saved') successCount++;
      }
      setState(() => _savingAll = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successCount == entries.length ? 'All saved.' : 'Saved $successCount/${entries.length} entries.')));
    }

    await _fetchHistory();
  }

  void _clearAllInputs() {
    for (final c in _qtyControllers.values) c.clear();
    setState(() => _rowStatus.clear());
  }

  Future<void> _exportEntriesCsv() async {
    final rows = <List<String>>[];
    rows.add(['animal_id', 'date', 'quantity', 'session']);
    final dateStr = DateFormat('yyyy-MM-dd').format(_selectedDate);
    for (final id in _qtyControllers.keys) {
      final val = _qtyControllers[id]?.text.trim() ?? '';
      if (val.isEmpty) continue;
      rows.add([id, dateStr, val, _session]);
    }
    if (rows.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No entries to export')));
      return;
    }
    final csv = rows.map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(',')).join('\n');
    await Clipboard.setData(ClipboardData(text: csv));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV copied to clipboard')));
  }

  Future<void> _exportHistoryCsv() async {
    if (_milkHistory.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No history to export')));
      return;
    }
    final rows = <List<String>>[];
    rows.add(['date', 'animal_id', 'animal_name', 'quantity', 'session']);
    for (final e in _milkHistory) {
      final date = e['date']?.toString() ?? '';
      final aid = e['animal_id']?.toString() ?? '';
      final aname = _animalNames[aid] ?? '';
      final q = e['quantity']?.toString() ?? '';
      final s = (e['session'] ?? '').toString();
      rows.add([date, aid, aname, q, s]);
    }
    final csv = rows.map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(',')).join('\n');
    await Clipboard.setData(ClipboardData(text: csv));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('History CSV copied to clipboard')));
  }

  Future<void> _showEditEntrySheet(Map<String, dynamic> entry) async {
    final id = (entry['id'] ?? '').toString();
    final dateStr = (entry['date'] ?? '').toString();
    DateTime parsedDate;
    try {
      parsedDate = DateTime.parse(dateStr);
    } catch (_) {
      parsedDate = DateTime.now();
    }
    final qtyCtl = TextEditingController(text: (entry['quantity'] ?? '').toString());
    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: MediaQuery.of(context).viewInsets,
        child: DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return SingleChildScrollView(
              controller: controller,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('Edit milk entry', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    Form(
                      key: formKey,
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    final picked = await showDatePicker(
                                      context: context,
                                      initialDate: parsedDate,
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime.now(),
                                    );
                                    if (picked != null) setState(() => parsedDate = picked);
                                  },
                                  child: InputDecorator(
                                    decoration: const InputDecoration(labelText: 'Date', border: OutlineInputBorder()),
                                    child: Text(DateFormat('yyyy-MM-dd').format(parsedDate)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: InputDecorator(decoration: const InputDecoration(labelText: 'Entry type', border: OutlineInputBorder()), child: const Text('per_cow'))),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: qtyCtl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Quantity (L)', border: OutlineInputBorder()),
                            validator: (v) {
                              final t = (v ?? '').trim();
                              if (t.isEmpty) return 'Required';
                              final n = double.tryParse(t.replaceAll(',', '.'));
                              if (n == null || n <= 0) return 'Invalid';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: () async {
                                    if (!formKey.currentState!.validate()) return;
                                    final newQty = double.parse(qtyCtl.text.trim().replaceAll(',', '.'));
                                    final payload = {'quantity': newQty, 'date': DateFormat('yyyy-MM-dd').format(parsedDate)};
                                    Navigator.pop(context);
                                    final updated = await _apiService.updateMilkEntry(id, payload);
                                    if (updated != null) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry updated')));
                                      await _fetchHistory();
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update entry')));
                                    }
                                  },
                                  child: const Text('Save changes'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                            ],
                          )
                        ],
                      ),
                    )
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

    qtyCtl.dispose();
  }

  Future<void> _confirmDeleteEntry(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete milk entry'),
        content: const Text('Are you sure you want to delete this milk record? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );

    if (confirmed == true) {
      final ok = await _apiService.deleteMilkEntry(id);
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry deleted')));
        await _fetchHistory();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete entry')));
      }
    }
  }

  Widget _buildAddTab(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _buildCardMessage(icon: Icons.error_outline, message: _error!, color: Colors.red);
    if (_animals.isEmpty) return _buildCardMessage(icon: Icons.pets, message: 'No animals available.');

    final total = _currentEntriesTotal();

    return RefreshIndicator(
      onRefresh: _fetchAnimals,
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final narrow = width < 700;

        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                ElevatedButton.icon(onPressed: () => _selectDate(context), icon: const Icon(Icons.calendar_today), label: Text(DateFormat('yyyy-MM-dd').format(_selectedDate))),
                const SizedBox(width: 12),
                SizedBox(
                  width: 140,
                  child: InputDecorator(
                    decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Session'),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _session,
                        items: _sessionOptions.map((s) => DropdownMenuItem(value: s, child: Text(s[0].toUpperCase() + s.substring(1)))).toList(),
                        onChanged: (v) {
                          if (v != null && mounted) setState(() => _session = v);
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Checkbox(value: _bulkMode, onChanged: (v) => setState(() => _bulkMode = v ?? false)),
                const Text('Bulk Mode'),
                const Spacer(),
                Text('Total: ${total.toStringAsFixed(2)} L', style: Theme.of(context).textTheme.titleMedium),
              ]),
              const SizedBox(height: 16),
              if (_bulkMode)
                Row(children: [
                  SizedBox(width: narrow ? 160 : 260, child: TextField(controller: _bulkQtyController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Bulk Quantity (L)', border: OutlineInputBorder()))),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(onPressed: _savingAll ? null : _saveProduction, icon: _savingAll ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt), label: Text(_savingAll ? 'Saving...' : 'Save Bulk'))
                ])
              else ...[
                if (!narrow) _buildDataTableView(context) else _buildCardListView(context),
                const SizedBox(height: 12),
                Row(children: [
                  ElevatedButton.icon(onPressed: _savingAll ? null : _saveProduction, icon: _savingAll ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt), label: Text(_savingAll ? 'Saving...' : 'Save Production')),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(onPressed: () => _clearAllInputs(), icon: const Icon(Icons.clear), label: const Text('Clear inputs')),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(onPressed: _exportEntriesCsv, icon: const Icon(Icons.download), label: const Text('Copy CSV')),
                ])
              ]
            ]),
          ),
        );
      }),
    );
  }

  Widget _buildDataTableView(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: Scrollbar(
        controller: _verticalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _verticalController,
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 32),
              child: DataTable(
                columnSpacing: 16,
                dataRowMinHeight: 64,
                headingTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                columns: const [
                  DataColumn(label: Text('Tag / Name')),
                  DataColumn(label: Text('Quantity (L)')),
                  DataColumn(label: Text('Actions')),
                  DataColumn(label: Text('Status')),
                ],
                rows: _animals.map((a) {
                  final id = (a['id'] ?? '').toString();
                  final tag = (a['tag'] ?? '').toString();
                  final name = (a['name'] ?? '').toString();
                  final controller = _qtyControllers[id]!;
                  final statusText = _rowStatus[id] ?? '';
                  final saving = _savingRows[id] ?? false;

                  return DataRow(cells: [
                    DataCell(Text('$tag — $name')),
                    DataCell(SizedBox(
                        width: 160,
                        child: TextField(
                          controller: controller,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10), hintText: 'e.g. 3.2', border: OutlineInputBorder(), errorText: statusText.startsWith('error') ? 'Invalid' : null),
                        ))),
                    DataCell(Row(children: [
                      IconButton(onPressed: saving ? null : () => _saveSingleProduction(id), icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt)),
                      IconButton(onPressed: () {
                        controller.clear();
                        setState(() => _rowStatus[id] = '');
                      }, icon: const Icon(Icons.clear)),
                    ])),
                    DataCell(Text(statusText == 'saved' ? 'Saved' : statusText.startsWith('error') ? 'Error' : '', style: TextStyle(color: statusText.startsWith('error') ? Colors.red : (statusText == 'saved' ? Colors.green : Colors.black87)))),
                  ]);
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardListView(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _animals.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        final a = _animals[i];
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        final controller = _qtyControllers[id]!;
        final statusText = _rowStatus[id] ?? '';
        final saving = _savingRows[id] ?? false;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: Text('$tag — $name')),
              SizedBox(width: 120, child: TextField(controller: controller, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(hintText: 'e.g. 3.2', border: OutlineInputBorder(), errorText: statusText.startsWith('error') ? 'Invalid' : null))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: saving ? null : () => _saveSingleProduction(id), child: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save')),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildHistoryTab(BuildContext context) {
    if (_loadingHistory) return const Center(child: CircularProgressIndicator());
    if (_milkHistory.isEmpty) return _buildCardMessage(icon: Icons.history, message: 'No history available.');

    final Map<DateTime, double> dailyTotals = {};
    for (final entry in _milkHistory) {
      final dateStr = entry['date'] as String?;
      if (dateStr != null) {
        final date = DateTime.parse(dateStr);
        final qty = (entry['quantity'] as num?)?.toDouble() ?? 0.0;
        final key = DateTime(date.year, date.month, date.day);
        dailyTotals[key] = (dailyTotals[key] ?? 0) + qty;
      }
    }

    final sortedDates = dailyTotals.keys.toList()..sort((a, b) => a.compareTo(b));
    final maxPoints = 60;
    List<DateTime> chartDates = sortedDates;
    if (sortedDates.length > maxPoints) chartDates = sortedDates.sublist(sortedDates.length - maxPoints);

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < chartDates.length; i++) {
      final date = chartDates[i];
      final total = dailyTotals[date] ?? 0.0;
      barGroups.add(BarChartGroupData(x: i, barRods: [BarChartRodData(toY: total, color: Theme.of(context).colorScheme.primary)]));
    }

    final overallTotal = dailyTotals.values.fold<double>(0, (p, e) => p + e);
    final avg = dailyTotals.isEmpty ? 0.0 : overallTotal / dailyTotals.length;

    return RefreshIndicator(
      onRefresh: _fetchHistory,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              DropdownButton<String>(
                value: _historyFilter,
                items: _filterOptions.map((f) {
                  var label = f.replaceAll('_', ' ');
                  label = label[0].toUpperCase() + label.substring(1);
                  return DropdownMenuItem(value: f, child: Text(label));
                }).toList(),
                onChanged: (v) {
                  if (v != null && mounted) setState(() => _historyFilter = v);
                  _fetchHistory();
                },
              ),
              const SizedBox(width: 16),
              IconButton(onPressed: _fetchHistory, icon: const Icon(Icons.refresh), tooltip: 'Refresh History'),
              const Spacer(),
              Text('Total: ${overallTotal.toStringAsFixed(1)} L'),
              const SizedBox(width: 12),
              Text('Avg/day: ${avg.toStringAsFixed(2)} L'),
            ]),
            const SizedBox(height: 16),
            Text('Daily Milk Production Chart', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: BarChart(
                BarChartData(
                  barGroups: barGroups,
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, getTitlesWidget: (double value, TitleMeta meta) {
                      final idx = value.toInt();
                      if (idx >= 0 && idx < chartDates.length) {
                        return Padding(padding: const EdgeInsets.only(top: 8.0), child: Text(DateFormat('MM-dd').format(chartDates[idx]), style: const TextStyle(fontSize: 10)));
                      }
                      return const SizedBox();
                    })),
                    leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: (double value, TitleMeta meta) => Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 10)))),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  gridData: const FlGridData(show: true, drawVerticalLine: false),
                  barTouchData: BarTouchData(enabled: true, touchTooltipData: BarTouchTooltipData(getTooltipItem: (group, groupIndex, rod, rodIndex) {
                    if (groupIndex >= 0 && groupIndex < chartDates.length) {
                      final date = DateFormat('MM-dd').format(chartDates[groupIndex]);
                      return BarTooltipItem('$date\n${rod.toY.toStringAsFixed(1)} L', const TextStyle(color: Colors.white));
                    }
                    return null;
                  })),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text('Production History Table', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(
              elevation: 2,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  columnSpacing: 12,
                  columns: const [
                    DataColumn(label: Text('Date')),
                    DataColumn(label: Text('Animal')),
                    DataColumn(label: Text('Quantity (L)')),
                    DataColumn(label: Text('Actions')),
                  ],
                  rows: _milkHistory.map((entry) {
                    final id = (entry['id'] ?? '').toString();
                    final date = entry['date']?.toString() ?? 'N/A';
                    final animalId = (entry['animal_id'] ?? '').toString();
                    final animalName = _animalNames[animalId] ?? (entry['animal_tag'] ?? entry['animal_name'] ?? 'Unknown').toString();
                    final quantity = (entry['quantity'] ?? '').toString();
                    return DataRow(cells: [
                      DataCell(Text(date)),
                      DataCell(Text(animalName)),
                      DataCell(Text(quantity)),
                      DataCell(Row(children: [
                        IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit, size: 20), onPressed: () => _showEditEntrySheet(entry)),
                        IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => _confirmDeleteEntry(id)),
                      ])),
                    ]);
                  }).toList(),
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _buildCardMessage({required IconData icon, required String message, Color? color}) {
    return Card(elevation: 2, margin: const EdgeInsets.all(16), child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 48, color: color ?? Colors.black54), const SizedBox(height: 8), Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge)])));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Milk Production'),
          actions: [
            IconButton(onPressed: _fetchAnimals, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
            IconButton(onPressed: _exportHistoryCsv, icon: const Icon(Icons.download), tooltip: 'Copy history CSV'),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Add Production'), Tab(text: 'History & Chart')]),
        ),
        body: TabBarView(children: [_buildAddTab(context), _buildHistoryTab(context)]),
      ),
    );
  }
}
*/
















/*
// milk_production_with_crud.dart working with edit..
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart';
import 'api_service.dart';

class MilkProductionPage extends StatefulWidget {
  final String token;
  const MilkProductionPage({super.key, required this.token});

  @override
  State<MilkProductionPage> createState() => _MilkProductionPageState();
}

class _MilkProductionPageState extends State<MilkProductionPage> {
  final List<Map<String, dynamic>> _animals = [];
  final List<Map<String, dynamic>> _milkHistory = [];
  final Map<String, String> _animalNames = {};

  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, String> _rowStatus = {};
  final Map<String, bool> _savingRows = {};

  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  bool _loading = true;
  bool _loadingHistory = false;
  bool _savingAll = false;
  String? _error;
  late ApiService _apiService;

  DateTime _selectedDate = DateTime.now();
  bool _bulkMode = false;
  final TextEditingController _bulkQtyController = TextEditingController();

  String _historyFilter = 'all';
  final List<String> _filterOptions = [
    'all',
    'last_week',
    'last_month',
    'last_year',
  ];

  @override
  void initState() {
    super.initState();
    _api_service_init();
  }

  void _api_service_init() {
    _apiService = ApiService(widget.token);
    _fetchAnimals();
  }

  Future<void> _fetchAnimals() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals.clear();
      _animalNames.clear();
      _qtyControllers.clear();
      _rowStatus.clear();
      _savingRows.clear();
    });

    try {
      final farmIds = await _api_service_getUserFarmIds();
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }

      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      for (final a in animals) {
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        if (id.isNotEmpty) {
          _animalNames[id] = '$tag — $name';
          _qtyControllers[id] = _qtyControllers[id] ?? TextEditingController();
          _savingRows[id] = false;
        }
        _animals.add(a);
      }

      setState(() {
        _loading = false;
      });

      await _fetchHistory();
    } catch (e) {
      debugPrint('Error fetching animals: $e');
      setState(() {
        _error = 'Failed to load animals. Please check your connection.';
        _loading = false;
      });
    }
  }

  Future<List<String>> _api_service_getUserFarmIds() async {
    try {
      return await _apiService.getUserFarmIds();
    } catch (e) {
      debugPrint('getUserFarmIds error: $e');
      return [];
    }
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _loadingHistory = true;
      _milkHistory.clear();
    });

    try {
      DateTime? fromDate;
      DateTime toDate = DateTime.now();

      switch (_historyFilter) {
        case 'last_week':
          fromDate = toDate.subtract(const Duration(days: 7));
          break;
        case 'last_month':
          fromDate = toDate.subtract(const Duration(days: 30));
          break;
        case 'last_year':
          fromDate = toDate.subtract(const Duration(days: 365));
          break;
        default:
          fromDate = null;
      }

      final animalIds = _animals.map((a) => (a['id'] ?? '').toString()).where((id) => id.isNotEmpty).toList();
      final history = await _apiService.fetchMilkHistory(animalIds: animalIds, fromDate: fromDate, toDate: toDate);

      if (!mounted) return;
      setState(() {
        _milkHistory.addAll(history);
        for (final e in _milkHistory) {
          final aid = (e['animal_id'] ?? '').toString();
          if (aid.isNotEmpty && !_animalNames.containsKey(aid)) {
            final tag = (e['animal_tag'] ?? '').toString();
            final name = (e['animal_name'] ?? '').toString();
            if (tag.isNotEmpty || name.isNotEmpty) _animalNames[aid] = '${tag.isNotEmpty ? tag : ''}${tag.isNotEmpty && name.isNotEmpty ? ' — ' : ''}${name}';
          }
        }
        _loadingHistory = false;
      });
    } catch (e) {
      debugPrint('Error fetching history: $e');
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load history: $e')));
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _selectedDate && mounted) {
      setState(() => _selectedDate = picked);
    }
  }

  double _currentEntriesTotal() {
    double sum = 0.0;
    for (final id in _qtyControllers.keys) {
      final val = _qtyControllers[id]?.text.trim() ?? '';
      final num = double.tryParse(val.replaceAll(',', '.')) ?? 0.0;
      sum += num;
    }
    return sum;
  }

  /// Save single production: NOTE — no 'session' field is sent to the server.
  Future<void> _saveSingleProduction(String animalId) async {
    final qtyStr = _qtyControllers[animalId]?.text.trim() ?? '';
    if (qtyStr.isEmpty) {
      setState(() => _rowStatus[animalId] = 'error: empty');
      return;
    }
    final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
    if (qty == null || qty <= 0) {
      setState(() => _rowStatus[animalId] = 'error: invalid');
      return;
    }
    final a = _animals.firstWhere((e) => (e['id'] ?? '').toString() == animalId, orElse: () => {});
    final farmId = (a['farm_id'] ?? '').toString();

    setState(() {
      _savingRows[animalId] = true;
      _rowStatus[animalId] = 'saving';
    });

    try {
      final result = await _apiService.saveMilkProduction(
        animalId: animalId,
        farmId: farmId.isNotEmpty ? farmId : null,
        quantity: qty,
        date: _selectedDate,
      );

      if (!mounted) return;

      final success = result['success'] == true;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = success ? 'saved' : 'error: ${result['statusCode'] ?? 'err'}';
      });

      if (!success) {
        final body = result['body'] ?? result['error'] ?? 'Unknown error';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: $body')));
        debugPrint('Save failed details: $result');
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
        final created = result['data'] as Map<String, dynamic>?;
        if (created != null) {
          setState(() {
            _milkHistory.removeWhere((m) =>
                (m['animal_id'] ?? '').toString() == created['animal_id'].toString() &&
                (m['date'] ?? '').toString() == created['date'].toString() &&
                (m['entry_type'] ?? 'per_cow') == (created['entry_type'] ?? 'per_cow'));
            _milkHistory.insert(0, created);
            _animalNames[created['animal_id']?.toString() ?? ''] = _animalNames[created['animal_id']?.toString()] ?? (_animalNames[animalId] ?? '');
          });
        } else {
          await _fetchHistory();
        }
      }
    } catch (e) {
      debugPrint('saveSingleProduction error: $e');
      if (!mounted) return;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = 'error: network';
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Network error: $e')));
    }
  }

  Future<void> _saveProduction() async {
    if (_bulkMode) {
      final qtyStr = _bulkQtyController.text.trim();
      if (qtyStr.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter quantity for bulk.')));
        return;
      }
      final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
      if (qty == null || qty <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid quantity.')));
        return;
      }

      setState(() => _savingAll = true);

      final payloads = <Map<String, dynamic>>[];
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final farmId = (a['farm_id'] ?? '').toString();
        payloads.add({
          'animal_id': id,
          'farm_id': farmId.isNotEmpty ? farmId : null,
          'quantity': qty,
          'date': DateFormat('yyyy-MM-dd').format(_selectedDate),
          'entry_type': 'per_cow',
          'source': 'web',
        });
      }

      final createdList = await _apiService.saveMilkProductionBulk(payloads);
      setState(() => _savingAll = false);

      if (createdList == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Bulk save failed')));
      } else {
        setState(() {
          final incomingIds = createdList.map((c) => (c['animal_id'] ?? '').toString()).toSet();
          final targetDate = DateFormat('yyyy-MM-dd').format(_selectedDate);
          _milkHistory.removeWhere((m) {
            final mid = (m['animal_id'] ?? '').toString();
            final mdate = (m['date'] ?? '').toString();
            return incomingIds.contains(mid) && mdate == targetDate && (m['entry_type'] ?? 'per_cow') == 'per_cow';
          });
          _milkHistory.insertAll(0, createdList);
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Bulk save completed: ${createdList.length} entries returned')));
      }
    } else {
      final entries = <String>[];
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final qtyStr = _qtyControllers[id]?.text.trim() ?? '';
        if (qtyStr.isNotEmpty) entries.add(id);
      }
      if (entries.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No entries to save.')));
        return;
      }

      setState(() => _savingAll = true);
      int successCount = 0;

      for (final id in entries) {
        await _saveSingleProduction(id);
        if (_rowStatus[id] == 'saved') successCount++;
      }

      setState(() => _savingAll = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successCount == entries.length ? 'All saved.' : 'Saved $successCount/${entries.length} entries.')));
    }

    await _fetchHistory();
  }

  void _clearAllInputs() {
    for (final c in _qtyControllers.values) c.clear();
    setState(() => _rowStatus.clear());
  }

  Future<void> _exportEntriesCsv() async {
    final rows = <List<String>>[];
    rows.add(['animal_id', 'date', 'quantity']);
    for (final id in _qtyControllers.keys) {
      final val = _qtyControllers[id]?.text.trim() ?? '';
      if (val.isEmpty) continue;
      rows.add([id, DateFormat('yyyy-MM-dd').format(_selectedDate), val]);
    }
    if (rows.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No entries to export')));
      return;
    }
    final csv = rows.map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(',')).join('\n');
    await Clipboard.setData(ClipboardData(text: csv));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV copied to clipboard')));
  }

  Future<void> _exportHistoryCsv() async {
    if (_milkHistory.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No history to export')));
      return;
    }
    final rows = <List<String>>[];
    rows.add(['date', 'animal_id', 'animal_name', 'quantity']);
    for (final e in _milkHistory) {
      final date = e['date']?.toString() ?? '';
      final aid = e['animal_id']?.toString() ?? '';
      final aname = _animalNames[aid] ?? '';
      final q = e['quantity']?.toString() ?? '';
      rows.add([date, aid, aname, q]);
    }
    final csv = rows.map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(',')).join('\n');
    await Clipboard.setData(ClipboardData(text: csv));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('History CSV copied to clipboard')));
  }

  Future<void> _showEditEntrySheet(Map<String, dynamic> entry) async {
    final id = (entry['id'] ?? '').toString();
    final dateStr = (entry['date'] ?? '').toString();
    DateTime parsedDate;
    try {
      parsedDate = DateTime.parse(dateStr);
    } catch (_) {
      parsedDate = DateTime.now();
    }
    final qtyCtl = TextEditingController(text: (entry['quantity'] ?? '').toString());
    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: MediaQuery.of(context).viewInsets,
        child: DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return SingleChildScrollView(
              controller: controller,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('Edit milk entry', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 12),
                    Form(
                      key: formKey,
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    final picked = await showDatePicker(
                                      context: context,
                                      initialDate: parsedDate,
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime.now(),
                                    );
                                    if (picked != null) setState(() => parsedDate = picked);
                                  },
                                  child: InputDecorator(
                                    decoration: const InputDecoration(labelText: 'Date', border: OutlineInputBorder()),
                                    child: Text(DateFormat('yyyy-MM-dd').format(parsedDate)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: InputDecorator(decoration: const InputDecoration(labelText: 'Entry type', border: OutlineInputBorder()), child: const Text('per_cow'))),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: qtyCtl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Quantity (L)', border: OutlineInputBorder()),
                            validator: (v) {
                              final t = (v ?? '').trim();
                              if (t.isEmpty) return 'Required';
                              final n = double.tryParse(t.replaceAll(',', '.'));
                              if (n == null || n <= 0) return 'Invalid';
                              return null;
                            },
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: () async {
                                    if (!formKey.currentState!.validate()) return;
                                    final newQty = double.parse(qtyCtl.text.trim().replaceAll(',', '.'));
                                    final payload = {'quantity': newQty, 'date': DateFormat('yyyy-MM-dd').format(parsedDate)};
                                    Navigator.pop(context);
                                    final updated = await _apiService.updateMilkEntry(id, payload);
                                    if (updated != null) {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry updated')));
                                      await _fetchHistory();
                                    } else {
                                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to update entry')));
                                    }
                                  },
                                  child: const Text('Save changes'),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel'))),
                            ],
                          )
                        ],
                      ),
                    )
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

    qtyCtl.dispose();
  }

  Future<void> _confirmDeleteEntry(String id) async {
    final c = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete milk entry'),
        content: const Text('Are you sure you want to delete this milk record? This action cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (c == true) {
      final ok = await _apiService.deleteMilkEntry(id);
      if (ok) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Entry deleted')));
        await _fetchHistory();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete entry')));
      }
    }
  }

  Widget _buildAddTab(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _buildCardMessage(icon: Icons.error_outline, message: _error!, color: Colors.red);
    if (_animals.isEmpty) return _buildCardMessage(icon: Icons.pets, message: 'No animals available.');

    final total = _currentEntriesTotal();

    return RefreshIndicator(
      onRefresh: _fetchAnimals,
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final narrow = width < 700;

        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                ElevatedButton.icon(onPressed: () => _selectDate(context), icon: const Icon(Icons.calendar_today), label: Text(DateFormat('yyyy-MM-dd').format(_selectedDate))),
                const SizedBox(width: 12),
                Checkbox(value: _bulkMode, onChanged: (v) => setState(() => _bulkMode = v ?? false)),
                const Text('Bulk Mode'),
                const Spacer(),
                Text('Total: ${total.toStringAsFixed(2)} L', style: Theme.of(context).textTheme.titleMedium),
              ]),
              const SizedBox(height: 16),
              if (_bulkMode)
                Row(children: [
                  SizedBox(width: narrow ? 160 : 260, child: TextField(controller: _bulkQtyController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Bulk Quantity (L)', border: OutlineInputBorder()))),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(onPressed: _savingAll ? null : _saveProduction, icon: _savingAll ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt), label: Text(_savingAll ? 'Saving...' : 'Save Bulk'))
                ])
              else ...[
                if (!narrow) _buildDataTableView(context) else _buildCardListView(context),
                const SizedBox(height: 12),
                Row(children: [
                  ElevatedButton.icon(onPressed: _savingAll ? null : _saveProduction, icon: _savingAll ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt), label: Text(_savingAll ? 'Saving...' : 'Save Production')),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(onPressed: () => _clearAllInputs(), icon: const Icon(Icons.clear), label: const Text('Clear inputs')),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(onPressed: _exportEntriesCsv, icon: const Icon(Icons.download), label: const Text('Copy CSV')),
                ])
              ]
            ]),
          ),
        );
      }),
    );
  }

  Widget _buildDataTableView(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: Scrollbar(
        controller: _verticalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _verticalController,
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 32),
              child: DataTable(
                columnSpacing: 16,
                dataRowMinHeight: 64,
                headingTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                columns: const [
                  DataColumn(label: Text('Tag / Name')),
                  DataColumn(label: Text('Quantity (L)')),
                  DataColumn(label: Text('Actions')),
                  DataColumn(label: Text('Status')),
                ],
                rows: _animals.map((a) {
                  final id = (a['id'] ?? '').toString();
                  final tag = (a['tag'] ?? '').toString();
                  final name = (a['name'] ?? '').toString();
                  final controller = _qtyControllers[id]!;
                  final statusText = _rowStatus[id] ?? '';
                  final saving = _savingRows[id] ?? false;

                  return DataRow(cells: [
                    DataCell(Text('$tag — $name')),
                    DataCell(SizedBox(
                        width: 160,
                        child: TextField(
                          controller: controller,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10), hintText: 'e.g. 3.2', border: OutlineInputBorder(), errorText: statusText.startsWith('error') ? 'Invalid' : null),
                        ))),
                    DataCell(Row(children: [
                      IconButton(onPressed: saving ? null : () => _saveSingleProduction(id), icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt)),
                      IconButton(onPressed: () { controller.clear(); setState(() => _rowStatus[id] = ''); }, icon: const Icon(Icons.clear)),
                    ])),
                    DataCell(Text(statusText == 'saved' ? 'Saved' : statusText.startsWith('error') ? 'Error' : '', style: TextStyle(color: statusText.startsWith('error') ? Colors.red : (statusText == 'saved' ? Colors.green : Colors.black87)))),
                  ]);
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardListView(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _animals.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        final a = _animals[i];
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        final controller = _qtyControllers[id]!;
        final statusText = _rowStatus[id] ?? '';
        final saving = _savingRows[id] ?? false;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: Text('$tag — $name')),
              SizedBox(width: 120, child: TextField(controller: controller, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(hintText: 'e.g. 3.2', border: OutlineInputBorder(), errorText: statusText.startsWith('error') ? 'Invalid' : null))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: saving ? null : () => _saveSingleProduction(id), child: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save')),
            ]),
          ),
        );
      },
    );
  }

  Widget _buildHistoryTab(BuildContext context) {
    if (_loadingHistory) return const Center(child: CircularProgressIndicator());
    if (_milkHistory.isEmpty) return _buildCardMessage(icon: Icons.history, message: 'No history available.');

    final Map<DateTime, double> dailyTotals = {};
    for (final entry in _milkHistory) {
      final dateStr = entry['date'] as String?;
      if (dateStr != null) {
        final date = DateTime.parse(dateStr);
        final qty = (entry['quantity'] as num?)?.toDouble() ?? 0.0;
        final key = DateTime(date.year, date.month, date.day);
        dailyTotals[key] = (dailyTotals[key] ?? 0) + qty;
      }
    }

    final sortedDates = dailyTotals.keys.toList()..sort((a, b) => a.compareTo(b));
    final maxPoints = 60;
    List<DateTime> chartDates = sortedDates;
    if (sortedDates.length > maxPoints) chartDates = sortedDates.sublist(sortedDates.length - maxPoints);

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < chartDates.length; i++) {
      final date = chartDates[i];
      final total = dailyTotals[date] ?? 0.0;
      barGroups.add(BarChartGroupData(x: i, barRods: [BarChartRodData(toY: total, color: Theme.of(context).colorScheme.primary)],));
    }

    final overallTotal = dailyTotals.values.fold<double>(0, (p, e) => p + e);
    final avg = dailyTotals.isEmpty ? 0.0 : overallTotal / dailyTotals.length;

    return RefreshIndicator(
      onRefresh: _fetchHistory,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              DropdownButton<String>(value: _historyFilter, items: _filterOptions.map((f) { String label = f.replaceAll('_', ' '); label = label[0].toUpperCase() + label.substring(1); return DropdownMenuItem(value: f, child: Text(label)); }).toList(), onChanged: (value) { if (value != null && mounted) setState(() { _historyFilter = value; }); _fetchHistory(); }),
              const SizedBox(width: 16),
              IconButton(onPressed: _fetchHistory, icon: const Icon(Icons.refresh), tooltip: 'Refresh History'),
              const Spacer(),
              Text('Total: ${overallTotal.toStringAsFixed(1)} L'),
              const SizedBox(width: 12),
              Text('Avg/day: ${avg.toStringAsFixed(2)} L'),
            ]),
            const SizedBox(height: 16),
            Text('Daily Milk Production Chart', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(height: 320, child: BarChart(BarChartData(barGroups: barGroups, titlesData: FlTitlesData(show: true,
              bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, getTitlesWidget: (double value, TitleMeta meta) {
                final index = value.toInt();
                if (index >= 0 && index < chartDates.length) {
                  return Padding(padding: const EdgeInsets.only(top: 8.0), child: Text(DateFormat('MM-dd').format(chartDates[index]), style: const TextStyle(fontSize: 10)));
                }
                return const SizedBox();
              })),
              leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: (double value, TitleMeta meta) { return Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 10)); })),
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)), rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false))), borderData: FlBorderData(show: false), gridData: const FlGridData(show: true, drawVerticalLine: false),
              barTouchData: BarTouchData(enabled: true, touchTooltipData: BarTouchTooltipData(getTooltipItem: (group, groupIndex, rod, rodIndex) {
                if (groupIndex >= 0 && groupIndex < chartDates.length) {
                  final date = DateFormat('MM-dd').format(chartDates[groupIndex]);
                  return BarTooltipItem('$date\n${rod.toY.toStringAsFixed(1)} L', const TextStyle(color: Colors.white));
                }
                return null;
              })),))),
            const SizedBox(height: 24),
            Text('Production History Table', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(elevation: 2, child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(columnSpacing: 12, columns: const [DataColumn(label: Text('Date')), DataColumn(label: Text('Animal')), DataColumn(label: Text('Quantity (L)')), DataColumn(label: Text('Actions'))], rows: _milkHistory.map((entry) {
              final id = (entry['id'] ?? '').toString();
              final date = entry['date']?.toString() ?? 'N/A';
              final animalId = (entry['animal_id'] ?? '').toString();
              final animalName = _animalNames[animalId] ?? (entry['animal_tag'] ?? entry['animal_name'] ?? 'Unknown').toString();
              final quantity = (entry['quantity'] ?? '').toString();
              return DataRow(cells: [DataCell(Text(date)), DataCell(Text(animalName)), DataCell(Text(quantity)), DataCell(Row(children: [IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit, size: 20), onPressed: () => _showEditEntrySheet(entry)), IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline, size: 20), onPressed: () => _confirmDeleteEntry(id)),]))]);
            }).toList()))),
          ]),
        ),
      ),
    );
  }

  Widget _buildCardMessage({required IconData icon, required String message, Color? color}) {
    return Card(elevation: 2, margin: const EdgeInsets.all(16), child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 48, color: color ?? Colors.black54), const SizedBox(height: 8), Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge)])));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Milk Production'),
          actions: [
            IconButton(onPressed: _fetchAnimals, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
            IconButton(onPressed: _exportHistoryCsv, icon: const Icon(Icons.download), tooltip: 'Copy history CSV'),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Add Production'), Tab(text: 'History & Chart')]),
        ),
        body: TabBarView(children: [_buildAddTab(context), _buildHistoryTab(context)]),
      ),
    );
  }

  @override
  void dispose() {
    _bulkQtyController.dispose();
    for (final c in _qtyControllers.values) c.dispose();
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }
}


*/










/*// milk_production_with_crud.dart
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart'; // Clipboard
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'api_service.dart';
import 'supabase_config.dart';

/// ApiService extension: update & delete milk entries via Supabase REST
extension ApiServiceMilkCrud on ApiService {
  Future<Map<String, dynamic>?> updateMilkEntry(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await http.patch(
        Uri.parse(url),
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Prefer': 'return=representation',
        },
        body: json.encode(payload),
      );
      debugPrint(
        'updateMilkEntry status: ${resp.statusCode} body: ${resp.body}',
      );
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final List data = json.decode(resp.body);
        if (data.isNotEmpty)
          return Map<String, dynamic>.from(data.first as Map);
      }
    } catch (e) {
      debugPrint('updateMilkEntry error: $e');
    }
    return null;
  }

  Future<bool> deleteMilkEntry(String id) async {
    final url = '$SUPABASE_URL/rest/v1/milk_production?id=eq.$id';
    try {
      final resp = await http.delete(
        Uri.parse(url),
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );
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

/// MilkProductionPage with add/edit/delete + bulk support
class MilkProductionPage extends StatefulWidget {
  final String token;
  const MilkProductionPage({super.key, required this.token});

  @override
  State<MilkProductionPage> createState() => _MilkProductionPageState();
}

class _MilkProductionPageState extends State<MilkProductionPage> {
  final List<Map<String, dynamic>> _animals = [];
  final List<Map<String, dynamic>> _milkHistory = [];
  final Map<String, String> _animalNames = {};

  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, String> _rowStatus =
      {}; // '', 'saving', 'saved', 'error: ...'
  final Map<String, bool> _savingRows = {};

  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  bool _loading = true;
  bool _loadingHistory = false;
  bool _savingAll = false;
  String? _error;
  late ApiService _apiService;

  DateTime _selectedDate = DateTime.now();
  String _selectedSession = 'morning';
  bool _bulkMode = false;
  final TextEditingController _bulkQtyController = TextEditingController();

  String _historyFilter = 'all';
  final List<String> _filterOptions = [
    'all',
    'last_week',
    'last_month',
    'last_year',
  ];

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAnimals();
  }

  Future<void> _fetchAnimals() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals.clear();
      _animalNames.clear();
      _qtyControllers.clear();
      _rowStatus.clear();
      _savingRows.clear();
    });

    try {
      final farmIds = await _api_service_getUserFarmIds();
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }

      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      for (final a in animals) {
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        if (id.isNotEmpty) {
          _animalNames[id] = '$tag — $name';
          _qtyControllers[id] = _qtyControllers[id] ?? TextEditingController();
          _savingRows[id] = false;
        }
        _animals.add(a);
      }

      setState(() {
        _loading = false;
      });

      // fetch history after animals loaded
      await _fetchHistory();
    } catch (e) {
      debugPrint('Error fetching animals: $e');
      setState(() {
        _error = 'Failed to load animals. Please check your connection.';
        _loading = false;
      });
    }
  }

  Future<List<String>> _api_service_getUserFarmIds() async {
    try {
      return await _apiService.getUserFarmIds();
    } catch (e) {
      debugPrint('getUserFarmIds error: $e');
      return [];
    }
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _loadingHistory = true;
      _milkHistory.clear();
    });

    try {
      DateTime? fromDate;
      DateTime toDate = DateTime.now();

      switch (_historyFilter) {
        case 'last_week':
          fromDate = toDate.subtract(const Duration(days: 7));
          break;
        case 'last_month':
          fromDate = toDate.subtract(const Duration(days: 30));
          break;
        case 'last_year':
          fromDate = toDate.subtract(const Duration(days: 365));
          break;
        default:
          fromDate = null;
      }

      final animalIds = _animals
          .map((a) => (a['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      final history = await _apiService.fetchMilkHistory(
        animalIds: animalIds,
        fromDate: fromDate,
        toDate: toDate,
      );

      if (!mounted) return;
      setState(() {
        _milkHistory.addAll(history);
        // populate animalNames from history if missing
        for (final e in _milkHistory) {
          final aid = (e['animal_id'] ?? '').toString();
          if (aid.isNotEmpty && !_animalNames.containsKey(aid)) {
            final tag = (e['animal_tag'] ?? '').toString();
            final name = (e['animal_name'] ?? '').toString();
            if (tag.isNotEmpty || name.isNotEmpty)
              _animalNames[aid] =
                  '${tag.isNotEmpty ? tag : ''}${tag.isNotEmpty && name.isNotEmpty ? ' — ' : ''}${name}';
          }
        }
        _loadingHistory = false;
      });
    } catch (e) {
      debugPrint('Error fetching history: $e');
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load history: $e')));
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _selectedDate && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  double _currentEntriesTotal() {
    double sum = 0.0;
    for (final id in _qtyControllers.keys) {
      final val = _qtyControllers[id]?.text.trim() ?? '';
      final num = double.tryParse(val.replaceAll(',', '.')) ?? 0.0;
      sum += num;
    }
    return sum;
  }

  Future<void> _saveSingleProduction(String animalId) async {
    final qtyStr = _qtyControllers[animalId]?.text.trim() ?? '';
    if (qtyStr.isEmpty) {
      setState(() => _rowStatus[animalId] = 'error: empty');
      return;
    }
    final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
    if (qty == null || qty <= 0) {
      setState(() => _rowStatus[animalId] = 'error: invalid');
      return;
    }
    final a = _animals.firstWhere(
      (e) => (e['id'] ?? '').toString() == animalId,
      orElse: () => {},
    );
    final farmId = (a['farm_id'] ?? '').toString();

    setState(() {
      _savingRows[animalId] = true;
      _rowStatus[animalId] = 'saving';
    });

    try {
      final result = await _apiService.saveMilkProduction(
        animalId: animalId,
        farmId: farmId,
        quantity: qty,
        session: _selectedSession,
        date: _selectedDate,
      );

      if (!mounted) return;

      final success = result['success'] == true;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = success
            ? 'saved'
            : 'error: ${result['statusCode']}';
      });

      if (!success) {
        final body = result['body'] ?? result['error'] ?? 'Unknown error';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Save failed: $body')));
        debugPrint('Save failed details: ${result}');
      } else {
        // if server returned a record, you can optionally use it:
        final created = result['data'] as Map<String, dynamic>?;
        if (created != null) {
          // e.g. add to _milkHistory immediately or use returned id
          // _milkHistory.insert(0, created);
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Saved')));
      }
    } catch (e) {
      debugPrint('saveSingleProduction error: $e');
      if (!mounted) return;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = 'error: network';
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Network error: $e')));
    }

    // refresh history for immediate feedback
    await _fetchHistory();
  }

  Future<void> _saveProduction() async {
    if (_bulkMode) {
      final qtyStr = _bulkQtyController.text.trim();
      if (qtyStr.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter quantity for bulk.')),
        );
        return;
      }
      final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
      if (qty == null || qty <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invalid quantity.')));
        return;
      }

      setState(() {
        _savingAll = true;
      });

      int successCount = 0;
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final farmId = (a['farm_id'] ?? '').toString();
        try {
          final success = await _apiService.saveMilkProduction(
            animalId: id,
            farmId: farmId,
            quantity: qty,
            session: _selectedSession,
            date: _selectedDate,
          );
          setState(() => _rowStatus[id] = success != null ? 'saved' : 'error');
          if (success != null) successCount++;
        } catch (e) {
          setState(() => _rowStatus[(a['id'] ?? '').toString()] = 'error');
          debugPrint('bulk save error for ${a['id']}: $e');
        }
      }

      setState(() {
        _savingAll = false;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            successCount == _animals.length
                ? 'Bulk save completed.'
                : 'Bulk save finished: $successCount/${_animals.length} saved.',
          ),
        ),
      );
    } else {
      // save only filled rows
      final entries = <String>[];
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final qtyStr = _qtyControllers[id]?.text.trim() ?? '';
        if (qtyStr.isNotEmpty) entries.add(id);
      }
      if (entries.isEmpty) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No entries to save.')));
        return;
      }

      setState(() => _savingAll = true);
      int successCount = 0;

      for (final id in entries) {
        await _saveSingleProduction(id);
        if (_rowStatus[id] == 'saved') successCount++;
      }

      setState(() => _savingAll = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            successCount == entries.length
                ? 'All saved.'
                : 'Saved $successCount/${entries.length} entries.',
          ),
        ),
      );
    }

    await _fetchHistory();
  }

  void _clearAllInputs() {
    for (final c in _qtyControllers.values) {
      c.clear();
    }
    setState(() {
      _rowStatus.clear();
    });
  }

  Future<void> _exportEntriesCsv() async {
    // builds CSV of current entries (animal_id,date,session,quantity)
    final rows = <List<String>>[];
    rows.add(['animal_id', 'date', 'session', 'quantity']);
    for (final id in _qtyControllers.keys) {
      final val = _qtyControllers[id]?.text.trim() ?? '';
      if (val.isEmpty) continue;
      rows.add([
        id,
        DateFormat('yyyy-MM-dd').format(_selectedDate),
        _selectedSession,
        val,
      ]);
    }
    if (rows.length <= 1) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No entries to export')));
      return;
    }
    final csv = rows
        .map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(','))
        .join('\n');

    await Clipboard.setData(ClipboardData(text: csv));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('CSV copied to clipboard')));
  }

  Future<void> _exportHistoryCsv() async {
    if (_milkHistory.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No history to export')));
      return;
    }
    final rows = <List<String>>[];
    rows.add(['date', 'session', 'animal_id', 'animal_name', 'quantity']);
    for (final e in _milkHistory) {
      final date = e['date']?.toString() ?? '';
      final session = e['session']?.toString() ?? '';
      final aid = e['animal_id']?.toString() ?? '';
      final aname = _animalNames[aid] ?? '';
      final q = e['quantity']?.toString() ?? '';
      rows.add([date, session, aid, aname, q]);
    }
    final csv = rows
        .map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(','))
        .join('\n');
    await Clipboard.setData(ClipboardData(text: csv));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('History CSV copied to clipboard')),
    );
  }

  // ===== History entry edit / delete helpers =====
  Future<void> _showEditEntrySheet(Map<String, dynamic> entry) async {
    final id = (entry['id'] ?? '').toString();
    final dateStr = (entry['date'] ?? '').toString();
    DateTime parsedDate;
    try {
      parsedDate = DateTime.parse(dateStr);
    } catch (_) {
      parsedDate = DateTime.now();
    }
    final qtyCtl = TextEditingController(
      text: (entry['quantity'] ?? '').toString(),
    );
    String session = (entry['session'] ?? 'morning').toString();

    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: MediaQuery.of(context).viewInsets,
        child: DraggableScrollableSheet(
          initialChildSize: 0.5,
          minChildSize: 0.3,
          maxChildSize: 0.95,
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
                          // date picker row
                          Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
                                    final picked = await showDatePicker(
                                      context: context,
                                      initialDate: parsedDate,
                                      firstDate: DateTime(2000),
                                      lastDate: DateTime.now(),
                                    );
                                    if (picked != null)
                                      setState(() => parsedDate = picked);
                                  },
                                  child: InputDecorator(
                                    decoration: const InputDecoration(
                                      labelText: 'Date',
                                      border: OutlineInputBorder(),
                                    ),
                                    child: Text(
                                      DateFormat(
                                        'yyyy-MM-dd',
                                      ).format(parsedDate),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: DropdownButtonFormField<String>(
                                  value: session,
                                  onChanged: (v) => session = v ?? session,
                                  items: ['morning', 'evening']
                                      .map(
                                        (s) => DropdownMenuItem(
                                          value: s,
                                          child: Text(
                                            s[0].toUpperCase() + s.substring(1),
                                          ),
                                        ),
                                      )
                                      .toList(),
                                  decoration: const InputDecoration(
                                    labelText: 'Session',
                                    border: OutlineInputBorder(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          TextFormField(
                            controller: qtyCtl,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Quantity (L)',
                              border: OutlineInputBorder(),
                            ),
                            validator: (v) {
                              final t = (v ?? '').trim();
                              if (t.isEmpty) return 'Required';
                              final n = double.tryParse(t.replaceAll(',', '.'));
                              if (n == null || n <= 0) return 'Invalid';
                              return null;
                            },
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
                                      qtyCtl.text.trim().replaceAll(',', '.'),
                                    );
                                    final payload = {
                                      'quantity': newQty,
                                      'date': DateFormat(
                                        'yyyy-MM-dd',
                                      ).format(parsedDate),
                                      'session': session,
                                    };
                                    Navigator.pop(context);
                                    final updated = await _apiService
                                        .updateMilkEntry(id, payload);
                                    if (updated != null) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text('Entry updated'),
                                        ),
                                      );
                                      await _fetchHistory();
                                    } else {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Failed to update entry',
                                          ),
                                        ),
                                      );
                                    }
                                  },
                                  child: const Text('Save changes'),
                                ),
                              ),
                              const SizedBox(width: 8),
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

    qtyCtl.dispose();
  }

  Future<void> _confirmDeleteEntry(String id) async {
    final c = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete milk entry'),
        content: const Text(
          'Are you sure you want to delete this milk record? This action cannot be undone.',
        ),
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
    if (c == true) {
      final ok = await _apiService.deleteMilkEntry(id);
      if (ok) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Entry deleted')));
        await _fetchHistory();
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to delete entry')));
      }
    }
  }

  Widget _buildAddTab(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null)
      return _buildCardMessage(
        icon: Icons.error_outline,
        message: _error!,
        color: Colors.red,
      );
    if (_animals.isEmpty)
      return _buildCardMessage(
        icon: Icons.pets,
        message: 'No animals available.',
      );

    final total = _currentEntriesTotal();

    return RefreshIndicator(
      onRefresh: _fetchAnimals,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final narrow = width < 700;

          return SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => _selectDate(context),
                        icon: const Icon(Icons.calendar_today),
                        label: Text(
                          DateFormat('yyyy-MM-dd').format(_selectedDate),
                        ),
                      ),
                      const SizedBox(width: 12),
                      DropdownButton<String>(
                        value: _selectedSession,
                        onChanged: (v) => setState(
                          () => _selectedSession = v ?? _selectedSession,
                        ),
                        items: ['morning', 'evening']
                            .map(
                              (s) => DropdownMenuItem(
                                value: s,
                                child: Text(
                                  s[0].toUpperCase() + s.substring(1),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                      const SizedBox(width: 12),
                      Checkbox(
                        value: _bulkMode,
                        onChanged: (v) =>
                            setState(() => _bulkMode = v ?? false),
                      ),
                      const Text('Bulk Mode'),
                      const Spacer(),
                      Text(
                        'Total: ${total.toStringAsFixed(2)} L',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  if (_bulkMode)
                    Row(
                      children: [
                        SizedBox(
                          width: narrow ? 160 : 260,
                          child: TextField(
                            controller: _bulkQtyController,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Bulk Quantity (L)',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _savingAll ? null : _saveProduction,
                          icon: _savingAll
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_alt),
                          label: Text(_savingAll ? 'Saving...' : 'Save Bulk'),
                        ),
                      ],
                    )
                  else ...[
                    if (!narrow)
                      _buildDataTableView(context)
                    else
                      _buildCardListView(context),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          onPressed: _savingAll ? null : _saveProduction,
                          icon: _savingAll
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.save_alt),
                          label: Text(
                            _savingAll ? 'Saving...' : 'Save Production',
                          ),
                        ),
                        const SizedBox(width: 12),
                        OutlinedButton.icon(
                          onPressed: () => _clearAllInputs(),
                          icon: const Icon(Icons.clear),
                          label: const Text('Clear inputs'),
                        ),
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _exportEntriesCsv,
                          icon: const Icon(Icons.download),
                          label: const Text('Copy CSV'),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDataTableView(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: Scrollbar(
        controller: _verticalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _verticalController,
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minWidth: MediaQuery.of(context).size.width - 32,
              ),
              child: DataTable(
                columnSpacing: 16,
                dataRowMinHeight: 64,
                headingTextStyle: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                columns: const [
                  DataColumn(label: Text('Tag / Name')),
                  DataColumn(label: Text('Quantity (L)')),
                  DataColumn(label: Text('Actions')),
                  DataColumn(label: Text('Status')),
                ],
                rows: _animals.map((a) {
                  final id = (a['id'] ?? '').toString();
                  final tag = (a['tag'] ?? '').toString();
                  final name = (a['name'] ?? '').toString();
                  final controller = _qtyControllers[id]!;
                  final statusText = _rowStatus[id] ?? '';
                  final saving = _savingRows[id] ?? false;

                  return DataRow(
                    cells: [
                      DataCell(Text('$tag — $name')),
                      DataCell(
                        SizedBox(
                          width: 160,
                          child: TextField(
                            controller: controller,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 12,
                                horizontal: 10,
                              ),
                              hintText: 'e.g. 3.2',
                              border: OutlineInputBorder(),
                              errorText: statusText.startsWith('error')
                                  ? 'Invalid'
                                  : null,
                            ),
                          ),
                        ),
                      ),
                      DataCell(
                        Row(
                          children: [
                            IconButton(
                              onPressed: saving
                                  ? null
                                  : () => _saveSingleProduction(id),
                              icon: saving
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.save_alt),
                            ),
                            IconButton(
                              onPressed: () {
                                controller.clear();
                                setState(() => _rowStatus[id] = '');
                              },
                              icon: const Icon(Icons.clear),
                            ),
                          ],
                        ),
                      ),
                      DataCell(
                        Text(
                          statusText == 'saved'
                              ? 'Saved'
                              : statusText.startsWith('error')
                              ? 'Error'
                              : '',
                          style: TextStyle(
                            color: statusText.startsWith('error')
                                ? Colors.red
                                : (statusText == 'saved'
                                      ? Colors.green
                                      : Colors.black87),
                          ),
                        ),
                      ),
                    ],
                  );
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardListView(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _animals.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        final a = _animals[i];
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        final controller = _qtyControllers[id]!;
        final statusText = _rowStatus[id] ?? '';
        final saving = _savingRows[id] ?? false;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(child: Text('$tag — $name')),
                SizedBox(
                  width: 120,
                  child: TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      hintText: 'e.g. 3.2',
                      border: OutlineInputBorder(),
                      errorText: statusText.startsWith('error')
                          ? 'Invalid'
                          : null,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: saving ? null : () => _saveSingleProduction(id),
                  child: saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHistoryTab(BuildContext context) {
    if (_loadingHistory)
      return const Center(child: CircularProgressIndicator());
    if (_milkHistory.isEmpty)
      return _buildCardMessage(
        icon: Icons.history,
        message: 'No history available.',
      );

    final Map<DateTime, double> dailyTotals = {};
    for (final entry in _milkHistory) {
      final dateStr = entry['date'] as String?;
      if (dateStr != null) {
        final date = DateTime.parse(dateStr);
        final qty = (entry['quantity'] as num?)?.toDouble() ?? 0.0;
        final key = DateTime(date.year, date.month, date.day);
        dailyTotals[key] = (dailyTotals[key] ?? 0) + qty;
      }
    }

    final sortedDates = dailyTotals.keys.toList()
      ..sort((a, b) => a.compareTo(b));

    // If too many days, limit chart to last 60 days for readability
    final maxPoints = 60;
    List<DateTime> chartDates = sortedDates;
    if (sortedDates.length > maxPoints)
      chartDates = sortedDates.sublist(sortedDates.length - maxPoints);

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < chartDates.length; i++) {
      final date = chartDates[i];
      final total = dailyTotals[date] ?? 0.0;
      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: total,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      );
    }

    final overallTotal = dailyTotals.values.fold<double>(0, (p, e) => p + e);
    final avg = dailyTotals.isEmpty ? 0.0 : overallTotal / dailyTotals.length;

    return RefreshIndicator(
      onRefresh: _fetchHistory,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
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
                      String label = f.replaceAll('_', ' ');
                      label = label[0].toUpperCase() + label.substring(1);
                      return DropdownMenuItem(value: f, child: Text(label));
                    }).toList(),
                    onChanged: (value) {
                      if (value != null && mounted)
                        setState(() {
                          _historyFilter = value;
                        });
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
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
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
                            final index = value.toInt();
                            if (index >= 0 && index < chartDates.length) {
                              return Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  DateFormat('MM-dd').format(chartDates[index]),
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
                          getTitlesWidget: (double value, TitleMeta meta) {
                            return Text(
                              value.toStringAsFixed(0),
                              style: const TextStyle(fontSize: 10),
                            );
                          },
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
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Card(
                elevation: 2,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 12,
                    columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Session')),
                      DataColumn(label: Text('Animal')),
                      DataColumn(label: Text('Quantity (L)')),
                      DataColumn(label: Text('Actions')),
                    ],
                    rows: _milkHistory.map((entry) {
                      final id = (entry['id'] ?? '').toString();
                      final date = entry['date']?.toString() ?? 'N/A';
                      final rawSession = (entry['session'] as String?) ?? 'N/A';
                      final session = rawSession == 'N/A'
                          ? rawSession
                          : '${rawSession[0].toUpperCase()}${rawSession.substring(1)}';
                      final animalId = (entry['animal_id'] ?? '').toString();
                      final animalName =
                          _animalNames[animalId] ??
                          (entry['animal_name'] ??
                                  entry['animal_tag'] ??
                                  'Unknown')
                              .toString();
                      final quantity = (entry['quantity'] ?? '').toString();
                      return DataRow(
                        cells: [
                          DataCell(Text(date)),
                          DataCell(Text(session)),
                          DataCell(Text(animalName)),
                          DataCell(Text(quantity)),
                          DataCell(
                            Row(
                              children: [
                                IconButton(
                                  tooltip: 'Edit',
                                  icon: const Icon(Icons.edit, size: 20),
                                  onPressed: () => _showEditEntrySheet(entry),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCardMessage({
    required IconData icon,
    required String message,
    Color? color,
  }) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color ?? Colors.black54),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Milk Production'),
          actions: [
            IconButton(
              onPressed: _fetchAnimals,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
            IconButton(
              onPressed: _exportHistoryCsv,
              icon: const Icon(Icons.download),
              tooltip: 'Copy history CSV',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Add Production'),
              Tab(text: 'History & Chart'),
            ],
          ),
        ),
        body: TabBarView(
          children: [_buildAddTab(context), _buildHistoryTab(context)],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _bulkQtyController.dispose();
    for (final c in _qtyControllers.values) c.dispose();
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }
}
*/















/*99import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:flutter/services.dart'; // for Clipboard
import 'api_service.dart';

class MilkProductionPage extends StatefulWidget {
  final String token;
  const MilkProductionPage({super.key, required this.token});

  @override
  State<MilkProductionPage> createState() => _MilkProductionPageState();
}

class _MilkProductionPageState extends State<MilkProductionPage> {
  final List<Map<String, dynamic>> _animals = [];
  final List<Map<String, dynamic>> _milkHistory = [];
  final Map<String, String> _animalNames = {};

  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, String> _rowStatus = {}; // '', 'saving', 'saved', 'error: ...'
  final Map<String, bool> _savingRows = {};

  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  bool _loading = true;
  bool _loadingHistory = false;
  bool _savingAll = false;
  String? _error;
  late ApiService _apiService;

  DateTime _selectedDate = DateTime.now();
  String _selectedSession = 'morning';
  bool _bulkMode = false;
  final TextEditingController _bulkQtyController = TextEditingController();

  String _historyFilter = 'all';
  final List<String> _filterOptions = [
    'all',
    'last_week',
    'last_month',
    'last_year',
  ];

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAnimals();
  }

  Future<void> _fetchAnimals() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals.clear();
      _animalNames.clear();
      _qtyControllers.clear();
      _rowStatus.clear();
      _savingRows.clear();
    });

    try {
      final farmIds = await _api_service_getUserFarmIds();
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }

      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      for (final a in animals) {
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        if (id.isNotEmpty) {
          _animalNames[id] = '$tag — $name';
          _qtyControllers[id] = _qtyControllers[id] ?? TextEditingController();
          _savingRows[id] = false;
        }
        _animals.add(a);
      }

      setState(() {
        _loading = false;
      });

      // fetch history after animals loaded
      await _fetchHistory();
    } catch (e) {
      debugPrint('Error fetching animals: $e');
      setState(() {
        _error = 'Failed to load animals. Please check your connection.';
        _loading = false;
      });
    }
  }

  Future<List<String>> _api_service_getUserFarmIds() async {
    try {
      return await _apiService.getUserFarmIds();
    } catch (e) {
      debugPrint('getUserFarmIds error: $e');
      return [];
    }
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _loadingHistory = true;
      _milkHistory.clear();
    });

    try {
      DateTime? fromDate;
      DateTime toDate = DateTime.now();

      switch (_historyFilter) {
        case 'last_week':
          fromDate = toDate.subtract(const Duration(days: 7));
          break;
        case 'last_month':
          fromDate = toDate.subtract(const Duration(days: 30));
          break;
        case 'last_year':
          fromDate = toDate.subtract(const Duration(days: 365));
          break;
        default:
          fromDate = null;
      }

      final animalIds = _animals.map((a) => (a['id'] ?? '').toString()).where((id) => id.isNotEmpty).toList();
      final history = await _apiService.fetchMilkHistory(animalIds: animalIds, fromDate: fromDate, toDate: toDate);

      if (!mounted) return;
      setState(() {
        _milkHistory.addAll(history);
        _loadingHistory = false;
      });
    } catch (e) {
      debugPrint('Error fetching history: $e');
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Failed to load history: $e')));
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _selectedDate && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  double _currentEntriesTotal() {
    double sum = 0.0;
    for (final id in _qtyControllers.keys) {
      final val = _qtyControllers[id]?.text.trim() ?? '';
      final num = double.tryParse(val.replaceAll(',', '.')) ?? 0.0;
      sum += num;
    }
    return sum;
  }

  Future<void> _saveSingleProduction(String animalId) async {
    final qtyStr = _qtyControllers[animalId]?.text.trim() ?? '';
    if (qtyStr.isEmpty) {
      setState(() => _rowStatus[animalId] = 'error: empty');
      return;
    }
    final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
    if (qty == null || qty <= 0) {
      setState(() => _rowStatus[animalId] = 'error: invalid');
      return;
    }
    final a = _animals.firstWhere((e) => (e['id'] ?? '').toString() == animalId, orElse: () => {});
    final farmId = (a['farm_id'] ?? '').toString();

    setState(() {
      _savingRows[animalId] = true;
      _rowStatus[animalId] = 'saving';
    });

    try {
      final success = await _apiService.saveMilkProduction(animalId: animalId, farmId: farmId, quantity: qty, session: _selectedSession, date: _selectedDate);
      if (!mounted) return;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = success ? 'saved' : 'error: failed';
      });
    } catch (e) {
      debugPrint('saveSingleProduction error: $e');
      if (!mounted) return;
      setState(() {
        _savingRows[animalId] = false;
        _rowStatus[animalId] = 'error: $e';
      });
    }

    // refresh history for immediate feedback
    await _fetchHistory();
  }

  Future<void> _saveProduction() async {
    if (_bulkMode) {
      final qtyStr = _bulkQtyController.text.trim();
      if (qtyStr.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please enter quantity for bulk.')));
        return;
      }
      final qty = double.tryParse(qtyStr.replaceAll(',', '.'));
      if (qty == null || qty <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Invalid quantity.')));
        return;
      }

      setState(() {
        _savingAll = true;
      });

      int successCount = 0;
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final farmId = (a['farm_id'] ?? '').toString();
        try {
          final success = await _apiService.saveMilkProduction(animalId: id, farmId: farmId, quantity: qty, session: _selectedSession, date: _selectedDate);
          setState(() => _rowStatus[id] = success ? 'saved' : 'error');
          if (success) successCount++;
        } catch (e) {
          setState(() => _rowStatus[id] = 'error');
          debugPrint('bulk save error for $id: $e');
        }
      }

      setState(() {
        _savingAll = false;
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successCount == _animals.length ? 'Bulk save completed.' : 'Bulk save finished: $successCount/${_animals.length} saved.')));
    } else {
      // save only filled rows and run concurrently with a small limit
      final entries = <String>[];
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final qtyStr = _qtyControllers[id]?.text.trim() ?? '';
        if (qtyStr.isNotEmpty) entries.add(id);
      }
      if (entries.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No entries to save.')));
        return;
      }

      setState(() => _savingAll = true);
      int successCount = 0;

      // perform in sequence to avoid overloading API; can be changed to Future.wait for speed
      for (final id in entries) {
        await _saveSingleProduction(id);
        if (_rowStatus[id] == 'saved') successCount++;
      }

      setState(() => _savingAll = false);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(successCount == entries.length ? 'All saved.' : 'Saved $successCount/${entries.length} entries.')));
    }

    await _fetchHistory();
  }

  Widget _buildAddTab(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return _buildCardMessage(icon: Icons.error_outline, message: _error!, color: Colors.red);
    if (_animals.isEmpty) return _buildCardMessage(icon: Icons.pets, message: 'No animals available.');

    final total = _currentEntriesTotal();

    return RefreshIndicator(
      onRefresh: _fetchAnimals,
      child: LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        final narrow = width < 700;

        return SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                ElevatedButton.icon(onPressed: () => _selectDate(context), icon: const Icon(Icons.calendar_today), label: Text(DateFormat('yyyy-MM-dd').format(_selectedDate))),
                const SizedBox(width: 12),
                DropdownButton<String>(value: _selectedSession, onChanged: (v) => setState(() => _selectedSession = v ?? _selectedSession), items: ['morning', 'evening'].map((s) => DropdownMenuItem(value: s, child: Text(s[0].toUpperCase() + s.substring(1)))).toList()),
                const SizedBox(width: 12),
                Checkbox(value: _bulkMode, onChanged: (v) => setState(() => _bulkMode = v ?? false)),
                const Text('Bulk Mode'),
                const Spacer(),
                Text('Total: ${total.toStringAsFixed(2)} L', style: Theme.of(context).textTheme.titleMedium),
              ]),
              const SizedBox(height: 16),
              if (_bulkMode)
                Row(children: [
                  SizedBox(width: narrow ? 160 : 260, child: TextField(controller: _bulkQtyController, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Bulk Quantity (L)', border: OutlineInputBorder()),)),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(onPressed: _savingAll ? null : _saveProduction, icon: _savingAll ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt), label: Text(_savingAll ? 'Saving...' : 'Save Bulk'))
                ])
              else ...[
                // Responsive: show DataTable on wide, cards on narrow
                if (!narrow) _buildDataTableView(context) else _buildCardListView(context),
                const SizedBox(height: 12),
                Row(children: [
                  ElevatedButton.icon(onPressed: _savingAll ? null : _saveProduction, icon: _savingAll ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt), label: Text(_savingAll ? 'Saving...' : 'Save Production')),
                  const SizedBox(width: 12),
                  OutlinedButton.icon(onPressed: () => _clearAllInputs(), icon: const Icon(Icons.clear), label: const Text('Clear inputs')),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(onPressed: _exportEntriesCsv, icon: const Icon(Icons.download), label: const Text('Copy CSV')),
                ])
              ]
            ]),
          ),
        );
      }),
    );
  }

  Widget _buildDataTableView(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: Scrollbar(
        controller: _verticalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _verticalController,
          scrollDirection: Axis.vertical,
          child: SingleChildScrollView(
            controller: _horizontalController,
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: MediaQuery.of(context).size.width - 32),
              child: DataTable(
                columnSpacing: 16,
                dataRowMinHeight: 64,
                headingTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                columns: const [
                  DataColumn(label: Text('Tag / Name')),
                  DataColumn(label: Text('Quantity (L)')),
                  DataColumn(label: Text('Actions')),
                  DataColumn(label: Text('Status')),
                ],
                rows: _animals.map((a) {
                  final id = (a['id'] ?? '').toString();
                  final tag = (a['tag'] ?? '').toString();
                  final name = (a['name'] ?? '').toString();
                  final controller = _qtyControllers[id]!;
                  final statusText = _rowStatus[id] ?? '';
                  final saving = _savingRows[id] ?? false;

                  return DataRow(cells: [
                    DataCell(Text('$tag — $name')),
                    DataCell(SizedBox(width: 160, child: TextField(controller: controller, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(isDense: true, contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10), hintText: 'e.g. 3.2', border: OutlineInputBorder(), errorText: statusText.startsWith('error') ? 'Invalid' : null)))),
                    DataCell(Row(children: [
                      IconButton(onPressed: saving ? null : () => _saveSingleProduction(id), icon: saving ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.save_alt)),
                      IconButton(onPressed: () { controller.clear(); setState(() => _rowStatus[id] = ''); }, icon: const Icon(Icons.clear)),
                    ])),
                    DataCell(Text(statusText == 'saved' ? 'Saved' : statusText.startsWith('error') ? 'Error' : '', style: TextStyle(color: statusText.startsWith('error') ? Colors.red : (statusText == 'saved' ? Colors.green : Colors.black87)))),
                  ]);
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCardListView(BuildContext context) {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: _animals.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (c, i) {
        final a = _animals[i];
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        final controller = _qtyControllers[id]!;
        final statusText = _rowStatus[id] ?? '';
        final saving = _savingRows[id] ?? false;

        return Card(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(child: Text('$tag — $name')),
              SizedBox(width: 120, child: TextField(controller: controller, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(hintText: 'e.g. 3.2', border: OutlineInputBorder(), errorText: statusText.startsWith('error') ? 'Invalid' : null),)),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: saving ? null : () => _saveSingleProduction(id), child: saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Save')),
            ]),
          ),
        );
      },
    );
  }

  void _clearAllInputs() {
    for (final c in _qtyControllers.values) {
      c.clear();
    }
    setState(() {
      _rowStatus.clear();
    });
  }

  Future<void> _exportEntriesCsv() async {
    // builds CSV of current entries (animal_id,date,session,quantity)
    final rows = <List<String>>[];
    rows.add(['animal_id', 'date', 'session', 'quantity']);
    for (final id in _qtyControllers.keys) {
      final val = _qtyControllers[id]?.text.trim() ?? '';
      if (val.isEmpty) continue;
      rows.add([id, DateFormat('yyyy-MM-dd').format(_selectedDate), _selectedSession, val]);
    }
    if (rows.length <= 1) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No entries to export')));
      return;
    }
    final csv = rows.map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(',')).join('\n');

    await Clipboard.setData(ClipboardData(text: csv));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('CSV copied to clipboard')));
  }

  Widget _buildHistoryTab(BuildContext context) {
    if (_loadingHistory) return const Center(child: CircularProgressIndicator());
    if (_milkHistory.isEmpty) return _buildCardMessage(icon: Icons.history, message: 'No history available.');

    final Map<DateTime, double> dailyTotals = {};
    for (final entry in _milkHistory) {
      final dateStr = entry['date'] as String?;
      if (dateStr != null) {
        final date = DateTime.parse(dateStr);
        final qty = (entry['quantity'] as num?)?.toDouble() ?? 0.0;
        final key = DateTime(date.year, date.month, date.day);
        dailyTotals[key] = (dailyTotals[key] ?? 0) + qty;
      }
    }

    final sortedDates = dailyTotals.keys.toList()..sort((a, b) => a.compareTo(b));

    // If too many days, limit chart to last 60 days for readability
    final maxPoints = 60;
    List<DateTime> chartDates = sortedDates;
    if (sortedDates.length > maxPoints) chartDates = sortedDates.sublist(sortedDates.length - maxPoints);

    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < chartDates.length; i++) {
      final date = chartDates[i];
      final total = dailyTotals[date] ?? 0.0;
      barGroups.add(BarChartGroupData(x: i, barRods: [BarChartRodData(toY: total, color: Theme.of(context).colorScheme.primary)],));
    }

    final overallTotal = dailyTotals.values.fold<double>(0, (p, e) => p + e);
    final avg = dailyTotals.isEmpty ? 0.0 : overallTotal / dailyTotals.length;

    return RefreshIndicator(
      onRefresh: _fetchHistory,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              DropdownButton<String>(value: _historyFilter, items: _filterOptions.map((f) { String label = f.replaceAll('_', ' '); label = label[0].toUpperCase() + label.substring(1); return DropdownMenuItem(value: f, child: Text(label)); }).toList(), onChanged: (value) { if (value != null && mounted) setState(() { _historyFilter = value; }); _fetchHistory(); }),
              const SizedBox(width: 16),
              IconButton(onPressed: _fetchHistory, icon: const Icon(Icons.refresh), tooltip: 'Refresh History'),
              const Spacer(),
              Text('Total: ${overallTotal.toStringAsFixed(1)} L'),
              const SizedBox(width: 12),
              Text('Avg/day: ${avg.toStringAsFixed(2)} L'),
            ]),
            const SizedBox(height: 16),
            Text('Daily Milk Production Chart', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SizedBox(
              height: 320,
              child: BarChart(
                BarChartData(
                  barGroups: barGroups,
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 32, getTitlesWidget: (double value, TitleMeta meta) { final index = value.toInt(); if (index >= 0 && index < chartDates.length) { return Padding(padding: const EdgeInsets.only(top: 8.0), child: Text(DateFormat('MM-dd').format(chartDates[index]), style: const TextStyle(fontSize: 10))); } return const SizedBox(); })),
                    leftTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 40, getTitlesWidget: (double value, TitleMeta meta) { return Text(value.toStringAsFixed(0), style: const TextStyle(fontSize: 10)); })),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                  ),
                  borderData: FlBorderData(show: false),
                  gridData: const FlGridData(show: true, drawVerticalLine: false),
                  barTouchData: BarTouchData(enabled: true, touchTooltipData: BarTouchTooltipData(getTooltipItem: (group, groupIndex, rod, rodIndex) { if (groupIndex >= 0 && groupIndex < chartDates.length) { final date = DateFormat('MM-dd').format(chartDates[groupIndex]); return BarTooltipItem('$date\n${rod.toY.toStringAsFixed(1)} L', const TextStyle(color: Colors.white)); } return null; })),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text('Production History Table', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Card(elevation: 2, child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(columnSpacing: 16, columns: const [DataColumn(label: Text('Date')), DataColumn(label: Text('Session')), DataColumn(label: Text('Animal')), DataColumn(label: Text('Quantity (L)'))], rows: _milkHistory.map((entry) { final date = entry['date'] as String? ?? 'N/A'; final rawSession = (entry['session'] as String? ?? 'N/A'); final session = rawSession == 'N/A' ? rawSession : '${rawSession[0].toUpperCase()}${rawSession.substring(1)}'; final animalId = (entry['animal_id'] ?? '').toString(); final animalName = _animalNames[animalId] ?? 'Unknown'; final quantity = entry['quantity']?.toString() ?? '0'; return DataRow(cells: [DataCell(Text(date)), DataCell(Text(session)), DataCell(Text(animalName)), DataCell(Text(quantity))]); }).toList()))),
          ]),
        ),
      ),
    );
  }

  Widget _buildCardMessage({required IconData icon, required String message, Color? color}) {
    return Card(elevation: 2, margin: const EdgeInsets.all(16), child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 48, color: color ?? Colors.black54), const SizedBox(height: 8), Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge)])));
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Milk Production'),
          actions: [
            IconButton(onPressed: _fetchAnimals, icon: const Icon(Icons.refresh), tooltip: 'Refresh'),
            IconButton(onPressed: _exportHistoryCsv, icon: const Icon(Icons.download), tooltip: 'Copy history CSV'),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Add Production'), Tab(text: 'History & Chart')]),
        ),
        body: TabBarView(children: [_buildAddTab(context), _buildHistoryTab(context)]),
      ),
    );
  }

  Future<void> _exportHistoryCsv() async {
    if (_milkHistory.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No history to export')));
      return;
    }
    final rows = <List<String>>[];
    rows.add(['date', 'session', 'animal_id', 'animal_name', 'quantity']);
    for (final e in _milkHistory) {
      final date = e['date']?.toString() ?? '';
      final session = e['session']?.toString() ?? '';
      final aid = e['animal_id']?.toString() ?? '';
      final aname = _animalNames[aid] ?? '';
      final q = e['quantity']?.toString() ?? '';
      rows.add([date, session, aid, aname, q]);
    }
    final csv = rows.map((r) => r.map((c) => '"${c.replaceAll('"', '""')}"').join(',')).join('\n');
    await Clipboard.setData(ClipboardData(text: csv));
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('History CSV copied to clipboard')));
  }

  @override
  void dispose() {
    _bulkQtyController.dispose();
    for (final c in _qtyControllers.values) c.dispose();
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }
}
*/













/*import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'api_service.dart';

class MilkProductionPage extends StatefulWidget {
  final String token;
  const MilkProductionPage({super.key, required this.token});

  @override
  State<MilkProductionPage> createState() => _MilkProductionPageState();
}

class _MilkProductionPageState extends State<MilkProductionPage> {
  List<Map<String, dynamic>> _animals = [];
  List<Map<String, dynamic>> _milkHistory = [];
  Map<String, String> _animalNames = {};
  // removed unused _farmIds field
  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, String> _rowStatus = {};

  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  bool _loading = true;
  bool _loadingHistory = false;
  String? _error;
  late ApiService _apiService;

  DateTime _selectedDate = DateTime.now();
  String _selectedSession = 'morning';
  bool _bulkMode = false;
  final TextEditingController _bulkQtyController = TextEditingController();

  // make this non-final so you can set it in the UI
  String _historyFilter = 'all';
  final List<String> _filterOptions = [
    'all',
    'last_week',
    'last_month',
    'last_year',
  ];

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAnimals();
  }

  Future<void> _fetchAnimals() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals = [];
      _animalNames = {};
    });

    try {
      final farmIds = await _apiService.getUserFarmIds();
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }
      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      final animalNames = <String, String>{};
      for (final a in animals) {
        final id = (a['id'] ?? '').toString();
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        if (id.isNotEmpty) {
          animalNames[id] = '$tag — $name';
          _qtyControllers[id] ??= TextEditingController();
        }
      }

      setState(() {
        _animals = animals;
        _animalNames = animalNames;
        _loading = false;
      });
      _fetchHistory();
    } catch (e) {
      debugPrint('Error fetching animals: $e');
      setState(() {
        _error = 'Failed to load animals. Please check your connection.';
        _loading = false;
      });
    }
  }

  Future<void> _fetchHistory() async {
    setState(() {
      _loadingHistory = true;
      _milkHistory = [];
    });

    try {
      DateTime? fromDate;
      DateTime toDate = DateTime.now();

      switch (_historyFilter) {
        case 'last_week':
          fromDate = toDate.subtract(const Duration(days: 7));
          break;
        case 'last_month':
          fromDate = toDate.subtract(const Duration(days: 30));
          break;
        case 'last_year':
          fromDate = toDate.subtract(const Duration(days: 365));
          break;
        default:
          fromDate = null;
      }

      final animalIds = _animals
          .map((a) => (a['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList();
      final history = await _apiService.fetchMilkHistory(
        animalIds: animalIds,
        fromDate: fromDate,
        toDate: toDate,
      );

      if (!mounted) return;
      setState(() {
        _milkHistory = history;
        _loadingHistory = false;
      });
    } catch (e) {
      debugPrint('Error fetching history: $e');
      if (!mounted) return;
      setState(() {
        _loadingHistory = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to load history: $e')));
    }
  }

  Future<void> _selectDate(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && picked != _selectedDate && mounted) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  Future<void> _saveProduction() async {
    if (_bulkMode) {
      final qtyStr = _bulkQtyController.text.trim();
      if (qtyStr.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter quantity for bulk.')),
        );
        return;
      }
      final qty = double.tryParse(qtyStr);
      if (qty == null || qty <= 0) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Invalid quantity.')));
        return;
      }
      bool hasError = false;
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final farmId = (a['farm_id'] ?? '').toString();
        final success = await _apiService.saveMilkProduction(
          animalId: id,
          farmId: farmId,
          quantity: qty,
          session: _selectedSession,
          date: _selectedDate,
        );
        if (!mounted) return;
        setState(() {
          _rowStatus[id] = success ? 'saved' : 'error';
        });
        if (!success) hasError = true;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hasError ? 'Bulk save had errors.' : 'Bulk save completed.',
          ),
        ),
      );
    } else {
      bool hasError = false;
      for (final a in _animals) {
        final id = (a['id'] ?? '').toString();
        final qtyStr = _qtyControllers[id]?.text.trim() ?? '';
        if (qtyStr.isEmpty) continue;
        final qty = double.tryParse(qtyStr);
        if (qty == null || qty <= 0) {
          if (!mounted) return;
          setState(() => _rowStatus[id] = 'error: invalid');
          hasError = true;
          continue;
        }
        final farmId = (a['farm_id'] ?? '').toString();
        final success = await _apiService.saveMilkProduction(
          animalId: id,
          farmId: farmId,
          quantity: qty,
          session: _selectedSession,
          date: _selectedDate,
        );
        if (!mounted) return;
        setState(() {
          _rowStatus[id] = success ? 'saved' : 'error';
        });
        if (!success) hasError = true;
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            hasError ? 'Save had errors.' : 'All saved successfully.',
          ),
        ),
      );
    }
    _fetchHistory();
  }

  Widget _buildAddTab() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Card(
        elevation: 2,
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyLarge,
              ),
            ],
          ),
        ),
      );
    }
    if (_animals.isEmpty) {
      return Card(
        elevation: 2,
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No animals available.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchAnimals,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: () => _selectDate(context),
                    icon: const Icon(Icons.calendar_today),
                    label: Text(DateFormat('yyyy-MM-dd').format(_selectedDate)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  DropdownButton<String>(
                    value: _selectedSession,
                    onChanged: (value) =>
                        setState(() => _selectedSession = value!),
                    items: ['morning', 'evening']
                        .map(
                          (s) => DropdownMenuItem(
                            value: s,
                            child: Text(s[0].toUpperCase() + s.substring(1)),
                          ),
                        )
                        .toList(),
                  ),
                  const SizedBox(width: 16),
                  Checkbox(
                    value: _bulkMode,
                    onChanged: (value) => setState(() {
                      _bulkMode = value!;
                      if (!value) _bulkQtyController.clear();
                    }),
                  ),
                  const Text('Bulk Mode'),
                ],
              ),
              const SizedBox(height: 16),
              if (_bulkMode)
                SizedBox(
                  width: 200,
                  child: TextField(
                    controller: _bulkQtyController,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Bulk Quantity (L)',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      isDense: true,
                    ),
                  ),
                )
              else
                _buildTable(),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _saveProduction,
                icon: const Icon(Icons.save_alt),
                label: const Text('Save Production'),
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTable() {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: Scrollbar(
        controller: _verticalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _verticalController,
          scrollDirection: Axis.vertical,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                controller: _horizontalController,
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: DataTable(
                    columnSpacing: 16,
                    dataRowMinHeight: 60,
                    headingTextStyle: Theme.of(context).textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                    columns: const [
                      DataColumn(label: Text('Tag / Name')),
                      DataColumn(label: Text('Quantity (L)')),
                      DataColumn(label: Text('Status')),
                    ],
                    rows: _animals.map((a) {
                      final id = (a['id'] ?? '').toString();
                      final tag = (a['tag'] ?? '').toString();
                      final name = (a['name'] ?? '').toString();
                      _qtyControllers[id] ??= TextEditingController();
                      final controller = _qtyControllers[id]!;
                      final statusText = _rowStatus[id] ?? '';

                      return DataRow(
                        cells: [
                          DataCell(Text('$tag — $name')),
                          DataCell(
                            SizedBox(
                              width: 120,
                              child: TextField(
                                controller: controller,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                      decimal: true,
                                    ),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                    horizontal: 10,
                                  ),
                                  hintText: 'e.g. 3.2',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  errorText: statusText.startsWith('error')
                                      ? 'Invalid'
                                      : null,
                                ),
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              statusText == 'saved'
                                  ? 'Saved'
                                  : statusText.startsWith('error')
                                  ? 'Error'
                                  : '',
                              style: TextStyle(
                                color: statusText.startsWith('error')
                                    ? Colors.red
                                    : (statusText == 'saved'
                                          ? Colors.green
                                          : Colors.black87),
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryTab() {
    if (_loadingHistory) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_milkHistory.isEmpty) {
      return Card(
        elevation: 2,
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No history available.',
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      );
    }

    final Map<DateTime, double> dailyTotals = {};
    for (final entry in _milkHistory) {
      final dateStr = entry['date'] as String?;
      if (dateStr != null) {
        final date = DateTime.parse(dateStr);
        final qty = (entry['quantity'] as num?)?.toDouble() ?? 0.0;
        final key = DateTime(date.year, date.month, date.day);
        dailyTotals[key] = (dailyTotals[key] ?? 0) + qty;
      }
    }

    final sortedDates = dailyTotals.keys.toList()
      ..sort((a, b) => a.compareTo(b));
    final barGroups = <BarChartGroupData>[];
    for (int i = 0; i < sortedDates.length; i++) {
      final date = sortedDates[i];
      final total = dailyTotals[date] ?? 0.0;
      barGroups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: total,
              color: Theme.of(context).colorScheme.primary,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _fetchHistory,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
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
                      String label = f.replaceAll('_', ' ');
                      label = label[0].toUpperCase() + label.substring(1);
                      return DropdownMenuItem(value: f, child: Text(label));
                    }).toList(),
                    onChanged: (value) {
                      if (value != null && mounted) {
                        setState(() => _historyFilter = value);
                        _fetchHistory();
                      }
                    },
                  ),
                  const SizedBox(width: 16),
                  IconButton(
                    onPressed: _fetchHistory,
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Refresh History',
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                'Daily Milk Production Chart',
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 300,
                child: BarChart(
                  BarChartData(
                    barGroups: barGroups,
                    titlesData: FlTitlesData(
                      show: true,
                      bottomTitles: AxisTitles(
                        sideTitles: SideTitles(
                          showTitles: true,
                          reservedSize: 32,
                          // explicit parameter types and avoid SideTitleWidget to prevent api mismatch
                          getTitlesWidget: (double value, TitleMeta meta) {
                            final index = value.toInt();
                            if (index >= 0 && index < sortedDates.length) {
                              return Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  DateFormat(
                                    'MM-dd',
                                  ).format(sortedDates[index]),
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
                          getTitlesWidget: (double value, TitleMeta meta) {
                            return Text(
                              value.toStringAsFixed(0),
                              style: const TextStyle(fontSize: 10),
                            );
                          },
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
                              groupIndex < sortedDates.length) {
                            final date = DateFormat(
                              'MM-dd',
                            ).format(sortedDates[groupIndex]);
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
                style: Theme.of(
                  context,
                ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Card(
                elevation: 2,
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    columnSpacing: 16,
                    columns: const [
                      DataColumn(label: Text('Date')),
                      DataColumn(label: Text('Session')),
                      DataColumn(label: Text('Animal')),
                      DataColumn(label: Text('Quantity (L)')),
                    ],
                    rows: _milkHistory.map((entry) {
                      final date = entry['date'] as String? ?? 'N/A';
                      final rawSession = (entry['session'] as String? ?? 'N/A');
                      final session = rawSession == 'N/A'
                          ? rawSession
                          : '${rawSession[0].toUpperCase()}${rawSession.substring(1)}';
                      final animalId = (entry['animal_id'] ?? '').toString();
                      final animalName = _animalNames[animalId] ?? 'Unknown';
                      final quantity = entry['quantity']?.toString() ?? '0';
                      return DataRow(
                        cells: [
                          DataCell(Text(date)),
                          DataCell(Text(session)),
                          DataCell(Text(animalName)),
                          DataCell(Text(quantity)),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Milk Production'),
          actions: [
            IconButton(
              onPressed: _fetchAnimals,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Add Production'),
              Tab(text: 'History & Chart'),
            ],
          ),
        ),
        body: TabBarView(children: [_buildAddTab(), _buildHistoryTab()]),
      ),
    );
  }

  @override
  void dispose() {
    _bulkQtyController.dispose();
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }
}
*/




















/*import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:flutter/foundation.dart' show debugPrint;
import 'supabase_config.dart';

class MilkProductionPage extends StatefulWidget {
  final String token;
  const MilkProductionPage({super.key, required this.token});

  @override
  State<MilkProductionPage> createState() => _MilkProductionPageState();
}

class _MilkProductionPageState extends State<MilkProductionPage> {
  List<Map<String, dynamic>> _animals = [];
  List<String> _farmIds = [];
  final Map<String, TextEditingController> _qtyControllers = {};
  final Map<String, String> _rowStatus = {};

  final ScrollController _horizontalController = ScrollController();
  final ScrollController _verticalController = ScrollController();

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetchAnimals();
  }

  Future<void> _fetchAnimals() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals = [];
      _farmIds = [];
    });

    try {
      final farmIds = await _getUserFarmIdsFromToken();
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }
      final animals = await _fetchAnimalsForFarms(farmIds: farmIds);

      setState(() {
        _farmIds = farmIds;
        _animals = animals;
        for (final a in _animals) {
          final id = (a['id'] ?? '').toString();
          if (id.isNotEmpty) {
            _qtyControllers[id] ??= TextEditingController();
          }
        }
        _loading = false;
      });
    } catch (e) {
      debugPrint('Error fetching animals: $e');
      setState(() {
        _error = 'Failed to load animals. Please check your connection.';
        _loading = false;
      });
    }
  }

  Future<List<String>> _getUserFarmIdsFromToken() async {
    final telegramId = _getTelegramIdFromToken();
    if (telegramId.isEmpty) throw Exception('Invalid token: no telegram_id');
    final userId = await _fetchUserIdForTelegram(telegramId: telegramId);
    if (userId == null || userId.isEmpty) {
      throw Exception('No app user found for Telegram ID $telegramId');
    }
    final owned = await _fetchOwnedFarmIds(userId: userId);
    final member = await _fetchMemberFarmIds(userId: userId);
    final set = <String>{...owned, ...member};
    return set.toList();
  }

  String _getTelegramIdFromToken() {
    final p = _decodeJwtPayload(widget.token);
    return (p['telegram_id'] ?? p['sub'])?.toString() ?? '';
  }

  Map<String, dynamic> _decodeJwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return {};
      final payload = parts[1];
      var output = payload.replaceAll('-', '+').replaceAll('_', '/');
      switch (output.length % 4) {
        case 2:
          output += '==';
          break;
        case 3:
          output += '=';
          break;
      }
      final decoded = utf8.decode(base64.decode(output));
      return json.decode(decoded);
    } catch (e) {
      debugPrint('JWT decode error: $e');
      return {};
    }
  }

  Future<String?> _fetchUserIdForTelegram({required String telegramId}) async {
    final url = '$SUPABASE_URL/rest/v1/app_users?select=id&telegram_id=eq.$telegramId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ${widget.token}',
        'Accept': 'application/json',
      },
    );
    if (resp.statusCode != 200) return null;
    final List data = json.decode(resp.body);
    if (data.isEmpty) return null;
    return (data.first['id'] ?? '').toString();
  }

  Future<List<String>> _fetchOwnedFarmIds({required String userId}) async {
    final url = '$SUPABASE_URL/rest/v1/farms?select=id&owner_id=eq.$userId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ${widget.token}',
        'Accept': 'application/json',
      },
    );
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data.map<String>((e) => (e['id'] ?? '').toString()).where((e) => e.isNotEmpty).toList();
  }

  Future<List<String>> _fetchMemberFarmIds({required String userId}) async {
    final url = '$SUPABASE_URL/rest/v1/farm_members?select=farm_id&user_id=eq.$userId';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ${widget.token}',
        'Accept': 'application/json',
      },
    );
    if (resp.statusCode != 200) return [];
    final List data = json.decode(resp.body);
    return data.map<String>((e) => (e['farm_id'] ?? '').toString()).where((e) => e.isNotEmpty).toList();
  }

  Future<List<Map<String, dynamic>>> _fetchAnimalsForFarms({required List<String> farmIds}) async {
    if (farmIds.isEmpty) return [];
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url = '$SUPABASE_URL/rest/v1/animals?select=*&farm_id=in.$encodedList&order=id';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ${widget.token}',
        'Accept': 'application/json',
      },
    );
    if (resp.statusCode != 200) {
      throw Exception('Failed to fetch animals: ${resp.statusCode}');
    }
    final List data = json.decode(resp.body);
    return List<Map<String, dynamic>>.from(data.map((e) => Map<String, dynamic>.from(e as Map)));
  }

  Future<void> _saveForAnimal(String animalId) async {
    final qtyStr = _qtyControllers[animalId]?.text.trim() ?? '';
    if (qtyStr.isEmpty) {
      setState(() => _rowStatus[animalId] = 'error: empty');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid quantity.')),
      );
      return;
    }

    final qty = double.tryParse(qtyStr);
    if (qty == null || qty <= 0) {
      setState(() => _rowStatus[animalId] = 'error: invalid');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid positive number.')),
      );
      return;
    }

    try {
      final animal = _animals.firstWhere((a) => (a['id'] ?? '').toString() == animalId, orElse: () => {});
      final farmId = (animal['farm_id'] ?? '').toString();

      final response = await http.post(
        Uri.parse('$SUPABASE_URL/rest/v1/milk_production'),
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer ${widget.token}',
          'Content-Type': 'application/json',
          'Prefer': 'return=minimal',
        },
        body: json.encode({
          'animal_id': animalId,
          'farm_id': farmId.isNotEmpty ? farmId : null,
          'quantity': qty,
          'date': DateTime.now().toIso8601String().split('T')[0],
          'source': 'web',
        }),
      );

      debugPrint('saveForAnimal status: ${response.statusCode} body: ${response.body}');
      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() => _rowStatus[animalId] = 'saved');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Milk production saved for animal $animalId.'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        setState(() => _rowStatus[animalId] = 'error: ${response.statusCode}');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save: ${response.statusCode}')),
        );
      }
    } catch (e) {
      setState(() => _rowStatus[animalId] = 'error: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  Future<void> _batchSave() async {
    bool hasError = false;
    for (final a in _animals) {
      final id = (a['id'] ?? '').toString();
      if (id.isNotEmpty) {
        await _saveForAnimal(id);
        if (_rowStatus[id]?.startsWith('error') ?? false) {
          hasError = true;
        }
      }
    }
    if (!hasError) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('All valid entries saved successfully.'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  Widget _buildTable() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Card(
        elevation: 2,
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge),
            ],
          ),
        ),
      );
    }
    if (_animals.isEmpty) {
      return Card(
        elevation: 2,
        margin: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No animals available.', style: Theme.of(context).textTheme.bodyLarge),
        ),
      );
    }

    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(8),
      child: Scrollbar(
        controller: _verticalController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: _verticalController,
          scrollDirection: Axis.vertical,
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                controller: _horizontalController,
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: DataTable(
                    columnSpacing: 16,
                    dataRowMinHeight: 60,
                    headingTextStyle: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                    columns: const [
                      DataColumn(label: Text('Tag / Name')),
                      DataColumn(label: Text('Quantity (L)')),
                      DataColumn(label: Text('Action')),
                      DataColumn(label: Text('Status')),
                    ],
                    rows: _animals.map((a) {
                      final id = (a['id'] ?? '').toString();
                      final tag = (a['tag'] ?? '').toString();
                      final name = (a['name'] ?? '').toString();
                      _qtyControllers[id] ??= TextEditingController();
                      final controller = _qtyControllers[id]!;
                      final statusText = _rowStatus[id] ?? '';

                      return DataRow(
                        cells: [
                          DataCell(
                            Text(
                              '$tag — $name',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          DataCell(
                            SizedBox(
                              width: 120,
                              child: TextField(
                                controller: controller,
                                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                decoration: InputDecoration(
                                  isDense: true,
                                  contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
                                  hintText: 'e.g. 3.2',
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  errorText: statusText.startsWith('error') ? 'Invalid' : null,
                                ),
                              ),
                            ),
                          ),
                          DataCell(
                            ElevatedButton.icon(
                              onPressed: id.isNotEmpty ? () => _saveForAnimal(id) : null,
                              icon: const Icon(Icons.save, size: 16),
                              label: const Text('Save'),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                              ),
                            ),
                          ),
                          DataCell(
                            Text(
                              statusText == 'saved'
                                  ? 'Saved'
                                  : statusText.startsWith('error')
                                      ? 'Error'
                                      : '',
                              style: TextStyle(
                                color: statusText.startsWith('error')
                                    ? Colors.red
                                    : (statusText == 'saved' ? Colors.green : Colors.black87),
                              ),
                            ),
                          ),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    for (final c in _qtyControllers.values) {
      c.dispose();
    }
    _horizontalController.dispose();
    _verticalController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Milk Production'),
          actions: [
            IconButton(
              onPressed: _fetchAnimals,
              icon: const Icon(Icons.refresh),
              tooltip: 'Refresh',
            ),
          ],
        ),
        body: RefreshIndicator(
          onRefresh: _fetchAnimals,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Column(
              children: [
                Expanded(child: _buildTable()),
                const SizedBox(height: 12),
                ElevatedButton.icon(
                  onPressed: _batchSave,
                  icon: const Icon(Icons.save_alt),
                  label: const Text('Save All'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    textStyle: Theme.of(context).textTheme.labelLarge,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}*/