// lib/animallist.dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import 'api_service.dart';
import 'addanimal.dart'; // the form page - same folder

class AnimalListPage extends StatefulWidget {
  final String token;
  const AnimalListPage({Key? key, required this.token}) : super(key: key);

  @override
  State<AnimalListPage> createState() => _AnimalListPageState();
}

class _AnimalListPageState extends State<AnimalListPage> {
  late final ApiService _apiService;

  List<Map<String, dynamic>> _animals = [];
  Map<String, String> _farmNames = {}; // farmId -> farmName
  List<String> _userFarmIds = [];

  bool _loading = true;
  String? _error;

  final TextEditingController _searchController = TextEditingController();
  String? _selectedFarmId;
  bool _showOnlyLactating = false;

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
      final animals = await _api_service_fetchAnimals(farmIds);
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
      setState(() {
        _error = 'Failed to load animals. Check connection.';
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

  Future<List<Map<String, dynamic>>> _api_service_fetchAnimals(
    List<String> farmIds,
  ) async {
    try {
      return await _apiService.fetchAnimalsForFarms(farmIds);
    } catch (e) {
      debugPrint('fetchAnimalsForFarms error: $e');
      return [];
    }
  }

  Future<void> _fetchFarmNames(List<String> farmIds) async {
    if (farmIds.isEmpty) return;
    try {
      final map = await _apiService.fetchFarmsByIds(farmIds);
      setState(() => _farmNames = map);
    } catch (e) {
      debugPrint('fetchFarmNames error: $e');
    }
  }

  List<Map<String, dynamic>> get _filteredAnimals {
    final q = _searchController.text.trim().toLowerCase();
    return _animals.where((a) {
      if (_selectedFarmId != null && _selectedFarmId!.isNotEmpty) {
        if ((a['farm_id'] ?? '').toString() != _selectedFarmId) return false;
      }
      if (_showOnlyLactating) {
        final lact = (a['lactation'] ?? a['lactation_status'] ?? '')
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

  Future<void> _deleteAnimal(String id) async {
    final idx = _animals.indexWhere((e) => (e['id'] ?? '').toString() == id);
    if (idx == -1) return;

    final backup = _animals[idx];
    setState(() => _animals.removeAt(idx));

    final ok = await _apiService.deleteAnimal(id);
    if (!ok) {
      setState(() => _animals.insert(idx, backup));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to delete animal.')));
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Animal deleted')));
    }
  }

  Future<void> _openAddPage({Map<String, dynamic>? animal}) async {
    final result = await Navigator.push<Map<String, dynamic>?>(
      context,
      MaterialPageRoute(
        builder: (_) => AddAnimalPage(
          token: widget.token,
          initialAnimal: animal,
          farmNames: _farmNames,
          userFarmIds: _userFarmIds,
        ),
      ),
    );

    if (result != null) {
      // created or updated
      final id = (result['id'] ?? '').toString();
      final idx = _animals.indexWhere((a) => (a['id'] ?? '').toString() == id);
      if (idx != -1) {
        setState(() => _animals[idx] = result);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Animal updated')));
      } else {
        setState(() => _animals.insert(0, result));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Animal created')));
      }
    }
  }

  Widget _initialsAvatar(String name) {
    final label = name.isNotEmpty ? name[0].toUpperCase() : 'A';
    return CircleAvatar(radius: 28, child: Text(label));
  }

  String _ageLabel(String dob) {
    try {
      if (dob.isEmpty) return 'Unknown';
      final d = DateTime.parse(dob);
      final now = DateTime.now();
      final months = (now.year - d.year) * 12 + (now.month - d.month);
      if (months < 0) return 'Unknown';
      final y = months ~/ 12;
      final m = months % 12;
      if (y > 0) return '$y yr${y > 1 ? 's' : ''}${m > 0 ? ' $m mo' : ''}';
      return '$m mo';
    } catch (_) {
      return 'Unknown';
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Widget _buildCard(Map<String, dynamic> a) {
    final tag = (a['tag'] ?? '').toString();
    final name = (a['name'] ?? '').toString();
    final breed = (a['breed'] ?? '').toString();
    final id = (a['id'] ?? '').toString();
    final farmId = (a['farm_id'] ?? '').toString();
    final farmName = _farmNames[farmId] ?? '';
    final imageUrl = (a['image_url'] ?? '').toString();
    final lact = (a['lactation'] ?? '').toString().toLowerCase();
    final lactating = (lact == 'yes' || lact == 'true' || lact == '1');

    return Card(
      child: ListTile(
        leading: imageUrl.isNotEmpty
            ? ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.network(
                  imageUrl,
                  width: 56,
                  height: 56,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => _initialsAvatar(name),
                ),
              )
            : _initialsAvatar(name),
        title: Text('$tag — $name'),
        subtitle: Wrap(
          spacing: 8,
          children: [
            if (breed.isNotEmpty) Text(breed),
            if (farmName.isNotEmpty) Text(farmName),
            Text(
              a['dob'] != null && a['dob'].toString().isNotEmpty
                  ? _ageLabel(a['dob'].toString())
                  : 'Age unknown',
            ),
            if (lactating) const Chip(label: Text('Lactating')),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => _openAddPage(animal: a),
            ),
            IconButton(
              tooltip: 'Delete',
              icon: const Icon(Icons.delete_outline),
              onPressed: () async {
                final confirm = await showDialog<bool>(
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
                if (confirm == true) await _deleteAnimal(id);
              },
            ),
          ],
        ),
        onTap: () => _openAddPage(animal: a),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Animals'),
          actions: [
            IconButton(icon: const Icon(Icons.refresh), onPressed: _fetchAll),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        hintText: 'Search by tag, name or breed',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        isDense: true,
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
                      ..._farmNames.entries
                          .map(
                            (e) => PopupMenuItem(
                              value: e.key,
                              child: Text(e.value),
                            ),
                          )
                          .toList(),
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
                      padding: EdgeInsets.symmetric(horizontal: 8.0),
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
            padding: const EdgeInsets.all(12),
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : (_error != null
                      ? Center(child: Text(_error!))
                      : _filteredAnimals.isEmpty
                      ? const Center(child: Text('No animals found.'))
                      : ListView.separated(
                          itemBuilder: (c, i) =>
                              _buildCard(_filteredAnimals[i]),
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: 8),
                          itemCount: _filteredAnimals.length,
                        )),
          ),
        ),
        floatingActionButton: kIsWeb && MediaQuery.of(context).size.width > 900
            ? null
            : FloatingActionButton(
                onPressed: () => _openAddPage(),
                tooltip: 'Add Animal',
                child: const Icon(Icons.add),
              ),
      ),
    );
  }
}
