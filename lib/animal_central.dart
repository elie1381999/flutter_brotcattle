// lib/animal_central_with_crud.dart
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';

import 'api_service.dart';

class AnimalCentralPage extends StatefulWidget {
  final String token;
  const AnimalCentralPage({super.key, required this.token});

  @override
  State<AnimalCentralPage> createState() => _AnimalCentralPageState();
}

class _AnimalCentralPageState extends State<AnimalCentralPage> {
  late final ApiService _apiService;

  List<Map<String, dynamic>> _animals = [];
  Map<String, String> _farmNames = {}; // farmId -> farmName
  List<String> _userFarmIds = [];

  bool _loading = true;
  String? _error;

  // UI state
  final TextEditingController _searchController = TextEditingController();
  String? _selectedFarmId;
  bool _showOnlyLactating = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  Map<String, dynamic>? _selectedAnimal;

  // ---- Stage & Sex constants (as requested)
  static const List<String> STAGES = [
    'Calf',
    'Weaner',
    'Heifer',
    'Cow',
    'Steer',
    'Bull',
  ];
  static const List<String> SEXES = ['Female', 'Male', 'Unknown'];

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAll();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchAll() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals = [];
      _farmNames = {};
      _selectedIds.clear();
      _selectionMode = false;
      _selectedAnimal = null;
      _userFarmIds = [];
    });

    try {
      final farmIds = await _api_service_getUserFarmIds();
      _userFarmIds = farmIds;
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }

      final farmsMap = await _apiService.fetchFarmsByIds(farmIds);
      setState(() => _farmNames = farmsMap);

      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      // Normalize animals: support both 'dob' and 'birth_date' keys by mapping to 'dob' for UI
      final normalized = animals.map((a) {
        final m = Map<String, dynamic>.from(a);
        if ((m['dob'] == null || m['dob'].toString().isEmpty) &&
            (m['birth_date'] != null)) {
          m['dob'] = m['birth_date'];
        }
        // Ensure stage and sex are present as nice-cased strings for UI
        if (m['stage'] != null && m['stage'].toString().isNotEmpty) {
          final st = m['stage'].toString();
          final found = STAGES.firstWhere(
            (e) => e.toLowerCase() == st.toLowerCase(),
            orElse: () => st[0].toUpperCase() + st.substring(1),
          );
          m['stage'] = found;
        }
        if (m['sex'] != null && m['sex'].toString().isNotEmpty) {
          final sx = m['sex'].toString();
          final found = SEXES.firstWhere(
            (e) => e.toLowerCase() == sx.toLowerCase(),
            orElse: () => sx[0].toUpperCase() + sx.substring(1),
          );
          m['sex'] = found;
        }
        return m;
      }).toList();

      setState(() {
        _animals = normalized;
        _loading = false;
      });
    } catch (e) {
      debugPrint('fetchAnimals error: $e');
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

  List<Map<String, dynamic>> get _filteredAnimals {
    final q = _searchController.text.trim().toLowerCase();
    return _animals.where((a) {
      if (_selectedFarmId != null && _selectedFarmId!.isNotEmpty) {
        if ((a['farm_id'] ?? '').toString() != _selectedFarmId) return false;
      }
      if (_showOnlyLactating) {
        final lact =
            (a['lactation'] ??
                    a['lactation_status'] ??
                    a['lactation_flag'] ??
                    '')
                .toString()
                .toLowerCase();
        if (!(lact == 'yes' || lact == 'true' || lact == '1' || lact == 'y')) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();
  }

  int _calculateAgeInMonths(String dob) {
    try {
      final d = DateTime.parse(dob);
      final now = DateTime.now();
      return (now.year - d.year) * 12 + (now.month - d.month);
    } catch (_) {
      return -1;
    }
  }

  String _ageLabel(String dob) {
    final months = _calculateAgeInMonths(dob);
    if (months < 0) return 'Unknown age';
    final y = months ~/ 12;
    final m = months % 12;
    if (y > 0) return '$y yr${y > 1 ? 's' : ''}${m > 0 ? ' $m mo' : ''}';
    return '$m mo';
  }

  Future<void> _deleteAnimal(String id, {bool showUndo = true}) async {
    final idx = _animals.indexWhere((e) => (e['id'] ?? '').toString() == id);
    if (idx == -1) return;

    final backup = _animals[idx];
    setState(() => _animals.removeAt(idx)); // optimistic

    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    if (showUndo) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Animal deleted'),
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () {
              setState(() => _animals.insert(idx, backup));
            },
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }

    try {
      final ok = await _apiService.deleteAnimal(id);
      if (!ok) {
        if (!_animals.contains(backup)) {
          setState(() => _animals.insert(idx, backup));
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete animal.')),
        );
      }
    } catch (e) {
      if (!_animals.contains(backup)) {
        setState(() => _animals.insert(idx, backup));
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to delete animal.')));
      debugPrint('delete animal error: $e');
    }
  }

  void _toggleSelectionMode([bool? enable]) {
    setState(() {
      _selectionMode = enable ?? !_selectionMode;
      if (!_selectionMode) _selectedIds.clear();
    });
  }

  void _onItemTap(Map<String, dynamic> a, bool wideLayout) {
    final id = (a['id'] ?? '').toString();
    if (_selectionMode) {
      setState(() {
        if (_selectedIds.contains(id)) {
          _selectedIds.remove(id);
        } else {
          _selectedIds.add(id);
        }
      });
      return;
    }

    if (wideLayout) {
      setState(() => _selectedAnimal = a);
      return;
    }

    // show details bottom sheet for narrow screens
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.25,
            maxChildSize: 0.95,
            builder: (_, controller) {
              return _AnimalDetailSheet(
                animal: a,
                farmName: _farmNames[(a['farm_id'] ?? '').toString()] ?? '',
                onEdit: () {
                  Navigator.pop(context);
                  _showAnimalForm(animal: a);
                },
                onDelete: () {
                  Navigator.pop(context);
                  _confirmAndDelete((a['id'] ?? '').toString());
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmAndDelete(String id) async {
    final c = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete animal'),
        content: const Text('Are you sure you want to delete this animal?'),
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
    if (c == true) await _deleteAnimal(id);
  }

  Future<void> _performBulkDelete() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete selected animals'),
        content: Text('Delete ${_selectedIds.length} selected animals?'),
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
    if (confirmed != true) return;

    final ids = _selectedIds.toList();
    for (final id in ids) {
      await _deleteAnimal(id, showUndo: false);
    }
    _toggleSelectionMode(false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${ids.length} animals deleted')));
  }

  Widget _initialsAvatar(String name) {
    final label = name.isNotEmpty ? name[0].toUpperCase() : 'A';
    return CircleAvatar(
      radius: 36,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontSize: 24,
        ),
      ),
    );
  }

  Future<void> _showAnimalForm({Map<String, dynamic>? animal}) async {
    final isEdit = animal != null;
    final tagCtl = TextEditingController(
      text: animal != null ? (animal['tag'] ?? '').toString() : '',
    );
    final nameCtl = TextEditingController(
      text: animal != null ? (animal['name'] ?? '').toString() : '',
    );
    final breedCtl = TextEditingController(
      text: animal != null ? (animal['breed'] ?? '').toString() : '',
    );
    final dobCtl = TextEditingController(
      text: animal != null ? (animal['dob'] ?? '').toString() : '',
    );
    final notesCtl = TextEditingController(
      text: animal != null ? (animal['notes'] ?? '').toString() : '',
    );
    final imageCtl = TextEditingController(
      text: animal != null ? (animal['image_url'] ?? '').toString() : '',
    );

    String? selectedFarm = animal != null
        ? (animal['farm_id'] ?? '').toString()
        : (_userFarmIds.isNotEmpty ? _userFarmIds.first : null);

    // Initialize sex and stage for the form (local variables)
    String sexForForm = 'Female';
    String stageForForm = 'Calf';
    if (animal != null) {
      final rawSex = (animal['sex'] ?? '').toString();
      if (rawSex.isNotEmpty) {
        final foundSex = SEXES.firstWhere(
          (s) => s.toLowerCase() == rawSex.toLowerCase(),
          orElse: () => rawSex[0].toUpperCase() + rawSex.substring(1),
        );
        sexForForm = foundSex;
      }
      final rawStage = (animal['stage'] ?? '').toString();
      if (rawStage.isNotEmpty) {
        final foundStage = STAGES.firstWhere(
          (s) => s.toLowerCase() == rawStage.toLowerCase(),
          orElse: () => rawStage[0].toUpperCase() + rawStage.substring(1),
        );
        stageForForm = foundStage;
      }
    }

    bool lactating = false;
    final lactVal = (animal?['lactation'] ?? '').toString().toLowerCase();
    if (lactVal == 'yes' || lactVal == 'true' || lactVal == '1') {
      lactating = true;
    }

    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: MediaQuery.of(context).viewInsets,
        child: DraggableScrollableSheet(
          initialChildSize: 0.8,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return SingleChildScrollView(
              controller: controller,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      isEdit ? 'Edit animal' : 'Add animal',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Form(
                      key: formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: tagCtl,
                            decoration: const InputDecoration(labelText: 'Tag'),
                            validator: (v) =>
                                (v ?? '').trim().isEmpty ? 'Required' : null,
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: nameCtl,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: breedCtl,
                            decoration: const InputDecoration(
                              labelText: 'Breed',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: dobCtl,
                            decoration: const InputDecoration(
                              labelText: 'DOB (YYYY-MM-DD)',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: imageCtl,
                            decoration: const InputDecoration(
                              labelText: 'Image URL',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: notesCtl,
                            decoration: const InputDecoration(
                              labelText: 'Notes',
                            ),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String?>(
                                  value: selectedFarm,
                                  items: _userFarmIds
                                      .map(
                                        (f) => DropdownMenuItem(
                                          value: f,
                                          child: Text(_farmNames[f] ?? f),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) => selectedFarm = v,
                                  decoration: const InputDecoration(
                                    labelText: 'Farm',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: StatefulBuilder(
                                  builder: (c, sset) {
                                    return DropdownButtonFormField<String>(
                                      value: sexForForm,
                                      items: SEXES
                                          .map(
                                            (s) => DropdownMenuItem(
                                              value: s,
                                              child: Text(s),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (v) {
                                        if (v == null) return;
                                        sset(() {
                                          sexForForm = v;
                                          // If current stage incompatible with new sex, auto-adjust to a safe default
                                          final allowed =
                                              _availableStagesForSex(
                                                sexForForm,
                                              );
                                          if (!allowed.contains(stageForForm)) {
                                            // prefer a neutral stage if exists, else first allowed
                                            if (allowed.contains('Calf'))
                                              stageForForm = 'Calf';
                                            else
                                              stageForForm = allowed.first;
                                          }
                                        });
                                      },
                                      decoration: const InputDecoration(
                                        labelText: 'Sex',
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          StatefulBuilder(
                            builder: (c, sset) {
                              final allowedStages = _availableStagesForSex(
                                sexForForm,
                              );
                              if (!allowedStages.contains(stageForForm))
                                stageForForm = allowedStages.first;
                              return Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      value: stageForForm,
                                      items: allowedStages
                                          .map(
                                            (s) => DropdownMenuItem(
                                              value: s,
                                              child: Text(s),
                                            ),
                                          )
                                          .toList(),
                                      onChanged: (v) {
                                        if (v == null) return;
                                        sset(() => stageForForm = v);
                                      },
                                      decoration: const InputDecoration(
                                        labelText: 'Stage',
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Column(
                                    children: [
                                      const Text('Lactating'),
                                      Checkbox(
                                        value: lactating,
                                        onChanged: (v) =>
                                            sset(() => lactating = v ?? false),
                                      ),
                                    ],
                                  ),
                                ],
                              );
                            },
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: () async {
                                    if (!formKey.currentState!.validate()) {
                                      return;
                                    }

                                    // Validate stage-sex compatibility once more before closing
                                    final allowed = _availableStagesForSex(
                                      sexForForm,
                                    );
                                    if (!allowed.contains(stageForForm)) {
                                      ScaffoldMessenger.of(
                                        context,
                                      ).showSnackBar(
                                        const SnackBar(
                                          content: Text(
                                            'Selected stage is not compatible with chosen sex.',
                                          ),
                                        ),
                                      );
                                      return;
                                    }

                                    final payload = <String, dynamic>{
                                      'tag': tagCtl.text.trim(),
                                      'name': nameCtl.text.trim().isEmpty
                                          ? null
                                          : nameCtl.text.trim(),
                                      'breed': breedCtl.text.trim().isEmpty
                                          ? null
                                          : breedCtl.text.trim(),
                                      // use birth_date to match schema
                                      'birth_date': dobCtl.text.trim().isEmpty
                                          ? null
                                          : dobCtl.text.trim(),
                                      'notes': notesCtl.text.trim().isEmpty
                                          ? null
                                          : notesCtl.text.trim(),
                                      'image_url': imageCtl.text.trim().isEmpty
                                          ? null
                                          : imageCtl.text.trim(),
                                      'farm_id': selectedFarm,
                                      'lactation': lactating ? 'yes' : 'no',
                                      'sex': sexForForm.toLowerCase(),
                                      'stage': stageForForm.toLowerCase(),
                                    };

                                    Navigator.pop(
                                      context,
                                    ); // close sheet before network

                                    if (isEdit) {
                                      final id = (animal['id'] ?? '')
                                          .toString();
                                      final updated = await _apiService
                                          .updateAnimal(id, payload);
                                      if (updated != null) {
                                        // normalize
                                        if ((updated['dob'] == null ||
                                                updated['dob']
                                                    .toString()
                                                    .isEmpty) &&
                                            updated['birth_date'] != null) {
                                          updated['dob'] =
                                              updated['birth_date'];
                                        }
                                        // Normalize stage/sex for UI casing
                                        if (updated['stage'] != null) {
                                          final st = updated['stage']
                                              .toString();
                                          updated['stage'] = STAGES.firstWhere(
                                            (e) =>
                                                e.toLowerCase() ==
                                                st.toLowerCase(),
                                            orElse: () => st,
                                          );
                                        }
                                        if (updated['sex'] != null) {
                                          final sx = updated['sex'].toString();
                                          updated['sex'] = SEXES.firstWhere(
                                            (e) =>
                                                e.toLowerCase() ==
                                                sx.toLowerCase(),
                                            orElse: () => sx,
                                          );
                                        }

                                        final idx = _animals.indexWhere(
                                          (e) =>
                                              (e['id'] ?? '').toString() == id,
                                        );
                                        if (idx != -1) {
                                          setState(
                                            () => _animals[idx] = updated,
                                          );
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('Animal updated'),
                                            ),
                                          );
                                        } else {
                                          await _fetchAll();
                                        }
                                      } else {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Failed to update animal',
                                            ),
                                          ),
                                        );
                                      }
                                    } else {
                                      final created = await _apiService
                                          .createAnimal(payload);
                                      if (created != null) {
                                        if ((created['dob'] == null ||
                                                created['dob']
                                                    .toString()
                                                    .isEmpty) &&
                                            created['birth_date'] != null) {
                                          created['dob'] =
                                              created['birth_date'];
                                        }
                                        if (created['stage'] != null) {
                                          final st = created['stage']
                                              .toString();
                                          created['stage'] = STAGES.firstWhere(
                                            (e) =>
                                                e.toLowerCase() ==
                                                st.toLowerCase(),
                                            orElse: () => st,
                                          );
                                        }
                                        if (created['sex'] != null) {
                                          final sx = created['sex'].toString();
                                          created['sex'] = SEXES.firstWhere(
                                            (e) =>
                                                e.toLowerCase() ==
                                                sx.toLowerCase(),
                                            orElse: () => sx,
                                          );
                                        }
                                        setState(
                                          () => _animals.insert(0, created),
                                        );
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('Animal created'),
                                          ),
                                        );
                                      } else {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Failed to create animal',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  child: Text(
                                    isEdit ? 'Save changes' : 'Create',
                                  ),
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

    // dispose controllers
    tagCtl.dispose();
    nameCtl.dispose();
    breedCtl.dispose();
    dobCtl.dispose();
    notesCtl.dispose();
    imageCtl.dispose();
  }

  /// Returns allowed stages based on sex choice (enforcing your rules)
  List<String> _availableStagesForSex(String sex) {
    if (sex.toLowerCase() == 'male') {
      // males should not choose heifer or cow
      return STAGES.where((s) => s != 'Heifer' && s != 'Cow').toList();
    } else if (sex.toLowerCase() == 'female') {
      // females should not choose bull or steer
      return STAGES.where((s) => s != 'Bull' && s != 'Steer').toList();
    } else {
      // unknown -> allow all
      return STAGES;
    }
  }

  Widget _buildCard(Map<String, dynamic> a, bool wideLayout) {
    final tag = (a['tag'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    final breed = (a['breed'] ?? '').toString();
    final id = (a['id'] ?? '').toString();
    final farmId = (a['farm_id'] ?? '').toString();
    final farmName = _farmNames[farmId] ?? '';
    final imageUrl = (a['image_url'] ?? '').toString();
    final lact = (a['lactation'] ?? '').toString().toLowerCase();
    final lactating = (lact == 'yes' || lact == 'true' || lact == '1');
    final stage = (a['stage'] ?? '').toString();
    final sex = (a['sex'] ?? '').toString();

    final selected = _selectedIds.contains(id);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _onItemTap(a, wideLayout),
        onLongPress: () => _toggleSelectionMode(true),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: imageUrl.isNotEmpty
                    ? Image.network(
                        imageUrl,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        loadingBuilder: (c, child, progress) {
                          if (progress == null) return child;
                          return SizedBox(
                            width: 72,
                            height: 72,
                            child: Center(
                              child: CircularProgressIndicator(
                                value: progress.expectedTotalBytes != null
                                    ? progress.cumulativeBytesLoaded /
                                          (progress.expectedTotalBytes ?? 1)
                                    : null,
                              ),
                            ),
                          );
                        },
                        errorBuilder: (c, e, st) => _initialsAvatar(name),
                      )
                    : _initialsAvatar(name),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$tag — $name',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (_selectionMode)
                          Checkbox(
                            value: selected,
                            onChanged: (_) => _onItemTap(a, wideLayout),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (breed.isNotEmpty) Chip(label: Text(breed)),
                        if (farmName.isNotEmpty) Chip(label: Text(farmName)),
                        if (stage.isNotEmpty) Chip(label: Text(stage)),
                        if (sex.isNotEmpty) Chip(label: Text(sex)),
                        Chip(
                          label: Text(
                            a['dob'] != null && a['dob'].toString().isNotEmpty
                                ? _ageLabel(a['dob'])
                                : 'Age unknown',
                          ),
                        ),
                        if (lactating)
                          Chip(
                            label: const Text('Lactating'),
                            avatar: const Icon(Icons.opacity, size: 16),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Delete',
                onPressed: () async {
                  final c = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Delete animal'),
                      content: const Text(
                        'Are you sure you want to delete this animal?',
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
                  if (c == true) await _deleteAnimal(id);
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final showWideAdd = width >= 900;

    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: _selectionMode
              ? Text('${_selectedIds.length} selected')
              : const Text('Animal Central'),
          actions: [
            // Prominent Add button on wide screens, compact icon on small screens.
            if (!_selectionMode)
              if (showWideAdd)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: ElevatedButton.icon(
                    onPressed: () => _showAnimalForm(),
                    icon: const Icon(Icons.add),
                    label: const Text('Add animal'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 0,
                    ),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add animal',
                  onPressed: () => _showAnimalForm(),
                ),
            if (!_selectionMode)
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Search',
                onPressed: () => showSearch(
                  context: context,
                  delegate: _AnimalSearchDelegate(_animals),
                ),
              ),
            IconButton(
              icon: Icon(
                _selectionMode ? Icons.close : Icons.check_box_outlined,
              ),
              tooltip: _selectionMode ? 'Exit selection' : 'Selection mode',
              onPressed: () => _toggleSelectionMode(null),
            ),
            if (_selectionMode)
              IconButton(
                icon: const Icon(Icons.delete_forever),
                tooltip: 'Delete selected',
                onPressed: _performBulkDelete,
              ),
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: ElevatedButton.icon(
                  onPressed: _fetchAll,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(80, 36),
                  ),
                ),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchAll),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search by tag, name or breed',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () =>
                                    setState(() => _searchController.clear()),
                              )
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: 'Filters',
                    itemBuilder: (c) => [
                      const PopupMenuItem(
                        value: 'all',
                        child: Text('All farms'),
                      ),
                      ..._farmNames.entries.map(
                        (e) =>
                            PopupMenuItem(value: e.key, child: Text(e.value)),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'lactating',
                        checked: _showOnlyLactating,
                        child: const Text('Show only lactating'),
                      ),
                    ],
                    onSelected: (v) {
                      if (v == 'all') {
                        setState(() => _selectedFarmId = null);
                      } else if (v == 'lactating') {
                        setState(
                          () => _showOnlyLactating = !_showOnlyLactating,
                        );
                      } else {
                        setState(() => _selectedFarmId = v);
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(Icons.filter_list),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: RefreshIndicator(
          onRefresh: _fetchAll,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_error != null
                      ? _buildMessageCard(
                          icon: Icons.error_outline,
                          message: _error!,
                          color: Colors.red,
                        )
                      : _filteredAnimals.isEmpty
                      ? _buildMessageCard(
                          icon: Icons.pets,
                          message: 'No animals found.',
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth;
                            if (width >= 1100) {
                              // Desktop: master-detail two columns
                              return Row(
                                children: [
                                  Flexible(
                                    flex: 1,
                                    child: ListView.separated(
                                      itemCount: _filteredAnimals.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (context, idx) => _buildCard(
                                        _filteredAnimals[idx],
                                        true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    flex: 2,
                                    child: Card(
                                      elevation: 2,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: _selectedAnimal == null
                                          ? Center(
                                              child: Text(
                                                'Select an animal to view details',
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleMedium,
                                              ),
                                            )
                                          : _AnimalDetailPane(
                                              animal: _selectedAnimal!,
                                              farmName:
                                                  _farmNames[(_selectedAnimal!['farm_id'] ??
                                                          '')
                                                      .toString()] ??
                                                  '',
                                              onEdit: () => _showAnimalForm(
                                                animal: _selectedAnimal,
                                              ),
                                              onDelete: () => _confirmAndDelete(
                                                (_selectedAnimal!['id'] ?? '')
                                                    .toString(),
                                              ),
                                            ),
                                    ),
                                  ),
                                ],
                              );
                            } else if (width >= 600) {
                              // Tablet: grid
                              final cross = (width ~/ 320).clamp(2, 4);
                              return GridView.builder(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: cross,
                                      childAspectRatio: 3.5,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 12,
                                    ),
                                itemCount: _filteredAnimals.length,
                                itemBuilder: (c, i) =>
                                    _buildCard(_filteredAnimals[i], false),
                              );
                            } else {
                              // Mobile: single column list
                              return ListView.separated(
                                itemCount: _filteredAnimals.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, idx) =>
                                    _buildCard(_filteredAnimals[idx], false),
                              );
                            }
                          },
                        )),
          ),
        ),
        floatingActionButton: kIsWeb && MediaQuery.of(context).size.width > 900
            ? null
            : FloatingActionButton(
                onPressed: () {
                  _showAnimalForm();
                },
                tooltip: 'Add Animal',
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  Widget _buildMessageCard({
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
}

class _AnimalSearchDelegate extends SearchDelegate<String> {
  final List<Map<String, dynamic>> animals;
  _AnimalSearchDelegate(this.animals);

  @override
  List<Widget>? buildActions(BuildContext context) => [
    IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, ''),
  );

  @override
  Widget buildResults(BuildContext context) {
    final q = query.trim().toLowerCase();
    final results = animals.where((a) {
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (c, i) {
        final a = results[i];
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        return ListTile(
          title: Text('$tag — $name'),
          onTap: () => close(context, a['id']?.toString() ?? ''),
        );
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final q = query.trim().toLowerCase();
    final suggestions = q.isEmpty
        ? animals.take(10).toList()
        : animals.where((a) {
            final tag = (a['tag'] ?? '').toString().toLowerCase();
            final name = (a['name'] ?? '').toString().toLowerCase();
            final breed = (a['breed'] ?? '').toString().toLowerCase();
            return tag.contains(q) || name.contains(q) || breed.contains(q);
          }).toList();

    return ListView.builder(
      itemCount: suggestions.length,
      itemBuilder: (c, i) {
        final a = suggestions[i];
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        return ListTile(title: Text('$tag — $name'), onTap: () => query = tag);
      },
    );
  }
}

class _AnimalDetailSheet extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String farmName;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _AnimalDetailSheet({
    required this.animal,
    required this.farmName,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tag = (animal['tag'] ?? '').toString();
    final name = (animal['name'] ?? '').toString();
    final id = (animal['id'] ?? '').toString();
    final breed = (animal['breed'] ?? '').toString();
    final dob = (animal['dob'] ?? '').toString();
    final lactation = (animal['lactation'] ?? '').toString();
    final notes = (animal['notes'] ?? '').toString();
    final imageUrl = (animal['image_url'] ?? '').toString();
    final stage = (animal['stage'] ?? '').toString();
    final sex = (animal['sex'] ?? '').toString();

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  if (imageUrl.isNotEmpty)
                    SizedBox(
                      width: 160,
                      height: 160,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => CircleAvatar(
                            radius: 40,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : 'A',
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    CircleAvatar(
                      radius: 40,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : 'A',
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    '$tag — $name',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text('ID: $id'),
                  if (farmName.isNotEmpty) Text('Farm: $farmName'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                if (breed.isNotEmpty) Expanded(child: Text('Breed: $breed')),
                if (stage.isNotEmpty) Expanded(child: Text('Stage: $stage')),
              ],
            ),
            const SizedBox(height: 8),
            if (dob.isNotEmpty) Text('DOB: $dob'),
            const SizedBox(height: 8),
            if (sex.isNotEmpty) Text('Sex: $sex'),
            const SizedBox(height: 8),
            Text('Lactation: $lactation'),
            const SizedBox(height: 12),
            if (notes.isNotEmpty) ...[
              const Text(
                'Notes',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(notes),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete),
                    label: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimalDetailPane extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String farmName;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _AnimalDetailPane({
    required this.animal,
    required this.farmName,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // Large detail pane for desktop master-detail
    return Padding(
      padding: const EdgeInsets.all(16),
      child: _AnimalDetailSheet(
        animal: animal,
        farmName: farmName,
        onEdit: onEdit,
        onDelete: onDelete,
      ),
    );
  }
}
// ------------------------
// Utilities & helpers
// ------------------------

String formatDateForDisplay(String? isoDate) {
  if (isoDate == null || isoDate.isEmpty) return 'Unknown';
  try {
    final dt = DateTime.parse(isoDate);
    // Example: 2023-04-01 -> Apr 1, 2023
    return '${_monthName(dt.month)} ${dt.day}, ${dt.year}';
  } catch (_) {
    return isoDate;
  }
}

String _monthName(int m) {
  const names = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  if (m < 1 || m > 12) return '';
  return names[m - 1];
}

/// Show a platform-style confirmation dialog and return true if user confirmed.
Future<bool?> showConfirmDialog({
  required BuildContext context,
  required String title,
  required String message,
  String confirmText = 'Delete',
  String cancelText = 'Cancel',
}) {
  return showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(c, false),
          child: Text(cancelText),
        ),
        TextButton(
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirmText),
        ),
      ],
    ),
  );
}

/// Show a simple full-screen image viewer for network images.
/// Tapping the image or the close button dismisses.
Future<void> showFullImage(
  BuildContext context,
  String imageUrl, {
  String? heroTag,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (c) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          iconTheme: const IconThemeData(color: Colors.white),
        ),
        body: Center(
          child: Hero(
            tag: heroTag ?? imageUrl,
            child: InteractiveViewer(
              // allows pinch/zoom
              child: Image.network(
                imageUrl,
                fit: BoxFit.contain,
                errorBuilder: (c, e, st) {
                  return const Center(
                    child: Icon(
                      Icons.broken_image,
                      color: Colors.white,
                      size: 64,
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
      fullscreenDialog: true,
    ),
  );
}

/// Lightweight map helpers used across UI to avoid repeated null checks.
extension MapExtensions on Map<String, dynamic> {
  String str(String key, {String fallback = ''}) {
    final v = this[key];
    if (v == null) return fallback;
    return v.toString();
  }

  int? intVal(String key) {
    final v = this[key];
    if (v == null) return null;
    if (v is int) return v;
    return int.tryParse(v.toString());
  }

  double? doubleVal(String key) {
    final v = this[key];
    if (v == null) return null;
    if (v is double) return v;
    return double.tryParse(v.toString());
  }

  DateTime? date(String key) {
    final v = this[key];
    if (v == null) return null;
    try {
      return DateTime.parse(v.toString());
    } catch (_) {
      return null;
    }
  }

  bool boolFrom(String key) {
    final v = (this[key] ?? '').toString().toLowerCase();
    return v == '1' || v == 'true' || v == 'yes' || v == 'y';
  }
}

// ------------------------
// End of file
// ------------------------













/*
// lib/animal_central_with_crud.dart
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';

import 'api_service.dart';

class AnimalCentralPage extends StatefulWidget {
  final String token;
  const AnimalCentralPage({super.key, required this.token});

  @override
  State<AnimalCentralPage> createState() => _AnimalCentralPageState();
}

class _AnimalCentralPageState extends State<AnimalCentralPage> {
  late final ApiService _apiService;

  List<Map<String, dynamic>> _animals = [];
  Map<String, String> _farmNames = {}; // farmId -> farmName
  List<String> _userFarmIds = [];

  bool _loading = true;
  String? _error;

  // UI state
  final TextEditingController _searchController = TextEditingController();
  String? _selectedFarmId;
  bool _showOnlyLactating = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  Map<String, dynamic>? _selectedAnimal;

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAll();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _fetchAll() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals = [];
      _farmNames = {};
      _selectedIds.clear();
      _selectionMode = false;
      _selectedAnimal = null;
      _userFarmIds = [];
    });

    try {
      final farmIds = await _api_service_getUserFarmIds();
      _userFarmIds = farmIds;
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }

      final farmsMap = await _apiService.fetchFarmsByIds(farmIds);
      setState(() => _farmNames = farmsMap);

      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      // Normalize animals: support both 'dob' and 'birth_date' keys by mapping to 'dob' for UI
      final normalized = animals.map((a) {
        final m = Map<String, dynamic>.from(a);
        if ((m['dob'] == null || m['dob'].toString().isEmpty) &&
            (m['birth_date'] != null)) {
          m['dob'] = m['birth_date'];
        }
        return m;
      }).toList();

      setState(() {
        _animals = normalized;
        _loading = false;
      });
    } catch (e) {
      debugPrint('fetchAnimals error: $e');
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

  List<Map<String, dynamic>> get _filteredAnimals {
    final q = _searchController.text.trim().toLowerCase();
    return _animals.where((a) {
      if (_selectedFarmId != null && _selectedFarmId!.isNotEmpty) {
        if ((a['farm_id'] ?? '').toString() != _selectedFarmId) return false;
      }
      if (_showOnlyLactating) {
        final lact =
            (a['lactation'] ??
                    a['lactation_status'] ??
                    a['lactation_flag'] ??
                    '')
                .toString()
                .toLowerCase();
        if (!(lact == 'yes' || lact == 'true' || lact == '1' || lact == 'y')) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();
  }

  int _calculateAgeInMonths(String dob) {
    try {
      final d = DateTime.parse(dob);
      final now = DateTime.now();
      return (now.year - d.year) * 12 + (now.month - d.month);
    } catch (_) {
      return -1;
    }
  }

  String _ageLabel(String dob) {
    final months = _calculateAgeInMonths(dob);
    if (months < 0) return 'Unknown age';
    final y = months ~/ 12;
    final m = months % 12;
    if (y > 0) return '$y yr${y > 1 ? 's' : ''}${m > 0 ? ' $m mo' : ''}';
    return '$m mo';
  }

  Future<void> _deleteAnimal(String id, {bool showUndo = true}) async {
    final idx = _animals.indexWhere((e) => (e['id'] ?? '').toString() == id);
    if (idx == -1) return;

    final backup = _animals[idx];
    setState(() => _animals.removeAt(idx)); // optimistic

    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    if (showUndo) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Animal deleted'),
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () {
              setState(() => _animals.insert(idx, backup));
            },
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }

    try {
      final ok = await _apiService.deleteAnimal(id);
      if (!ok) {
        if (!_animals.contains(backup)) {
          setState(() => _animals.insert(idx, backup));
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete animal.')),
        );
      }
    } catch (e) {
      if (!_animals.contains(backup)) {
        setState(() => _animals.insert(idx, backup));
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to delete animal.')));
      debugPrint('delete animal error: $e');
    }
  }

  void _toggleSelectionMode([bool? enable]) {
    setState(() {
      _selectionMode = enable ?? !_selectionMode;
      if (!_selectionMode) _selectedIds.clear();
    });
  }

  void _onItemTap(Map<String, dynamic> a, bool wideLayout) {
    final id = (a['id'] ?? '').toString();
    if (_selectionMode) {
      setState(() {
        if (_selectedIds.contains(id)) {
          _selectedIds.remove(id);
        } else {
          _selectedIds.add(id);
        }
      });
      return;
    }

    if (wideLayout) {
      setState(() => _selectedAnimal = a);
      return;
    }

    // show details bottom sheet for narrow screens
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.25,
            maxChildSize: 0.95,
            builder: (_, controller) {
              return _AnimalDetailSheet(
                animal: a,
                farmName: _farmNames[(a['farm_id'] ?? '').toString()] ?? '',
                onEdit: () {
                  Navigator.pop(context);
                  _showAnimalForm(animal: a);
                },
                onDelete: () {
                  Navigator.pop(context);
                  _confirmAndDelete((a['id'] ?? '').toString());
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmAndDelete(String id) async {
    final c = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete animal'),
        content: const Text('Are you sure you want to delete this animal?'),
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
    if (c == true) await _deleteAnimal(id);
  }

  Future<void> _performBulkDelete() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete selected animals'),
        content: Text('Delete ${_selectedIds.length} selected animals?'),
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
    if (confirmed != true) return;

    final ids = _selectedIds.toList();
    for (final id in ids) {
      await _deleteAnimal(id, showUndo: false);
    }
    _toggleSelectionMode(false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${ids.length} animals deleted')));
  }

  Widget _initialsAvatar(String name) {
    final label = name.isNotEmpty ? name[0].toUpperCase() : 'A';
    return CircleAvatar(
      radius: 36,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontSize: 24,
        ),
      ),
    );
  }

  Future<void> _showAnimalForm({Map<String, dynamic>? animal}) async {
    final isEdit = animal != null;
    final tagCtl = TextEditingController(
      text: animal != null ? (animal['tag'] ?? '').toString() : '',
    );
    final nameCtl = TextEditingController(
      text: animal != null ? (animal['name'] ?? '').toString() : '',
    );
    final breedCtl = TextEditingController(
      text: animal != null ? (animal['breed'] ?? '').toString() : '',
    );
    final dobCtl = TextEditingController(
      text: animal != null ? (animal['dob'] ?? '').toString() : '',
    );
    final notesCtl = TextEditingController(
      text: animal != null ? (animal['notes'] ?? '').toString() : '',
    );
    final imageCtl = TextEditingController(
      text: animal != null ? (animal['image_url'] ?? '').toString() : '',
    );
    String? selectedFarm = animal != null
        ? (animal['farm_id'] ?? '').toString()
        : (_userFarmIds.isNotEmpty ? _userFarmIds.first : null);
    bool lactating = false;
    final lactVal = (animal?['lactation'] ?? '').toString().toLowerCase();
    if (lactVal == 'yes' || lactVal == 'true' || lactVal == '1') {
      lactating = true;
    }

    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: MediaQuery.of(context).viewInsets,
        child: DraggableScrollableSheet(
          initialChildSize: 0.8,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return SingleChildScrollView(
              controller: controller,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      isEdit ? 'Edit animal' : 'Add animal',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Form(
                      key: formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: tagCtl,
                            decoration: const InputDecoration(labelText: 'Tag'),
                            validator: (v) =>
                                (v ?? '').trim().isEmpty ? 'Required' : null,
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: nameCtl,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: breedCtl,
                            decoration: const InputDecoration(
                              labelText: 'Breed',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: dobCtl,
                            decoration: const InputDecoration(
                              labelText: 'DOB (YYYY-MM-DD)',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: imageCtl,
                            decoration: const InputDecoration(
                              labelText: 'Image URL',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: notesCtl,
                            decoration: const InputDecoration(
                              labelText: 'Notes',
                            ),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String?>(
                                  value: selectedFarm,
                                  items: _userFarmIds
                                      .map(
                                        (f) => DropdownMenuItem(
                                          value: f,
                                          child: Text(_farmNames[f] ?? f),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) => selectedFarm = v,
                                  decoration: const InputDecoration(
                                    labelText: 'Farm',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                children: [
                                  const Text('Lactating'),
                                  StatefulBuilder(
                                    builder: (c, sset) {
                                      return Checkbox(
                                        value: lactating,
                                        onChanged: (v) =>
                                            sset(() => lactating = v ?? false),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: () async {
                                    if (!formKey.currentState!.validate()) {
                                      return;
                                    }
                                    final payload = <String, dynamic>{
                                      'tag': tagCtl.text.trim(),
                                      'name': nameCtl.text.trim().isEmpty
                                          ? null
                                          : nameCtl.text.trim(),
                                      'breed': breedCtl.text.trim().isEmpty
                                          ? null
                                          : breedCtl.text.trim(),
                                      // use birth_date to match schema
                                      'birth_date': dobCtl.text.trim().isEmpty
                                          ? null
                                          : dobCtl.text.trim(),
                                      'notes': notesCtl.text.trim().isEmpty
                                          ? null
                                          : notesCtl.text.trim(),
                                      'image_url': imageCtl.text.trim().isEmpty
                                          ? null
                                          : imageCtl.text.trim(),
                                      'farm_id': selectedFarm,
                                      'lactation': lactating ? 'yes' : 'no',
                                    };

                                    Navigator.pop(
                                      context,
                                    ); // close sheet before network

                                    if (isEdit) {
                                      final id = (animal['id'] ?? '')
                                          .toString();
                                      final updated = await _apiService
                                          .updateAnimal(id, payload);
                                      if (updated != null) {
                                        // normalize
                                        if ((updated['dob'] == null ||
                                                updated['dob']
                                                    .toString()
                                                    .isEmpty) &&
                                            updated['birth_date'] != null) {
                                          updated['dob'] =
                                              updated['birth_date'];
                                        }
                                        final idx = _animals.indexWhere(
                                          (e) =>
                                              (e['id'] ?? '').toString() == id,
                                        );
                                        if (idx != -1) {
                                          setState(
                                            () => _animals[idx] = updated,
                                          );
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('Animal updated'),
                                            ),
                                          );
                                        } else {
                                          await _fetchAll();
                                        }
                                      } else {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Failed to update animal',
                                            ),
                                          ),
                                        );
                                      }
                                    } else {
                                      final created = await _apiService
                                          .createAnimal(payload);
                                      if (created != null) {
                                        if ((created['dob'] == null ||
                                                created['dob']
                                                    .toString()
                                                    .isEmpty) &&
                                            created['birth_date'] != null) {
                                          created['dob'] =
                                              created['birth_date'];
                                        }
                                        setState(
                                          () => _animals.insert(0, created),
                                        );
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('Animal created'),
                                          ),
                                        );
                                      } else {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Failed to create animal',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  child: Text(
                                    isEdit ? 'Save changes' : 'Create',
                                  ),
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

    // dispose controllers
    tagCtl.dispose();
    nameCtl.dispose();
    breedCtl.dispose();
    dobCtl.dispose();
    notesCtl.dispose();
    imageCtl.dispose();
  }

  Widget _buildCard(Map<String, dynamic> a, bool wideLayout) {
    final tag = (a['tag'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    final breed = (a['breed'] ?? '').toString();
    final id = (a['id'] ?? '').toString();
    final farmId = (a['farm_id'] ?? '').toString();
    final farmName = _farmNames[farmId] ?? '';
    final imageUrl = (a['image_url'] ?? '').toString();
    final lact = (a['lactation'] ?? '').toString().toLowerCase();
    final lactating = (lact == 'yes' || lact == 'true' || lact == '1');

    final selected = _selectedIds.contains(id);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _onItemTap(a, wideLayout),
        onLongPress: () => _toggleSelectionMode(true),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: imageUrl.isNotEmpty
                    ? Image.network(
                        imageUrl,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        loadingBuilder: (c, child, progress) {
                          if (progress == null) return child;
                          return SizedBox(
                            width: 72,
                            height: 72,
                            child: Center(
                              child: CircularProgressIndicator(
                                value: progress.expectedTotalBytes != null
                                    ? progress.cumulativeBytesLoaded /
                                          (progress.expectedTotalBytes ?? 1)
                                    : null,
                              ),
                            ),
                          );
                        },
                        errorBuilder: (c, e, st) => _initialsAvatar(name),
                      )
                    : _initialsAvatar(name),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$tag — $name',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (_selectionMode)
                          Checkbox(
                            value: selected,
                            onChanged: (_) => _onItemTap(a, wideLayout),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (breed.isNotEmpty) Chip(label: Text(breed)),
                        if (farmName.isNotEmpty) Chip(label: Text(farmName)),
                        Chip(
                          label: Text(
                            a['dob'] != null && a['dob'].toString().isNotEmpty
                                ? _ageLabel(a['dob'])
                                : 'Age unknown',
                          ),
                        ),
                        if (lactating)
                          Chip(
                            label: const Text('Lactating'),
                            avatar: const Icon(Icons.opacity, size: 16),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Delete',
                onPressed: () async {
                  final c = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Delete animal'),
                      content: const Text(
                        'Are you sure you want to delete this animal?',
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
                  if (c == true) await _deleteAnimal(id);
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final showWideAdd = width >= 900;

    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: _selectionMode
              ? Text('${_selectedIds.length} selected')
              : const Text('Animal Central'),
          actions: [
            // Prominent Add button on wide screens, compact icon on small screens.
            if (!_selectionMode)
              if (showWideAdd)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8.0),
                  child: ElevatedButton.icon(
                    onPressed: () => _showAnimalForm(),
                    icon: const Icon(Icons.add),
                    label: const Text('Add animal'),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                      elevation: 0,
                    ),
                  ),
                )
              else
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: 'Add animal',
                  onPressed: () => _showAnimalForm(),
                ),

            if (!_selectionMode)
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Search',
                onPressed: () => showSearch(
                  context: context,
                  delegate: _AnimalSearchDelegate(_animals),
                ),
              ),
            IconButton(
              icon: Icon(
                _selectionMode ? Icons.close : Icons.check_box_outlined,
              ),
              tooltip: _selectionMode ? 'Exit selection' : 'Selection mode',
              onPressed: () => _toggleSelectionMode(null),
            ),
            if (_selectionMode)
              IconButton(
                icon: const Icon(Icons.delete_forever),
                tooltip: 'Delete selected',
                onPressed: _performBulkDelete,
              ),
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: ElevatedButton.icon(
                  onPressed: _fetchAll,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(80, 36),
                  ),
                ),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchAll),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search by tag, name or breed',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () =>
                                    setState(() => _searchController.clear()),
                              )
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: 'Filters',
                    itemBuilder: (c) => [
                      const PopupMenuItem(
                        value: 'all',
                        child: Text('All farms'),
                      ),
                      ..._farmNames.entries.map(
                        (e) =>
                            PopupMenuItem(value: e.key, child: Text(e.value)),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'lactating',
                        checked: _showOnlyLactating,
                        child: const Text('Show only lactating'),
                      ),
                    ],
                    onSelected: (v) {
                      if (v == 'all') {
                        setState(() => _selectedFarmId = null);
                      } else if (v == 'lactating') {
                        setState(
                          () => _showOnlyLactating = !_showOnlyLactating,
                        );
                      } else {
                        setState(() => _selectedFarmId = v);
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(Icons.filter_list),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: RefreshIndicator(
          onRefresh: _fetchAll,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_error != null
                      ? _buildMessageCard(
                          icon: Icons.error_outline,
                          message: _error!,
                          color: Colors.red,
                        )
                      : _filteredAnimals.isEmpty
                      ? _buildMessageCard(
                          icon: Icons.pets,
                          message: 'No animals found.',
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth;
                            if (width >= 1100) {
                              // Desktop: master-detail two columns
                              return Row(
                                children: [
                                  Flexible(
                                    flex: 1,
                                    child: ListView.separated(
                                      itemCount: _filteredAnimals.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (context, idx) => _buildCard(
                                        _filteredAnimals[idx],
                                        true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    flex: 2,
                                    child: Card(
                                      elevation: 2,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: _selectedAnimal == null
                                          ? Center(
                                              child: Text(
                                                'Select an animal to view details',
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleMedium,
                                              ),
                                            )
                                          : _AnimalDetailPane(
                                              animal: _selectedAnimal!,
                                              farmName:
                                                  _farmNames[(_selectedAnimal!['farm_id'] ??
                                                          '')
                                                      .toString()] ??
                                                  '',
                                              onEdit: () => _showAnimalForm(
                                                animal: _selectedAnimal,
                                              ),
                                              onDelete: () => _confirmAndDelete(
                                                (_selectedAnimal!['id'] ?? '')
                                                    .toString(),
                                              ),
                                            ),
                                    ),
                                  ),
                                ],
                              );
                            } else if (width >= 600) {
                              // Tablet: grid
                              final cross = (width ~/ 320).clamp(2, 4);
                              return GridView.builder(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: cross,
                                      childAspectRatio: 3.5,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 12,
                                    ),
                                itemCount: _filteredAnimals.length,
                                itemBuilder: (c, i) =>
                                    _buildCard(_filteredAnimals[i], false),
                              );
                            } else {
                              // Mobile: single column list
                              return ListView.separated(
                                itemCount: _filteredAnimals.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, idx) =>
                                    _buildCard(_filteredAnimals[idx], false),
                              );
                            }
                          },
                        )),
          ),
        ),
        floatingActionButton: kIsWeb && MediaQuery.of(context).size.width > 900
            ? null
            : FloatingActionButton(
                onPressed: () {
                  _showAnimalForm();
                },
                tooltip: 'Add Animal',
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  Widget _buildMessageCard({
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
}

class _AnimalSearchDelegate extends SearchDelegate<String> {
  final List<Map<String, dynamic>> animals;
  _AnimalSearchDelegate(this.animals);

  @override
  List<Widget>? buildActions(BuildContext context) => [
    IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, ''),
  );

  @override
  Widget buildResults(BuildContext context) {
    final q = query.trim().toLowerCase();
    final results = animals.where((a) {
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (c, i) {
        final a = results[i];
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        return ListTile(
          title: Text('$tag — $name'),
          onTap: () => close(context, a['id']?.toString() ?? ''),
        );
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final q = query.trim().toLowerCase();
    final suggestions = q.isEmpty
        ? animals.take(10).toList()
        : animals.where((a) {
            final tag = (a['tag'] ?? '').toString().toLowerCase();
            final name = (a['name'] ?? '').toString().toLowerCase();
            final breed = (a['breed'] ?? '').toString().toLowerCase();
            return tag.contains(q) || name.contains(q) || breed.contains(q);
          }).toList();

    return ListView.builder(
      itemCount: suggestions.length,
      itemBuilder: (c, i) {
        final a = suggestions[i];
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        return ListTile(title: Text('$tag — $name'), onTap: () => query = tag);
      },
    );
  }
}

class _AnimalDetailSheet extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String farmName;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _AnimalDetailSheet({
    required this.animal,
    required this.farmName,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tag = (animal['tag'] ?? '').toString();
    final name = (animal['name'] ?? '').toString();
    final id = (animal['id'] ?? '').toString();
    final breed = (animal['breed'] ?? '').toString();
    final dob = (animal['dob'] ?? '').toString();
    final lactation = (animal['lactation'] ?? '').toString();
    final notes = (animal['notes'] ?? '').toString();
    final imageUrl = (animal['image_url'] ?? '').toString();

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  if (imageUrl.isNotEmpty)
                    SizedBox(
                      width: 160,
                      height: 160,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => CircleAvatar(
                            radius: 40,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : 'A',
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    CircleAvatar(
                      radius: 40,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : 'A',
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    '$tag — $name',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text('ID: $id'),
                  if (farmName.isNotEmpty) Text('Farm: $farmName'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('Breed: $breed'),
            const SizedBox(height: 8),
            if (dob.isNotEmpty) Text('DOB: $dob'),
            const SizedBox(height: 8),
            Text('Lactation: $lactation'),
            const SizedBox(height: 12),
            if (notes.isNotEmpty) ...[
              const Text(
                'Notes',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(notes),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete),
                    label: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimalDetailPane extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String farmName;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _AnimalDetailPane({
    required this.animal,
    required this.farmName,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // Large detail pane for desktop master-detail
    return Padding(
      padding: const EdgeInsets.all(16),
      child: _AnimalDetailSheet(
        animal: animal,
        farmName: farmName,
        onEdit: onEdit,
        onDelete: onDelete,
      ),
    );
  }
}
*/
















/*the best
// animal_central_with_crud.dart 
// Full updated AnimalCentralPage with Add / Edit / Delete / Create support.
// This file expects you to have `supabase_config.dart` (SUPABASE_URL, SUPABASE_ANON_KEY)
// and your existing `api_service.dart` (ApiService class) in the project.
// It adds an extension with CRUD helpers that use the same ApiService token and integrates
// a complete, responsive UI for listing, searching, creating, editing, and deleting animals.

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

import 'supabase_config.dart';
import 'api_service.dart';

// --- ApiService extension: animal CRUD helpers ---
extension ApiServiceAnimalCrud on ApiService {
  Future<Map<String, dynamic>?> createAnimal(
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/animals';
    try {
      final resp = await http.post(
        Uri.parse(url),
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
          'Prefer': 'return=representation',
        },
        body: json.encode(payload),
      );
      debugPrint('createAnimal status: ${resp.statusCode} body: ${resp.body}');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final List data = json.decode(resp.body);
        if (data.isNotEmpty) {
          return Map<String, dynamic>.from(data.first as Map);
        }
      }
    } catch (e) {
      debugPrint('createAnimal error: $e');
    }
    return null;
  }

  Future<Map<String, dynamic>?> updateAnimal(
    String id,
    Map<String, dynamic> payload,
  ) async {
    final url = '$SUPABASE_URL/rest/v1/animals?id=eq.$id';
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
      debugPrint('updateAnimal status: ${resp.statusCode} body: ${resp.body}');
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        final List data = json.decode(resp.body);
        if (data.isNotEmpty) {
          return Map<String, dynamic>.from(data.first as Map);
        }
      }
    } catch (e) {
      debugPrint('updateAnimal error: $e');
    }
    return null;
  }

  Future<bool> deleteAnimal(String id) async {
    final url = '$SUPABASE_URL/rest/v1/animals?id=eq.$id';
    try {
      final resp = await http.delete(
        Uri.parse(url),
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': 'Bearer $token',
          'Accept': 'application/json',
        },
      );
      debugPrint('deleteAnimal status: ${resp.statusCode} body: ${resp.body}');
      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      debugPrint('deleteAnimal error: $e');
      return false;
    }
  }
}

// --- AnimalCentralPage ---
class AnimalCentralPage extends StatefulWidget {
  final String token;
  const AnimalCentralPage({super.key, required this.token});

  @override
  State<AnimalCentralPage> createState() => _AnimalCentralPageState();
}

class _AnimalCentralPageState extends State<AnimalCentralPage> {
  late final ApiService _apiService;

  List<Map<String, dynamic>> _animals = [];
  Map<String, String> _farmNames = {}; // farmId -> farmName
  List<String> _userFarmIds = [];

  bool _loading = true;
  String? _error;

  // UI state
  final TextEditingController _searchController = TextEditingController();
  String? _selectedFarmId;
  bool _showOnlyLactating = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  Map<String, dynamic>? _selectedAnimal;

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAll();
  }

  Future<void> _fetchAll() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals = [];
      _farmNames = {};
      _selectedIds.clear();
      _selectionMode = false;
      _selectedAnimal = null;
      _userFarmIds = [];
    });

    try {
      final farmIds = await _api_service_getUserFarmIds();
      _userFarmIds = farmIds;
      if (farmIds.isEmpty) {
        setState(() {
          _error = 'No farms linked to your account.';
          _loading = false;
        });
        return;
      }

      await _fetchFarmNames(farmIds);
      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      // Normalize animals: support both 'dob' and 'birth_date' keys by mapping to 'dob' for UI
      final normalized = animals.map((a) {
        final m = Map<String, dynamic>.from(a);
        if ((m['dob'] == null || m['dob'].toString().isEmpty) &&
            (m['birth_date'] != null)) {
          m['dob'] = m['birth_date'];
        }
        return m;
      }).toList();

      setState(() {
        _animals = normalized;
        _loading = false;
      });
    } catch (e) {
      debugPrint('fetchAnimals error: $e');
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

  Future<void> _fetchFarmNames(List<String> farmIds) async {
    if (farmIds.isEmpty) return;
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url =
        '$SUPABASE_URL/rest/v1/farms?select=id,name&order=id&id=in.$encodedList';
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ${widget.token}',
        'Accept': 'application/json',
      },
    );
    if (resp.statusCode != 200) {
      debugPrint('fetchFarmNames failed: ${resp.statusCode} ${resp.body}');
      return;
    }
    final List data = json.decode(resp.body);
    setState(() {
      for (final f in data) {
        final id = (f['id'] ?? '').toString();
        final name = (f['name'] ?? '').toString();
        if (id.isNotEmpty) _farmNames[id] = name;
      }
    });
  }

  List<Map<String, dynamic>> get _filteredAnimals {
    final q = _searchController.text.trim().toLowerCase();
    return _animals.where((a) {
      if (_selectedFarmId != null && _selectedFarmId!.isNotEmpty) {
        if ((a['farm_id'] ?? '').toString() != _selectedFarmId) return false;
      }
      if (_showOnlyLactating) {
        final lact =
            (a['lactation'] ??
                    a['lactation_status'] ??
                    a['lactation_flag'] ??
                    a['lactation'] ??
                    a['lactation'])
                .toString()
                .toLowerCase();
        if (!(lact == 'yes' || lact == 'true' || lact == '1' || lact == 'y')) {
          return false;
        }
      }
      if (q.isEmpty) return true;
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();
  }

  int _calculateAgeInMonths(String dob) {
    try {
      final d = DateTime.parse(dob);
      final now = DateTime.now();
      return (now.year - d.year) * 12 + (now.month - d.month);
    } catch (_) {
      return -1;
    }
  }

  String _ageLabel(String dob) {
    final months = _calculateAgeInMonths(dob);
    if (months < 0) return 'Unknown age';
    final y = months ~/ 12;
    final m = months % 12;
    if (y > 0) return '$y yr${y > 1 ? 's' : ''}${m > 0 ? ' $m mo' : ''}';
    return '$m mo';
  }

  Future<void> _deleteAnimal(String id, {bool showUndo = true}) async {
    final idx = _animals.indexWhere((e) => (e['id'] ?? '').toString() == id);
    if (idx == -1) return;

    final backup = _animals[idx];
    setState(() => _animals.removeAt(idx)); // optimistic

    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    if (showUndo) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Animal deleted'),
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () {
              setState(() => _animals.insert(idx, backup));
            },
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }

    try {
      final ok = await _apiService.deleteAnimal(id);
      if (!ok) {
        if (!_animals.contains(backup)) {
          setState(() => _animals.insert(idx, backup));
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to delete animal.')),
        );
      }
    } catch (e) {
      if (!_animals.contains(backup)) {
        setState(() => _animals.insert(idx, backup));
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to delete animal.')));
      debugPrint('delete animal error: $e');
    }
  }

  void _toggleSelectionMode([bool? enable]) {
    setState(() {
      _selectionMode = enable ?? !_selectionMode;
      if (!_selectionMode) _selectedIds.clear();
    });
  }

  void _onItemTap(Map<String, dynamic> a, bool wideLayout) {
    final id = (a['id'] ?? '').toString();
    if (_selectionMode) {
      setState(() {
        if (_selectedIds.contains(id)) {
          _selectedIds.remove(id);
        } else {
          _selectedIds.add(id);
        }
      });
      return;
    }

    if (wideLayout) {
      setState(() => _selectedAnimal = a);
      return;
    }

    // show details bottom sheet for narrow screens
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.25,
            maxChildSize: 0.95,
            builder: (_, controller) {
              return _AnimalDetailSheet(
                animal: a,
                farmName: _farmNames[(a['farm_id'] ?? '').toString()] ?? '',
                onEdit: () {
                  Navigator.pop(context);
                  _showAnimalForm(animal: a);
                },
                onDelete: () {
                  Navigator.pop(context);
                  _confirmAndDelete((a['id'] ?? '').toString());
                },
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _confirmAndDelete(String id) async {
    final c = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete animal'),
        content: const Text('Are you sure you want to delete this animal?'),
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
    if (c == true) await _deleteAnimal(id);
  }

  Future<void> _performBulkDelete() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete selected animals'),
        content: Text('Delete ${_selectedIds.length} selected animals?'),
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
    if (confirmed != true) return;

    final ids = _selectedIds.toList();
    for (final id in ids) {
      await _deleteAnimal(id, showUndo: false);
    }
    _toggleSelectionMode(false);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('${ids.length} animals deleted')));
  }

  Widget _initialsAvatar(String name) {
    final label = name.isNotEmpty ? name[0].toUpperCase() : 'A';
    return CircleAvatar(
      radius: 36,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontSize: 24,
        ),
      ),
    );
  }

  Future<void> _showAnimalForm({Map<String, dynamic>? animal}) async {
    final isEdit = animal != null;
    final tagCtl = TextEditingController(
      text: animal != null ? (animal['tag'] ?? '').toString() : '',
    );
    final nameCtl = TextEditingController(
      text: animal != null ? (animal['name'] ?? '').toString() : '',
    );
    final breedCtl = TextEditingController(
      text: animal != null ? (animal['breed'] ?? '').toString() : '',
    );
    final dobCtl = TextEditingController(
      text: animal != null ? (animal['dob'] ?? '').toString() : '',
    );
    final notesCtl = TextEditingController(
      text: animal != null ? (animal['notes'] ?? '').toString() : '',
    );
    final imageCtl = TextEditingController(
      text: animal != null ? (animal['image_url'] ?? '').toString() : '',
    );
    String? selectedFarm = animal != null
        ? (animal['farm_id'] ?? '').toString()
        : (_userFarmIds.isNotEmpty ? _userFarmIds.first : null);
    bool lactating = false;
    final lactVal = (animal?['lactation'] ?? '').toString().toLowerCase();
    if (lactVal == 'yes' || lactVal == 'true' || lactVal == '1') {
      lactating = true;
    }

    final formKey = GlobalKey<FormState>();

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
        padding: MediaQuery.of(context).viewInsets,
        child: DraggableScrollableSheet(
          initialChildSize: 0.8,
          minChildSize: 0.4,
          maxChildSize: 0.95,
          builder: (_, controller) {
            return SingleChildScrollView(
              controller: controller,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text(
                      isEdit ? 'Edit animal' : 'Add animal',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 12),
                    Form(
                      key: formKey,
                      child: Column(
                        children: [
                          TextFormField(
                            controller: tagCtl,
                            decoration: const InputDecoration(labelText: 'Tag'),
                            validator: (v) =>
                                (v ?? '').trim().isEmpty ? 'Required' : null,
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: nameCtl,
                            decoration: const InputDecoration(
                              labelText: 'Name',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: breedCtl,
                            decoration: const InputDecoration(
                              labelText: 'Breed',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: dobCtl,
                            decoration: const InputDecoration(
                              labelText: 'DOB (YYYY-MM-DD)',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: imageCtl,
                            decoration: const InputDecoration(
                              labelText: 'Image URL',
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextFormField(
                            controller: notesCtl,
                            decoration: const InputDecoration(
                              labelText: 'Notes',
                            ),
                            maxLines: 3,
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<String?>(
                                  initialValue: selectedFarm,
                                  items: _userFarmIds
                                      .map(
                                        (f) => DropdownMenuItem(
                                          value: f,
                                          child: Text(_farmNames[f] ?? f),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) => selectedFarm = v,
                                  decoration: const InputDecoration(
                                    labelText: 'Farm',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Column(
                                children: [
                                  const Text('Lactating'),
                                  StatefulBuilder(
                                    builder: (c, sset) {
                                      return Checkbox(
                                        value: lactating,
                                        onChanged: (v) =>
                                            sset(() => lactating = v ?? false),
                                      );
                                    },
                                  ),
                                ],
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                child: ElevatedButton(
                                  onPressed: () async {
                                    if (!formKey.currentState!.validate()) {
                                      return;
                                    }
                                    final payload = <String, dynamic>{
                                      'tag': tagCtl.text.trim(),
                                      'name': nameCtl.text.trim().isEmpty
                                          ? null
                                          : nameCtl.text.trim(),
                                      'breed': breedCtl.text.trim().isEmpty
                                          ? null
                                          : breedCtl.text.trim(),
                                      // use birth_date to match schema
                                      'birth_date': dobCtl.text.trim().isEmpty
                                          ? null
                                          : dobCtl.text.trim(),
                                      'notes': notesCtl.text.trim().isEmpty
                                          ? null
                                          : notesCtl.text.trim(),
                                      'image_url': imageCtl.text.trim().isEmpty
                                          ? null
                                          : imageCtl.text.trim(),
                                      'farm_id': selectedFarm,
                                      'lactation': lactating ? 'yes' : 'no',
                                    };

                                    Navigator.pop(
                                      context,
                                    ); // close sheet before network

                                    if (isEdit) {
                                      final id = (animal['id'] ?? '')
                                          .toString();
                                      final updated = await _apiService
                                          .updateAnimal(id, payload);
                                      if (updated != null) {
                                        // normalize
                                        if ((updated['dob'] == null ||
                                                updated['dob']
                                                    .toString()
                                                    .isEmpty) &&
                                            updated['birth_date'] != null) {
                                          updated['dob'] =
                                              updated['birth_date'];
                                        }
                                        final idx = _animals.indexWhere(
                                          (e) =>
                                              (e['id'] ?? '').toString() == id,
                                        );
                                        if (idx != -1) {
                                          setState(
                                            () => _animals[idx] = updated,
                                          );
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            const SnackBar(
                                              content: Text('Animal updated'),
                                            ),
                                          );
                                        } else {
                                          await _fetchAll();
                                        }
                                      } else {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Failed to update animal',
                                            ),
                                          ),
                                        );
                                      }
                                    } else {
                                      final created = await _apiService
                                          .createAnimal(payload);
                                      if (created != null) {
                                        if ((created['dob'] == null ||
                                                created['dob']
                                                    .toString()
                                                    .isEmpty) &&
                                            created['birth_date'] != null) {
                                          created['dob'] =
                                              created['birth_date'];
                                        }
                                        setState(
                                          () => _animals.insert(0, created),
                                        );
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text('Animal created'),
                                          ),
                                        );
                                      } else {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Failed to create animal',
                                            ),
                                          ),
                                        );
                                      }
                                    }
                                  },
                                  child: Text(
                                    isEdit ? 'Save changes' : 'Create',
                                  ),
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

    // dispose controllers
    tagCtl.dispose();
    nameCtl.dispose();
    breedCtl.dispose();
    dobCtl.dispose();
    notesCtl.dispose();
    imageCtl.dispose();
  }

  Widget _buildCard(Map<String, dynamic> a, bool wideLayout) {
    final tag = (a['tag'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    final breed = (a['breed'] ?? '').toString();
    final id = (a['id'] ?? '').toString();
    final farmId = (a['farm_id'] ?? '').toString();
    final farmName = _farmNames[farmId] ?? '';
    final imageUrl = (a['image_url'] ?? '').toString();
    final lact = (a['lactation'] ?? '').toString().toLowerCase();
    final lactating = (lact == 'yes' || lact == 'true' || lact == '1');

    final selected = _selectedIds.contains(id);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _onItemTap(a, wideLayout),
        onLongPress: () => _toggleSelectionMode(true),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: imageUrl.isNotEmpty
                    ? Image.network(
                        imageUrl,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        loadingBuilder: (c, child, progress) {
                          if (progress == null) return child;
                          return SizedBox(
                            width: 72,
                            height: 72,
                            child: Center(
                              child: CircularProgressIndicator(
                                value: progress.expectedTotalBytes != null
                                    ? progress.cumulativeBytesLoaded /
                                          (progress.expectedTotalBytes ?? 1)
                                    : null,
                              ),
                            ),
                          );
                        },
                        errorBuilder: (c, e, st) => _initialsAvatar(name),
                      )
                    : _initialsAvatar(name),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '$tag — $name',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ),
                        if (_selectionMode)
                          Checkbox(
                            value: selected,
                            onChanged: (_) => _onItemTap(a, wideLayout),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        if (breed.isNotEmpty) Chip(label: Text(breed)),
                        if (farmName.isNotEmpty) Chip(label: Text(farmName)),
                        Chip(
                          label: Text(
                            a['dob'] != null && a['dob'].toString().isNotEmpty
                                ? _ageLabel(a['dob'])
                                : 'Age unknown',
                          ),
                        ),
                        if (lactating)
                          Chip(
                            label: const Text('Lactating'),
                            avatar: const Icon(Icons.opacity, size: 16),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Delete',
                onPressed: () async {
                  final c = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Delete animal'),
                      content: const Text(
                        'Are you sure you want to delete this animal?',
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
                  if (c == true) await _deleteAnimal(id);
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: _selectionMode
              ? Text('${_selectedIds.length} selected')
              : const Text('Animal Central'),
          actions: [
            if (!_selectionMode)
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Search',
                onPressed: () => showSearch(
                  context: context,
                  delegate: _AnimalSearchDelegate(_animals),
                ),
              ),
            IconButton(
              icon: Icon(
                _selectionMode ? Icons.close : Icons.check_box_outlined,
              ),
              tooltip: _selectionMode ? 'Exit selection' : 'Selection mode',
              onPressed: () => _toggleSelectionMode(null),
            ),
            if (_selectionMode)
              IconButton(
                icon: const Icon(Icons.delete_forever),
                tooltip: 'Delete selected',
                onPressed: _performBulkDelete,
              ),
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: ElevatedButton.icon(
                  onPressed: _fetchAll,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(80, 36),
                  ),
                ),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchAll),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search by tag, name or breed',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(
                                icon: const Icon(Icons.clear),
                                onPressed: () =>
                                    setState(() => _searchController.clear()),
                              )
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: 'Filters',
                    itemBuilder: (c) => [
                      const PopupMenuItem(
                        value: 'all',
                        child: Text('All farms'),
                      ),
                      ..._farmNames.entries.map(
                        (e) =>
                            PopupMenuItem(value: e.key, child: Text(e.value)),
                      ),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(
                        value: 'lactating',
                        checked: _showOnlyLactating,
                        child: const Text('Show only lactating'),
                      ),
                    ],
                    onSelected: (v) {
                      if (v == 'all') {
                        setState(() => _selectedFarmId = null);
                      } else if (v == 'lactating')
                        setState(
                          () => _showOnlyLactating = !_showOnlyLactating,
                        );
                      else
                        setState(() => _selectedFarmId = v);
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 12),
                      child: Icon(Icons.filter_list),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: RefreshIndicator(
          onRefresh: _fetchAll,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_error != null
                      ? _buildMessageCard(
                          icon: Icons.error_outline,
                          message: _error!,
                          color: Colors.red,
                        )
                      : _filteredAnimals.isEmpty
                      ? _buildMessageCard(
                          icon: Icons.pets,
                          message: 'No animals found.',
                        )
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth;
                            if (width >= 1100) {
                              // Desktop: master-detail two columns
                              return Row(
                                children: [
                                  Flexible(
                                    flex: 1,
                                    child: ListView.separated(
                                      itemCount: _filteredAnimals.length,
                                      separatorBuilder: (_, __) =>
                                          const SizedBox(height: 8),
                                      itemBuilder: (context, idx) => _buildCard(
                                        _filteredAnimals[idx],
                                        true,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    flex: 2,
                                    child: Card(
                                      elevation: 2,
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: _selectedAnimal == null
                                          ? Center(
                                              child: Text(
                                                'Select an animal to view details',
                                                style: Theme.of(
                                                  context,
                                                ).textTheme.titleMedium,
                                              ),
                                            )
                                          : _AnimalDetailPane(
                                              animal: _selectedAnimal!,
                                              farmName:
                                                  _farmNames[(_selectedAnimal!['farm_id'] ??
                                                          '')
                                                      .toString()] ??
                                                  '',
                                              onEdit: () => _showAnimalForm(
                                                animal: _selectedAnimal,
                                              ),
                                              onDelete: () => _confirmAndDelete(
                                                (_selectedAnimal!['id'] ?? '')
                                                    .toString(),
                                              ),
                                            ),
                                    ),
                                  ),
                                ],
                              );
                            } else if (width >= 600) {
                              // Tablet: grid
                              final cross = (width ~/ 320).clamp(2, 4);
                              return GridView.builder(
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: cross,
                                      childAspectRatio: 3.5,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 12,
                                    ),
                                itemCount: _filteredAnimals.length,
                                itemBuilder: (c, i) =>
                                    _buildCard(_filteredAnimals[i], false),
                              );
                            } else {
                              // Mobile: single column list
                              return ListView.separated(
                                itemCount: _filteredAnimals.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (context, idx) =>
                                    _buildCard(_filteredAnimals[idx], false),
                              );
                            }
                          },
                        )),
          ),
        ),
        floatingActionButton: kIsWeb && MediaQuery.of(context).size.width > 900
            ? null
            : FloatingActionButton(
                onPressed: () {
                  _showAnimalForm();
                },
                tooltip: 'Add Animal',
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  Widget _buildMessageCard({
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
}

class _AnimalSearchDelegate extends SearchDelegate<String> {
  final List<Map<String, dynamic>> animals;
  _AnimalSearchDelegate(this.animals);

  @override
  List<Widget>? buildActions(BuildContext context) => [
    IconButton(icon: const Icon(Icons.clear), onPressed: () => query = ''),
  ];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    onPressed: () => close(context, ''),
  );

  @override
  Widget buildResults(BuildContext context) {
    final q = query.trim().toLowerCase();
    final results = animals.where((a) {
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (c, i) {
        final a = results[i];
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        return ListTile(
          title: Text('$tag — $name'),
          onTap: () => close(context, a['id']?.toString() ?? ''),
        );
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final q = query.trim().toLowerCase();
    final suggestions = q.isEmpty
        ? animals.take(10).toList()
        : animals.where((a) {
            final tag = (a['tag'] ?? '').toString().toLowerCase();
            final name = (a['name'] ?? '').toString().toLowerCase();
            final breed = (a['breed'] ?? '').toString().toLowerCase();
            return tag.contains(q) || name.contains(q) || breed.contains(q);
          }).toList();

    return ListView.builder(
      itemCount: suggestions.length,
      itemBuilder: (c, i) {
        final a = suggestions[i];
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        return ListTile(title: Text('$tag — $name'), onTap: () => query = tag);
      },
    );
  }
}

class _AnimalDetailSheet extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String farmName;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _AnimalDetailSheet({
    required this.animal,
    required this.farmName,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final tag = (animal['tag'] ?? '').toString();
    final name = (animal['name'] ?? '').toString();
    final id = (animal['id'] ?? '').toString();
    final breed = (animal['breed'] ?? '').toString();
    final dob = (animal['dob'] ?? '').toString();
    final lactation = (animal['lactation'] ?? '').toString();
    final notes = (animal['notes'] ?? '').toString();
    final imageUrl = (animal['image_url'] ?? '').toString();

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Column(
                children: [
                  if (imageUrl.isNotEmpty)
                    SizedBox(
                      width: 160,
                      height: 160,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.network(
                          imageUrl,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => CircleAvatar(
                            radius: 40,
                            child: Text(
                              name.isNotEmpty ? name[0].toUpperCase() : 'A',
                            ),
                          ),
                        ),
                      ),
                    )
                  else
                    CircleAvatar(
                      radius: 40,
                      child: Text(
                        name.isNotEmpty ? name[0].toUpperCase() : 'A',
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    '$tag — $name',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 8),
                  Text('ID: $id'),
                  if (farmName.isNotEmpty) Text('Farm: $farmName'),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text('Breed: $breed'),
            const SizedBox(height: 8),
            if (dob.isNotEmpty) Text('DOB: $dob'),
            const SizedBox(height: 8),
            Text('Lactation: $lactation'),
            const SizedBox(height: 12),
            if (notes.isNotEmpty) ...[
              const Text(
                'Notes',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(notes),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: onEdit,
                    icon: const Icon(Icons.edit),
                    label: const Text('Edit'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: onDelete,
                    icon: const Icon(Icons.delete),
                    label: const Text('Delete'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AnimalDetailPane extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String farmName;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  const _AnimalDetailPane({
    required this.animal,
    required this.farmName,
    this.onEdit,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    // Large detail pane for desktop master-detail
    return Padding(
      padding: const EdgeInsets.all(16),
      child: _AnimalDetailSheet(
        animal: animal,
        farmName: farmName,
        onEdit: onEdit,
        onDelete: onDelete,
      ),
    );
  }
}

*/

















/*99import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'supabase_config.dart';
import 'api_service.dart';

/// Responsive, master-detail AnimalCentralPage optimized for Telegram Web UX.
/// - Shows a list (mobile) / grid (tablet) / master-detail (desktop) layout
/// - Improved image handling, age calculation, badges, undo-delete
/// - Keeps using your ApiService for fetching animals
class AnimalCentralPage extends StatefulWidget {
  final String token;
  const AnimalCentralPage({super.key, required this.token});

  @override
  State<AnimalCentralPage> createState() => _AnimalCentralPageState();
}

class _AnimalCentralPageState extends State<AnimalCentralPage> {
  late final ApiService _apiService;

  List<Map<String, dynamic>> _animals = [];
  Map<String, String> _farmNames = {}; // farmId -> farmName

  bool _loading = true;
  String? _error;

  // UI state
  final TextEditingController _searchController = TextEditingController();
  String? _selectedFarmId;
  bool _showOnlyLactating = false;
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};

  // master-detail selected on wide screens
  Map<String, dynamic>? _selectedAnimal;

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);
    _fetchAll();
  }

  Future<void> _fetchAll() async {
    setState(() {
      _loading = true;
      _error = null;
      _animals = [];
      _farmNames = {};
      _selectedIds.clear();
      _selectionMode = false;
      _selectedAnimal = null;
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

      await _fetchFarmNames(farmIds);
      final animals = await _apiService.fetchAnimalsForFarms(farmIds);

      setState(() {
        _animals = animals;
        _loading = false;
      });
    } catch (e) {
      debugPrint('fetchAnimals error: $e');
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

  Future<void> _fetchFarmNames(List<String> farmIds) async {
    if (farmIds.isEmpty) return;
    final encodedList = Uri.encodeComponent('(${farmIds.join(',')})');
    final url = '$SUPABASE_URL/rest/v1/farms?select=id,name&order=id&id=in.$encodedList';
    final resp = await http.get(Uri.parse(url), headers: {
      'apikey': SUPABASE_ANON_KEY,
      'Authorization': 'Bearer ${widget.token}',
      'Accept': 'application/json',
    });
    if (resp.statusCode != 200) {
      debugPrint('fetchFarmNames failed: ${resp.statusCode} ${resp.body}');
      return;
    }
    final List data = json.decode(resp.body);
    setState(() {
      for (final f in data) {
        final id = (f['id'] ?? '').toString();
        final name = (f['name'] ?? '').toString();
        if (id.isNotEmpty) _farmNames[id] = name;
      }
    });
  }

  List<Map<String, dynamic>> get _filteredAnimals {
    final q = _searchController.text.trim().toLowerCase();
    return _animals.where((a) {
      if (_selectedFarmId != null && _selectedFarmId!.isNotEmpty) {
        if ((a['farm_id'] ?? '').toString() != _selectedFarmId) return false;
      }
      if (_showOnlyLactating) {
        final lact = (a['lactation'] ?? '').toString().toLowerCase();
        if (!(lact == 'yes' || lact == 'true' || lact == '1')) return false;
      }
      if (q.isEmpty) return true;
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();
  }

  int _calculateAgeInMonths(String dob) {
    try {
      final d = DateTime.parse(dob);
      final now = DateTime.now();
      return (now.year - d.year) * 12 + (now.month - d.month);
    } catch (_) {
      return -1;
    }
  }

  String _ageLabel(String dob) {
    final months = _calculateAgeInMonths(dob);
    if (months < 0) return 'Unknown age';
    final y = months ~/ 12;
    final m = months % 12;
    if (y > 0) return '$y yr${y > 1 ? 's' : ''}${m > 0 ? ' $m mo' : ''}';
    return '$m mo';
  }

  Future<void> _deleteAnimal(String id, {bool showUndo = true}) async {
    final idx = _animals.indexWhere((e) => (e['id'] ?? '').toString() == id);
    if (idx == -1) return;

    final backup = _animals[idx];
    setState(() => _animals.removeAt(idx)); // optimistic

    ScaffoldMessenger.of(context).removeCurrentSnackBar();
    if (showUndo) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Animal deleted'),
          action: SnackBarAction(
            label: 'UNDO',
            onPressed: () {
              setState(() => _animals.insert(idx, backup));
            },
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    }

    // perform actual delete request but don't block UI
    try {
      final url = '$SUPABASE_URL/rest/v1/animals?id=eq.$id';
      final resp = await http.delete(Uri.parse(url), headers: {
        'apikey': SUPABASE_ANON_KEY,
        'Authorization': 'Bearer ${widget.token}',
        'Accept': 'application/json',
      });
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        // restore
        if (!_animals.contains(backup)) setState(() => _animals.insert(idx, backup));
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete animal.')));
        debugPrint('delete animal failed: ${resp.statusCode} ${resp.body}');
      }
    } catch (e) {
      if (!_animals.contains(backup)) setState(() => _animals.insert(idx, backup));
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Failed to delete animal.')));
      debugPrint('delete animal error: $e');
    }
  }

  void _toggleSelectionMode([bool? enable]) {
    setState(() {
      _selectionMode = enable ?? !_selectionMode;
      if (!_selectionMode) _selectedIds.clear();
    });
  }

  void _onItemTap(Map<String, dynamic> a, bool wideLayout) {
    final id = (a['id'] ?? '').toString();
    if (_selectionMode) {
      setState(() {
        if (_selectedIds.contains(id))
          _selectedIds.remove(id);
        else
          _selectedIds.add(id);
      });
      return;
    }

    if (wideLayout) {
      setState(() => _selectedAnimal = a);
      return;
    }

    // show details bottom sheet for narrow screens
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) {
        return Padding(
          padding: MediaQuery.of(context).viewInsets,
          child: DraggableScrollableSheet(
            initialChildSize: 0.7,
            minChildSize: 0.25,
            maxChildSize: 0.95,
            builder: (_, controller) {
              return _AnimalDetailSheet(
                animal: a,
                farmName: _farmNames[(a['farm_id'] ?? '').toString()] ?? '',
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _performBulkDelete() async {
    if (_selectedIds.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Delete selected animals'),
        content: Text('Delete ${_selectedIds.length} selected animals?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true) return;

    final ids = _selectedIds.toList();
    for (final id in ids) {
      await _deleteAnimal(id, showUndo: false);
    }
    _toggleSelectionMode(false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${ids.length} animals deleted')));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _buildCard(Map<String, dynamic> a, bool wideLayout) {
    final tag = (a['tag'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    final breed = (a['breed'] ?? '').toString();
    final id = (a['id'] ?? '').toString();
    final farmId = (a['farm_id'] ?? '').toString();
    final farmName = _farmNames[farmId] ?? '';
    final imageUrl = (a['image_url'] ?? '').toString();
    final lact = (a['lactation'] ?? '').toString().toLowerCase();
    final lactating = (lact == 'yes' || lact == 'true' || lact == '1');

    final selected = _selectedIds.contains(id);

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _onItemTap(a, wideLayout),
        onLongPress: () => _toggleSelectionMode(true),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: imageUrl.isNotEmpty
                    ? Image.network(
                        imageUrl,
                        width: 72,
                        height: 72,
                        fit: BoxFit.cover,
                        loadingBuilder: (c, child, progress) {
                          if (progress == null) return child;
                          return SizedBox(
                            width: 72,
                            height: 72,
                            child: Center(child: CircularProgressIndicator(value: progress.expectedTotalBytes != null ? progress.cumulativeBytesLoaded / (progress.expectedTotalBytes ?? 1) : null)),
                          );
                        },
                        errorBuilder: (c, e, st) => _initialsAvatar(name),
                      )
                    : _initialsAvatar(name),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(child: Text('$tag — $name', style: Theme.of(context).textTheme.titleMedium)),
                        if (_selectionMode)
                          Checkbox(value: selected, onChanged: (_) => _onItemTap(a, wideLayout)),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Wrap(spacing: 8, runSpacing: 6, children: [
                      if (breed.isNotEmpty) Chip(label: Text(breed)),
                      if (farmName.isNotEmpty) Chip(label: Text(farmName)),
                      Chip(label: Text(a['dob'] != null && a['dob'].toString().isNotEmpty ? _ageLabel(a['dob']) : 'Age unknown')),
                      if (lactating) Chip(label: const Text('Lactating'), avatar: const Icon(Icons.opacity, size: 16)),
                    ]),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: 'Delete',
                onPressed: () async {
                  final c = await showDialog<bool>(
                    context: context,
                    builder: (c) => AlertDialog(
                      title: const Text('Delete animal'),
                      content: const Text('Are you sure you want to delete this animal?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Delete')),
                      ],
                    ),
                  );
                  if (c == true) await _deleteAnimal(id);
                },
                icon: const Icon(Icons.delete_outline),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _initialsAvatar(String name) {
    final label = name.isNotEmpty ? name[0].toUpperCase() : 'A';
    return CircleAvatar(
      radius: 36,
      backgroundColor: Theme.of(context).colorScheme.primaryContainer,
      child: Text(label, style: TextStyle(color: Theme.of(context).colorScheme.onPrimaryContainer, fontSize: 24)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: _selectionMode ? Text('${_selectedIds.length} selected') : const Text('Animal Central'),
          actions: [
            if (!_selectionMode)
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: 'Search',
                onPressed: () => showSearch(context: context, delegate: _AnimalSearchDelegate(_animals)),
              ),
            IconButton(
              icon: Icon(_selectionMode ? Icons.close : Icons.check_box_outlined),
              tooltip: _selectionMode ? 'Exit selection' : 'Selection mode',
              onPressed: () => _toggleSelectionMode(null),
            ),
            if (_selectionMode)
              IconButton(icon: const Icon(Icons.delete_forever), tooltip: 'Delete selected', onPressed: _performBulkDelete),
            if (kIsWeb)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8.0),
                child: ElevatedButton.icon(
                  onPressed: _fetchAll,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh'),
                  style: ElevatedButton.styleFrom(minimumSize: const Size(80, 36)),
                ),
              )
            else
              IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchAll),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(60),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search by tag, name or breed',
                        prefixIcon: const Icon(Icons.search),
                        isDense: true,
                        border: const OutlineInputBorder(),
                        suffixIcon: _searchController.text.isNotEmpty
                            ? IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _searchController.clear()))
                            : null,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  const SizedBox(width: 8),
                  PopupMenuButton<String>(
                    tooltip: 'Filters',
                    itemBuilder: (c) => [
                      const PopupMenuItem(value: 'all', child: Text('All farms')),
                      ..._farmNames.entries.map((e) => PopupMenuItem(value: e.key, child: Text(e.value))),
                      const PopupMenuDivider(),
                      CheckedPopupMenuItem(value: 'lactating', checked: _showOnlyLactating, child: const Text('Show only lactating')),
                    ],
                    onSelected: (v) {
                      if (v == 'all') setState(() => _selectedFarmId = null);
                      else if (v == 'lactating') setState(() => _showOnlyLactating = !_showOnlyLactating);
                      else setState(() => _selectedFarmId = v);
                    },
                    child: const Padding(padding: EdgeInsets.symmetric(horizontal: 12), child: Icon(Icons.filter_list)),
                  ),
                ],
              ),
            ),
          ),
        ),
        body: RefreshIndicator(
          onRefresh: _fetchAll,
          child: Padding(
            padding: const EdgeInsets.all(12.0),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_error != null
                    ? _buildMessageCard(icon: Icons.error_outline, message: _error!, color: Colors.red)
                    : _filteredAnimals.isEmpty
                        ? _buildMessageCard(icon: Icons.pets, message: 'No animals found.')
                        : LayoutBuilder(builder: (context, constraints) {
                            final width = constraints.maxWidth;
                            if (width >= 1100) {
                              // Desktop: master-detail two columns
                              return Row(
                                children: [
                                  Flexible(
                                    flex: 1,
                                    child: ListView.separated(
                                      itemCount: _filteredAnimals.length,
                                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                                      itemBuilder: (context, idx) => _buildCard(_filteredAnimals[idx], true),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Flexible(
                                    flex: 2,
                                    child: Card(
                                      elevation: 2,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                      child: _selectedAnimal == null
                                          ? Center(child: Text('Select an animal to view details', style: Theme.of(context).textTheme.titleMedium))
                                          : _AnimalDetailPane(animal: _selectedAnimal!, farmName: _farmNames[(_selectedAnimal!['farm_id'] ?? '').toString()] ?? ''),
                                    ),
                                  ),
                                ],
                              );
                            } else if (width >= 600) {
                              // Tablet: grid
                              final cross = (width ~/ 320).clamp(2, 4);
                              return GridView.builder(
                                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: cross, childAspectRatio: 3.5, crossAxisSpacing: 12, mainAxisSpacing: 12),
                                itemCount: _filteredAnimals.length,
                                itemBuilder: (c, i) => _buildCard(_filteredAnimals[i], false),
                              );
                            } else {
                              // Mobile: single column list
                              return ListView.separated(
                                itemCount: _filteredAnimals.length,
                                separatorBuilder: (_, __) => const SizedBox(height: 8),
                                itemBuilder: (context, idx) => _buildCard(_filteredAnimals[idx], false),
                              );
                            }
                          })),
          ),
        ),
        floatingActionButton: kIsWeb && MediaQuery.of(context).size.width > 900
            ? null
            : FloatingActionButton(
                onPressed: () {
                  // TODO: navigate to add-animal page
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Add animal - not implemented')));
                },
                child: const Icon(Icons.add),
                tooltip: 'Add Animal',
              ),
      ),
    );
  }

  Widget _buildMessageCard({required IconData icon, required String message, Color? color}) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 48, color: color ?? Colors.black54), const SizedBox(height: 8), Text(message, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyLarge)]),
      ),
    );
  }
}

class _AnimalSearchDelegate extends SearchDelegate<String> {
  final List<Map<String, dynamic>> animals;
  _AnimalSearchDelegate(this.animals);

  @override
  List<Widget>? buildActions(BuildContext context) => [IconButton(icon: const Icon(Icons.clear), onPressed: () => query = '')];

  @override
  Widget? buildLeading(BuildContext context) => IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => close(context, ''));

  @override
  Widget buildResults(BuildContext context) {
    final q = query.trim().toLowerCase();
    final results = animals.where((a) {
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();

    return ListView.separated(
      itemCount: results.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (c, i) {
        final a = results[i];
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        return ListTile(title: Text('$tag — $name'), onTap: () => close(context, a['id']?.toString() ?? ''));
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final q = query.trim().toLowerCase();
    final suggestions = q.isEmpty ? animals.take(10).toList() : animals.where((a) {
      final tag = (a['tag'] ?? '').toString().toLowerCase();
      final name = (a['name'] ?? '').toString().toLowerCase();
      final breed = (a['breed'] ?? '').toString().toLowerCase();
      return tag.contains(q) || name.contains(q) || breed.contains(q);
    }).toList();

    return ListView.builder(
      itemCount: suggestions.length,
      itemBuilder: (c, i) {
        final a = suggestions[i];
        final tag = (a['tag'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        return ListTile(title: Text('$tag — $name'), onTap: () => query = '$tag');
      },
    );
  }
}

class _AnimalDetailSheet extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String farmName;
  const _AnimalDetailSheet({required this.animal, required this.farmName});

  @override
  Widget build(BuildContext context) {
    final tag = (animal['tag'] ?? '').toString();
    final name = (animal['name'] ?? '').toString();
    final id = (animal['id'] ?? '').toString();
    final breed = (animal['breed'] ?? '').toString();
    final dob = (animal['dob'] ?? '').toString();
    final lactation = (animal['lactation'] ?? '').toString();
    final notes = (animal['notes'] ?? '').toString();
    final imageUrl = (animal['image_url'] ?? '').toString();

    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Center(child: Column(children: [
            if (imageUrl.isNotEmpty)
              SizedBox(width: 160, height: 160, child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(imageUrl, fit: BoxFit.cover, errorBuilder: (_, __, ___) => CircleAvatar(radius: 40, child: Text(name.isNotEmpty ? name[0].toUpperCase() : 'A')))))
            else
              CircleAvatar(radius: 40, child: Text(name.isNotEmpty ? name[0].toUpperCase() : 'A')),
            const SizedBox(height: 12),
            Text('$tag — $name', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text('ID: $id'),
            if (farmName.isNotEmpty) Text('Farm: $farmName'),
          ])),
          const SizedBox(height: 16),
          Text('Breed: $breed'),
          const SizedBox(height: 8),
          if (dob.isNotEmpty) Text('DOB: $dob'),
          const SizedBox(height: 8),
          Text('Lactation: $lactation'),
          const SizedBox(height: 12),
          if (notes.isNotEmpty) ...[
            const Text('Notes', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(notes),
            const SizedBox(height: 12),
          ],
          Row(children: [
            Expanded(child: ElevatedButton.icon(onPressed: () { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Open details/edit - not implemented'))); }, icon: const Icon(Icons.edit), label: const Text('Edit'))),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(onPressed: () { Navigator.pop(context); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Show production - not implemented'))); }, icon: const Icon(Icons.local_drink), label: const Text('Production'))),
          ])
        ]),
      ),
    );
  }
}

class _AnimalDetailPane extends StatelessWidget {
  final Map<String, dynamic> animal;
  final String farmName;
  const _AnimalDetailPane({required this.animal, required this.farmName});

  @override
  Widget build(BuildContext context) {
    // Large detail pane for desktop master-detail
    return Padding(
      padding: const EdgeInsets.all(16),
      child: _AnimalDetailSheet(animal: animal, farmName: farmName),
    );
  }
}
*/







/*
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AnimalCentralPage extends StatefulWidget {
  const AnimalCentralPage({super.key});

  @override
  State<AnimalCentralPage> createState() => _AnimalCentralPageState();
}

class _AnimalCentralPageState extends State<AnimalCentralPage> {
  final SupabaseClient _supabase = Supabase.instance.client;

  // UI state
  bool _loading = false;
  String? _message;
  String _search = '';

  // Data
  List<Map<String, dynamic>> _animals = [];

  // Form controllers (add/edit)
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _tagCtrl = TextEditingController();
  final TextEditingController _nameCtrl = TextEditingController();
  final TextEditingController _breedCtrl = TextEditingController();
  final TextEditingController _weightCtrl = TextEditingController();
  String _weightUnit = 'kg';
  String _sex = 'female';
  DateTime? _birthDate;
  final TextEditingController _notesCtrl = TextEditingController();

  // Editing mode
  String? _editingId;

  // Scroll controllers
  final ScrollController _verticalController = ScrollController();
  final ScrollController _horizontalController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchAnimals();
  }

  @override
  void dispose() {
    _tagCtrl.dispose();
    _nameCtrl.dispose();
    _breedCtrl.dispose();
    _weightCtrl.dispose();
    _notesCtrl.dispose();
    _verticalController.dispose();
    _horizontalController.dispose();
    super.dispose();
  }

 Future<void> _fetchAnimals({String? search}) async {
  setState(() {
    _loading = true;
    _message = null;
  });

  try {
    final builder = _supabase
        .from('animals')
        .select('id,tag,name,breed,sex,birth_date,weight,weight_unit,notes,created_at,updated_at');

    if (search != null && search.trim().isNotEmpty) {
      final s = search.trim().replaceAll('%', r'\%');
      builder.or('tag.ilike.%$s%,name.ilike.%$s%'); // just call or(), no .execute() here
    }

    final res = await builder.order('tag', ascending: true); // await here, not on or()

  

    final list = (res as List)
        .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map? ?? {}))
        .toList();

    setState(() {
      _animals = list;
    });
  } catch (err, st) {
    debugPrint('fetchAnimals error: $err\n$st');
    setState(() {
      _animals = [];
      _message = 'Failed to fetch animals: $err';
    });
  } finally {
    setState(() => _loading = false);
  }
}


  void _startAddMode() {
    setState(() {
      _editingId = null;
      _tagCtrl.clear();
      _nameCtrl.clear();
      _breedCtrl.clear();
      _weightCtrl.clear();
      _weightUnit = 'kg';
      _sex = 'female';
      _birthDate = null;
      _notesCtrl.clear();
      _message = null;
    });
  }

  void _startEditMode(Map<String, dynamic> animal) {
    setState(() {
      _editingId = (animal['id'] ?? '').toString();
      _tagCtrl.text = animal['tag']?.toString() ?? '';
      _nameCtrl.text = animal['name']?.toString() ?? '';
      _breedCtrl.text = animal['breed']?.toString() ?? '';
      _weightCtrl.text = animal['weight']?.toString() ?? '';
      _weightUnit = animal['weight_unit']?.toString() ?? 'kg';
      _sex = animal['sex']?.toString() ?? 'female';
      _notesCtrl.text = animal['notes']?.toString() ?? '';
      final bd = animal['birth_date'];
      _birthDate = bd != null && bd.isNotEmpty ? DateTime.tryParse(bd) : null;
      _message = null;
    });
  }

  Future<void> _submitForm() async {
    if (!_formKey.currentState!.validate()) return;

    final payload = <String, dynamic>{
      'tag': _tagCtrl.text.trim(),
      'name': _nameCtrl.text.trim(),
      'breed': _breedCtrl.text.trim(),
      'sex': _sex,
      'birth_date': _birthDate != null
          ? _birthDate!.toIso8601String().split('T').first
          : null,
      'weight': _weightCtrl.text.trim().isEmpty
          ? null
          : double.tryParse(_weightCtrl.text.trim()),
      'weight_unit': _weightUnit,
      'notes': _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
    };

    setState(() {
      _loading = true;
      _message = null;
    });

    try {
      if (_editingId == null) {
        await _supabase.from('animals').insert(payload).select();
        setState(() => _message = 'Animal added ✓');
      } else {
await _supabase.from('animals').update(payload).eq('id', _editingId!).select();
        setState(() => _message = 'Animal updated ✓');
      }

      await _fetchAnimals(search: _search);
      _startAddMode();
    } catch (err) {
      setState(() {
        _message = 'Save failed: $err';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _confirmAndDelete(String id) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete animal'),
        content: const Text(
          'Are you sure you want to delete this animal? This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() {
      _loading = true;
      _message = null;
    });

    try {
      await _supabase.from('animals').delete().eq('id', id).select();
      setState(() => _message = 'Deleted');
      await _fetchAnimals(search: _search);
    } catch (err) {
      setState(() {
        _message = 'Delete failed: $err';
      });
    } finally {
      setState(() => _loading = false);
    }
  }

  Widget _buildSearchBar() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Search tag or name',
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => _search = v,
            onSubmitted: (v) => _fetchAnimals(search: v),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: () => _fetchAnimals(search: _search),
          icon: const Icon(Icons.search),
          label: const Text('Search'),
        ),
        const SizedBox(width: 8),
        IconButton(
          onPressed: () => _fetchAnimals(),
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
        ),
      ],
    );
  }

  Widget _buildFormCard() {
    final isEditing = _editingId != null;
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _tagCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Tag',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Tag required' : null,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextFormField(
                      controller: _nameCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        border: OutlineInputBorder(),
                      ),
                      validator: (v) =>
                          v == null || v.trim().isEmpty ? 'Name required' : null,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _breedCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Breed',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _sex,
                      decoration: const InputDecoration(
                        labelText: 'Sex',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'female', child: Text('Female')),
                        DropdownMenuItem(value: 'male', child: Text('Male')),
                        DropdownMenuItem(value: 'unknown', child: Text('Unknown')),
                      ],
                      onChanged: (v) => setState(() => _sex = v ?? 'female'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () async {
                        final d = await showDatePicker(
                          context: context,
                          initialDate: _birthDate ?? DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now(),
                        );
                        if (d != null) setState(() => _birthDate = d);
                      },
                      child: AbsorbPointer(
                        child: TextFormField(
                          decoration: InputDecoration(
                            labelText: 'Birth date',
                            border: const OutlineInputBorder(),
                            hintText: _birthDate == null
                                ? 'Select'
                                : _birthDate!.toIso8601String().split('T').first,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _weightCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(
                              labelText: 'Weight',
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 92,
                          child: DropdownButtonFormField<String>(
                            value: _weightUnit,
                            decoration: const InputDecoration(
                              labelText: 'Unit',
                              border: OutlineInputBorder(),
                            ),
                            items: const [
                              DropdownMenuItem(value: 'kg', child: Text('kg')),
                              DropdownMenuItem(value: 'lb', child: Text('lb')),
                            ],
                            onChanged: (v) => setState(() => _weightUnit = v ?? 'kg'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _notesCtrl,
                maxLines: 2,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    onPressed: _submitForm,
                    icon: Icon(isEditing ? Icons.save : Icons.add),
                    label: Text(isEditing ? 'Save changes' : 'Add animal'),
                  ),
                  const SizedBox(width: 12),
                  OutlinedButton(
                    onPressed: _startAddMode,
                    child: const Text('Clear'),
                  ),
                  const Spacer(),
                  if (_loading)
                    const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                ],
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    _message!,
                    style: TextStyle(
                        color: _message!.contains('✓') || _message == 'Deleted'
                            ? Colors.green
                            : Colors.red),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTable() {
    if (_animals.isEmpty) return const Center(child: Text('No animals available.'));

    return Scrollbar(
      controller: _verticalController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _verticalController,
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          controller: _horizontalController,
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 700),
            child: DataTable(
              columns: const [
                DataColumn(label: Text('Tag')),
                DataColumn(label: Text('Name')),
                DataColumn(label: Text('Breed')),
                DataColumn(label: Text('Sex')),
                DataColumn(label: Text('Birth date')),
                DataColumn(label: Text('Weight')),
                DataColumn(label: Text('Actions')),
              ],
              rows: _animals.map((a) {
                final id = a['id'].toString();
                return DataRow(
                  cells: [
                    DataCell(Text(a['tag'] ?? '')),
                    DataCell(Text(a['name'] ?? '')),
                    DataCell(Text(a['breed'] ?? '')),
                    DataCell(Text(a['sex'] ?? '')),
                    DataCell(Text(a['birth_date'] ?? '')),
                    DataCell(Text('${a['weight'] ?? ''} ${a['weight_unit'] ?? ''}')),
                    DataCell(
                      Row(
                        children: [
                          IconButton(
                              icon: const Icon(Icons.edit, size: 18),
                              onPressed: () => _startEditMode(a)),
                          IconButton(
                              icon: const Icon(Icons.delete, size: 18),
                              onPressed: () => _confirmAndDelete(id)),
                        ],
                      ),
                    ),
                  ],
                );
              }).toList(),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: _buildSearchBar()),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _startAddMode,
                  icon: const Icon(Icons.add),
                  label: const Text('New animal'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                controller: _verticalController,
                child: Column(
                  children: [
                    _buildFormCard(),
                    const SizedBox(height: 12),
                    _buildTable(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
*/