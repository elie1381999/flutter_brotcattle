// lib/fill_net.dart
import 'package:flutter/material.dart';
import 'api_service.dart' as api_service;
import 'api_fill_net.dart';

class FillNetPage extends StatefulWidget {
  final api_service.ApiService apiService;
  const FillNetPage({super.key, required this.apiService});

  @override
  State<FillNetPage> createState() => _FillNetPageState();
}

class _FillNetPageState extends State<FillNetPage> {
  late final FillNetApi _api;
  String? _selectedFarmId;
  List<Map<String, dynamic>> _farms = [];
  List<Map<String, dynamic>> _animals = [];
  List<Map<String, dynamic>> _feedItems = [];

  // Added missing selected feed item id
  String? _selectedFeedItemId;

  // Form controllers
  final _milkPriceCtrl = TextEditingController();
  final _feedQtyCtrl = TextEditingController();
  final _feedUnitCtrl = TextEditingController();
  final _feedUnitCostCtrl = TextEditingController();
  bool _isSingleAnimalFeed = true;
  String? _selectedSingleAnimalId;
  final Set<String> _selectedAnimalIds = {};
  String _allocationMethod = 'equal';
  final _manualPropsCtrl = TextEditingController();
  final _finAmountCtrl = TextEditingController();
  String? _finAnimalId;
  final _finNoteCtrl = TextEditingController();
  // Allowed financial types — must match your DB enum values
  final List<String> _finTypes = ['sale', 'vet', 'breeding', 'feed', 'other'];
  String? _selectedFinType;

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _api = FillNetApi(widget.apiService);
    _loadFarms();
  }

  Future<void> _loadFarms() async {
    if (mounted) {
      setState(() {
        _loading = true;
      });
    }
    try {
      final farms = await _api.fetchFarmsForUser();
      if (mounted) {
        setState(() {
          _farms = farms;
          if (_farms.isNotEmpty && _selectedFarmId == null) {
            _selectedFarmId = _farms.first['id']?.toString();
            if (_selectedFarmId != null) {
              _onFarmChanged(_selectedFarmId!);
            }
          }
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _onFarmChanged(String farmId) async {
    if (mounted) {
      setState(() {
        _selectedFarmId = farmId;
        _animals = [];
        _feedItems = [];
        _selectedAnimalIds.clear();
        _selectedSingleAnimalId = null;
        _selectedFeedItemId = null;
      });
    }
    final animals = await _api.fetchAnimalsForFarm(farmId);
    final feeds = await _api.fetchFeedItems(farmId: farmId);
    if (mounted) {
      setState(() {
        _animals = animals;
        _feedItems = feeds;
      });
    }
  }

  @override
  void dispose() {
    _milkPriceCtrl.dispose();
    _feedQtyCtrl.dispose();
    _feedUnitCtrl.dispose();
    _feedUnitCostCtrl.dispose();
    _manualPropsCtrl.dispose();
    _finAmountCtrl.dispose();
    _finNoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _setMilkPrice() async {
    if (_selectedFarmId == null) {
      if (mounted) {
        _showError('Select farm first.');
      }
      return;
    }
    final text = _milkPriceCtrl.text.trim();
    if (text.isEmpty) {
      if (mounted) {
        _showError('Enter milk price per unit.');
      }
      return;
    }
    final price = double.tryParse(text);
    if (price == null) {
      if (mounted) {
        _showError('Invalid number for price.');
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
      });
    }
    final ok = await _api.setFarmMilkPrice(_selectedFarmId!, price);
    if (mounted) {
      setState(() {
        _loading = false;
      });
      if (ok) {
        _showSuccess('Milk price saved.');
      } else {
        _showError('Failed to save milk price.');
      }
    }
  }

  Future<void> _previewAllocation() async {
    if (_isSingleAnimalFeed) {
      if (mounted) {
        _showError(
          'Preview available only for group feed. Switch Single-animal feed off.',
        );
      }
      return;
    }
    if (_selectedFarmId == null) {
      if (mounted) {
        _showError('Select farm first.');
      }
      return;
    }
    if (_selectedFeedItemId == null) {
      if (mounted) {
        _showError('Select feed item.');
      }
      return;
    }
    final qty = double.tryParse(_feedQtyCtrl.text.trim());
    if (qty == null || qty <= 0) {
      if (mounted) {
        _showError('Enter valid quantity.');
      }
      return;
    }

    final targetIds = _selectedAnimalIds.isNotEmpty
        ? _selectedAnimalIds.toList()
        : _animals
              .map((e) => (e['id'] ?? '').toString())
              .where((s) => s.isNotEmpty)
              .toList();
    if (targetIds.isEmpty) {
      if (mounted) {
        _showError('No animals selected or found in farm.');
      }
      return;
    }

    double? unitCost;
    if (_feedUnitCostCtrl.text.trim().isNotEmpty) {
      unitCost = double.tryParse(_feedUnitCostCtrl.text.trim());
    } else {
      final fi = _feedItems.firstWhere(
        (f) => (f['id'] ?? '').toString() == _selectedFeedItemId,
        orElse: () => {},
      );
      unitCost = (fi['cost_per_unit'] != null)
          ? double.tryParse(fi['cost_per_unit'].toString())
          : null;
    }
    if (unitCost == null) {
      if (mounted) {
        _showError(
          'Unit cost unknown. Provide unit cost or set it on the feed item.',
        );
      }
      return;
    }

    // make non-nullable local copy to satisfy analyzer
    final double unitCostVal = unitCost;

    List<Map<String, dynamic>> allocations = [];
    try {
      if (mounted) {
        setState(() {
          _loading = true;
        });
      }

      if (_allocationMethod == 'equal') {
        final n = targetIds.length;
        final proportion = 1.0 / n;
        for (final id in targetIds) {
          final animal = _animals.firstWhere(
            (a) => (a['id'] ?? '').toString() == id,
            orElse: () => {'tag': id},
          );
          allocations.add({
            'animal_id': id,
            'tag': animal['tag'] ?? animal['name'] ?? id,
            'proportion': proportion,
            'allocated_cost': proportion * qty * unitCostVal,
          });
        }
      } else if (_allocationMethod == 'weight') {
        double sum = 0;
        final weights = <String, double>{};
        for (final id in targetIds) {
          final animal = _animals.firstWhere(
            (a) => (a['id'] ?? '').toString() == id,
            orElse: () => {},
          );
          final w = (animal['weight'] != null)
              ? double.tryParse(animal['weight'].toString()) ?? 0.0
              : 0.0;
          weights[id] = w;
          sum += w;
        }
        if (sum == 0) {
          final n = targetIds.length;
          final proportion = 1.0 / n;
          for (final id in targetIds) {
            final animal = _animals.firstWhere(
              (a) => (a['id'] ?? '').toString() == id,
              orElse: () => {'tag': id},
            );
            allocations.add({
              'animal_id': id,
              'tag': animal['tag'] ?? animal['name'] ?? id,
              'proportion': proportion,
              'allocated_cost': proportion * qty * unitCostVal,
            });
          }
        } else {
          for (final id in targetIds) {
            final p = weights[id]! / sum;
            final animal = _animals.firstWhere(
              (a) => (a['id'] ?? '').toString() == id,
              orElse: () => {'tag': id},
            );
            allocations.add({
              'animal_id': id,
              'tag': animal['tag'] ?? animal['name'] ?? id,
              'proportion': p,
              'allocated_cost': p * qty * unitCostVal,
            });
          }
        }
      } else if (_allocationMethod == 'milk') {
        final from = DateTime.now().subtract(const Duration(days: 7));
        final milkEntries = await widget.apiService.fetchMilkHistory(
          animalIds: targetIds,
          fromDate: from,
          toDate: DateTime.now(),
        );
        final milkBy = <String, double>{};
        for (final e in milkEntries) {
          final aid = (e['animal_id'] ?? '').toString();
          final qtym =
              double.tryParse((e['quantity'] ?? '0').toString()) ?? 0.0;
          milkBy.update(aid, (v) => v + qtym, ifAbsent: () => qtym);
        }
        final totalMilk = milkBy.values.fold(0.0, (p, n) => p + n);
        if (totalMilk == 0) {
          final n = targetIds.length;
          final proportion = 1.0 / n;
          for (final id in targetIds) {
            final animal = _animals.firstWhere(
              (a) => (a['id'] ?? '').toString() == id,
              orElse: () => {'tag': id},
            );
            allocations.add({
              'animal_id': id,
              'tag': animal['tag'] ?? animal['name'] ?? id,
              'proportion': proportion,
              'allocated_cost': proportion * qty * unitCostVal,
            });
          }
        } else {
          for (final id in targetIds) {
            final m = milkBy[id] ?? 0.0;
            final p = m / totalMilk;
            final animal = _animals.firstWhere(
              (a) => (a['id'] ?? '').toString() == id,
              orElse: () => {'tag': id},
            );
            allocations.add({
              'animal_id': id,
              'tag': animal['tag'] ?? animal['name'] ?? id,
              'proportion': p,
              'allocated_cost': p * qty * unitCostVal,
            });
          }
        }
      } else if (_allocationMethod == 'manual') {
        final raw = _manualPropsCtrl.text.trim();
        if (raw.isEmpty) {
          if (mounted) {
            _showError(
              'Manual allocation selected but no proportions provided.',
            );
          }
          if (mounted) {
            setState(() {
              _loading = false;
            });
          }
          return;
        }
        final parts = raw
            .split(',')
            .map((s) => double.tryParse(s.trim()) ?? 0.0)
            .toList();
        if (parts.length != targetIds.length) {
          if (mounted) {
            _showError(
              'Manual proportions length must match number of selected animals.',
            );
          }
          if (mounted) {
            setState(() {
              _loading = false;
            });
          }
          return;
        }
        final sum = parts.fold(0.0, (p, n) => p + n);
        if (sum <= 0) {
          if (mounted) {
            _showError('Manual proportions must sum to more than zero.');
          }
          if (mounted) {
            setState(() {
              _loading = false;
            });
          }
          return;
        }
        for (var i = 0; i < targetIds.length; i++) {
          final id = targetIds[i];
          final p = parts[i] / sum;
          final animal = _animals.firstWhere(
            (a) => (a['id'] ?? '').toString() == id,
            orElse: () => {'tag': id},
          );
          allocations.add({
            'animal_id': id,
            'tag': animal['tag'] ?? animal['name'] ?? id,
            'proportion': p,
            'allocated_cost': p * qty * unitCostVal,
          });
        }
      } else {
        if (mounted) {
          _showError('Unknown allocation method: $_allocationMethod');
        }
        if (mounted) {
          setState(() {
            _loading = false;
          });
        }
        return;
      }

      if (mounted) {
        await showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (ctx) {
            return Padding(
              padding: MediaQuery.of(
                ctx,
              ).viewInsets.add(const EdgeInsets.all(12)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListTile(
                    title: Text('Preview allocation ($_allocationMethod)'),
                    subtitle: Text(
                      'Total qty: ${qty.toString()} ${_feedUnitCtrl.text.isNotEmpty ? _feedUnitCtrl.text : ''} • Unit cost: ${unitCostVal.toStringAsFixed(3)}',
                    ),
                  ),
                  const Divider(),
                  SizedBox(
                    height: 300,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: allocations.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (c, i) {
                        final row = allocations[i];
                        final tag = row['tag'] ?? row['animal_id'];
                        final p = (row['proportion'] ?? 0.0) as double;
                        final cost = (row['allocated_cost'] ?? 0.0) as double;
                        return ListTile(
                          dense: true,
                          title: Text(tag.toString()),
                          subtitle: Text('${(p * 100).toStringAsFixed(2)}%'),
                          trailing: Text(cost.toStringAsFixed(2)),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.of(ctx).pop();
                          _submitFeed();
                        },
                        child: const Text('Confirm & Save'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            );
          },
        );
      }
    } catch (e) {
      if (mounted) {
        _showError('Failed to compute preview: $e');
      }
      return;
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _submitFeed() async {
    if (_selectedFarmId == null) {
      if (mounted) {
        _showError('Select farm first.');
      }
      return;
    }
    if (_selectedFeedItemId == null) {
      if (mounted) {
        _showError('Select feed item.');
      }
      return;
    }
    final qty = double.tryParse(_feedQtyCtrl.text.trim());
    if (qty == null || qty <= 0) {
      if (mounted) {
        _showError('Enter valid quantity.');
      }
      return;
    }

    if (mounted) {
      setState(() {
        _loading = true;
      });
    }
    try {
      if (_isSingleAnimalFeed) {
        if (_selectedSingleAnimalId == null) {
          if (mounted) {
            _showError('Select single animal.');
          }
          return;
        }
        final rec = await _api.createFeedTransaction(
          farmId: _selectedFarmId!,
          feedItemId: _selectedFeedItemId!,
          quantity: qty,
          unit: _feedUnitCtrl.text.trim(),
          singleAnimalId: _selectedSingleAnimalId,
          unitCost: _feedUnitCostCtrl.text.trim().isNotEmpty
              ? double.tryParse(_feedUnitCostCtrl.text.trim())
              : null,
        );
        if (mounted) {
          if (rec != null) {
            _showSuccess('Feed transaction saved for animal.');
          } else {
            _showError('Failed to save feed transaction.');
          }
        }
      } else {
        final rec = await _api.createFeedTransaction(
          farmId: _selectedFarmId!,
          feedItemId: _selectedFeedItemId!,
          quantity: qty,
          unit: _feedUnitCtrl.text.trim(),
          singleAnimalId: null,
          unitCost: _feedUnitCostCtrl.text.trim().isNotEmpty
              ? double.tryParse(_feedUnitCostCtrl.text.trim())
              : null,
        );
        if (rec == null || rec['id'] == null) {
          if (mounted) {
            _showError('Failed to create group feed transaction.');
          }
          return;
        }
        final txId = rec['id'].toString();

        final animalIds = _selectedAnimalIds.isNotEmpty
            ? _selectedAnimalIds.toList()
            : _animals
                  .map((e) => e['id']?.toString() ?? '')
                  .where((s) => s.isNotEmpty)
                  .toList();
        if (animalIds.isEmpty) {
          if (mounted) {
            _showError(
              'No animals selected for allocation and no animals found in farm.',
            );
          }
          return;
        }

        List<double>? manualProps;
        if (_allocationMethod == 'manual') {
          final raw = _manualPropsCtrl.text.trim();
          if (raw.isEmpty) {
            if (mounted) {
              _showError(
                'Manual allocation selected but no proportions provided.',
              );
            }
            return;
          }
          try {
            manualProps = raw
                .split(',')
                .map((s) => double.parse(s.trim()))
                .toList();
            if (manualProps.length != animalIds.length) {
              if (mounted) {
                _showError(
                  'Manual proportions length must match number of selected animals.',
                );
              }
              return;
            }
          } catch (e) {
            if (mounted) {
              _showError(
                'Invalid manual proportions: use comma separated numbers.',
              );
            }
            return;
          }
        }

        final ok = await _api.allocateFeedTransaction(
          feedTxId: txId,
          method: _allocationMethod,
          animalIds: animalIds,
          manualProps: manualProps,
        );
        if (mounted) {
          if (ok) {
            _showSuccess('Group feed created and allocated.');
          } else {
            _showError(
              'Failed to allocate group feed. Check server logs and permissions.',
            );
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _submitFinancialRecord() async {
    if (_selectedFarmId == null) {
      if (mounted) _showError('Select farm first.');
      return;
    }

    final amt = double.tryParse(_finAmountCtrl.text.trim());
    if (amt == null) {
      if (mounted) _showError('Enter a valid amount.');
      return;
    }

    // prefer dropdown selection, fallback to text field (if you kept it)
    final rawType = (_selectedFinType ?? '').toString().toLowerCase();

    if (rawType.isEmpty) {
      if (mounted) _showError('Select a financial record type.');
      return;
    }

    // prevent accidental numeric values like "30"
    final isNumeric = RegExp(r'^\d+(\.\d+)?$').hasMatch(rawType);
    if (isNumeric) {
      if (mounted)
        _showError('Type appears numeric. Pick a valid type from the list.');
      return;
    }

    if (!_finTypes.contains(rawType)) {
      if (mounted) _showError('Type must be one of: ${_finTypes.join(', ')}');
      return;
    }

    if (mounted) setState(() => _loading = true);

    try {
      final rec = await _api.createFinancialRecord(
        farmId: _selectedFarmId!,
        type: rawType,
        amount: amt,
        description: _finNoteCtrl.text.trim(),
        animalId: _finAnimalId,
      );
      if (mounted) {
        if (rec != null)
          _showSuccess('Financial record saved.');
        else
          _showError('Failed to save financial record.');
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _showError(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
    }
  }

  void _showSuccess(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.green),
      );
    }
  }

  Future<void> _selectAnimalsDialog() async {
    final selected = Set<String>.from(_selectedAnimalIds);
    await showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Select animals to allocate'),
          content: SizedBox(
            width: double.maxFinite,
            child: _animals.isEmpty
                ? const Text('No animals found.')
                : ListView(
                    shrinkWrap: true,
                    children: _animals.map((a) {
                      final id = a['id']?.toString() ?? '';
                      final tag = (a['tag'] ?? a['name'] ?? '').toString();
                      final selectedNow = selected.contains(id);
                      return CheckboxListTile(
                        value: selectedNow,
                        title: Text(tag),
                        onChanged: (v) {
                          setState(() {
                            if (v == true)
                              selected.add(id);
                            else
                              selected.remove(id);
                          });
                        },
                      );
                    }).toList(),
                  ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _selectedAnimalIds.clear();
                  _selectedAnimalIds.addAll(selected);
                });
                Navigator.of(ctx).pop();
              },
              child: const Text('Apply'),
            ),
          ],
        );
      },
    );
  }

  void _clearFeedForm() {
    _feedQtyCtrl.clear();
    _feedUnitCtrl.clear();
    _feedUnitCostCtrl.clear();
    _selectedFeedItemId = null;
    _isSingleAnimalFeed = true;
    _selectedSingleAnimalId = null;
    _selectedAnimalIds.clear();
    _allocationMethod = 'equal';
    _manualPropsCtrl.clear();
    setState(() {});
  }

  void _clearFinancialForm() {
    _finAmountCtrl.clear();

    _finNoteCtrl.clear();
    _finAnimalId = null;
    _selectedFinType = null; // reset dropdown selection
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Fill Net — Feed / Prices / Expenses'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadFarms),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Farm selection',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: _selectedFarmId,
                    items: _farms.map((f) {
                      final id = (f['id'] ?? '').toString();
                      final name = (f['name'] ?? id).toString();
                      return DropdownMenuItem(value: id, child: Text(name));
                    }).toList(),
                    onChanged: (v) {
                      if (v != null) _onFarmChanged(v);
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      hintText: 'Select farm',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'Milk price (per unit)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _milkPriceCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            hintText: 'e.g. 0.36',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: _setMilkPrice,
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Add Feed',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          value: _selectedFeedItemId,
                          items: _feedItems.map((f) {
                            final id = (f['id'] ?? '').toString();
                            final name = (f['name'] ?? '').toString();
                            final cost = f['cost_per_unit'] != null
                                ? ' (${f['cost_per_unit']})'
                                : '';
                            return DropdownMenuItem(
                              value: id,
                              child: Text('$name$cost'),
                            );
                          }).toList(),
                          onChanged: (v) =>
                              setState(() => _selectedFeedItemId = v),
                          decoration: const InputDecoration(
                            labelText: 'Feed item',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _feedQtyCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Quantity',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _feedUnitCtrl,
                          decoration: const InputDecoration(
                            labelText: 'Unit (kg)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextFormField(
                          controller: _feedUnitCostCtrl,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: 'Unit cost (optional)',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('Single-animal feed'),
                          subtitle: const Text(
                            'If off, will create group feed and allocate to animals',
                          ),
                          value: _isSingleAnimalFeed,
                          onChanged: (v) =>
                              setState(() => _isSingleAnimalFeed = v),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                  ),
                  if (_isSingleAnimalFeed) ...[
                    const SizedBox(height: 8),
                    DropdownButtonFormField<String>(
                      value: _selectedSingleAnimalId,
                      items: _animals.map((a) {
                        final id = (a['id'] ?? '').toString();
                        final tag = (a['tag'] ?? a['name'] ?? '').toString();
                        return DropdownMenuItem(value: id, child: Text(tag));
                      }).toList(),
                      onChanged: (v) =>
                          setState(() => _selectedSingleAnimalId = v),
                      decoration: const InputDecoration(
                        labelText: 'Animal',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ] else ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        ElevatedButton.icon(
                          icon: const Icon(Icons.group),
                          label: const Text('Select animals (optional)'),
                          onPressed: _selectAnimalsDialog,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<String>(
                            value: _allocationMethod,
                            items: ['equal', 'weight', 'milk', 'manual']
                                .map(
                                  (m) => DropdownMenuItem(
                                    value: m,
                                    child: Text(m),
                                  ),
                                )
                                .toList(),
                            onChanged: (v) => setState(
                              () => _allocationMethod = v ?? 'equal',
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Allocation method',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                      ],
                    ),
                    if (_allocationMethod == 'manual') ...[
                      const SizedBox(height: 8),
                      TextFormField(
                        controller: _manualPropsCtrl,
                        decoration: const InputDecoration(
                          labelText: 'Manual proportions (comma separated)',
                          border: OutlineInputBorder(),
                          hintText: 'e.g. 2,1,1',
                        ),
                      ),
                    ],
                  ],
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isSingleAnimalFeed
                            ? _submitFeed
                            : _previewAllocation,
                        icon: Icon(
                          _isSingleAnimalFeed ? Icons.save : Icons.preview,
                        ),
                        label: Text(
                          _isSingleAnimalFeed
                              ? 'Save Feed'
                              : 'Preview allocation',
                        ),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _clearFeedForm,
                        icon: const Icon(Icons.clear),
                        label: const Text('Clear'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Add Financial Record (vet, sale, breeding etc.)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _finAmountCtrl,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      labelText: 'Amount',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Use dropdown to ensure only valid enum values are sent
                  DropdownButtonFormField<String>(
                    value: _selectedFinType,
                    items: _finTypes
                        .map(
                          (t) => DropdownMenuItem<String>(
                            value: t,
                            child: Text(t),
                          ),
                        )
                        .toList(),
                    onChanged: (v) => setState(() => _selectedFinType = v),
                    decoration: const InputDecoration(
                      labelText: 'Type (choose one)',
                      border: OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(height: 8),
                  DropdownButtonFormField<String?>(
                    value: _finAnimalId,
                    items: [
                      DropdownMenuItem<String?>(
                        value: null,
                        child: const Text('— no animal / shared —'),
                      ),
                      ..._animals.map((a) {
                        final id = a['id']?.toString() ?? '';
                        final tag = (a['tag'] ?? a['name'] ?? '').toString();
                        return DropdownMenuItem<String?>(
                          value: id,
                          child: Text(tag),
                        );
                      }).toList(),
                    ],
                    onChanged: (v) => setState(() => _finAnimalId = v),
                    decoration: const InputDecoration(
                      labelText: 'Animal (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _finNoteCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Note / Vendor',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _submitFinancialRecord,
                        icon: const Icon(Icons.save),
                        label: const Text('Save Financial Record'),
                      ),
                      const SizedBox(width: 12),
                      OutlinedButton.icon(
                        onPressed: _clearFinancialForm,
                        icon: const Icon(Icons.clear),
                        label: const Text('Clear'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
    );
  }
}
