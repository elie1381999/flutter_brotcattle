// addanimal.dart
import 'package:flutter/material.dart';

import 'api_service.dart';

class AddAnimalPage extends StatefulWidget {
  final String token;
  final Map<String, dynamic>? initialAnimal;
  final Map<String, String> farmNames;
  final List<String> userFarmIds;

  const AddAnimalPage({
    Key? key,
    required this.token,
    this.initialAnimal,
    required this.farmNames,
    required this.userFarmIds,
  }) : super(key: key);

  @override
  State<AddAnimalPage> createState() => _AddAnimalPageState();
}

class _AddAnimalPageState extends State<AddAnimalPage> {
  late final ApiService _apiService;
  final _formKey = GlobalKey<FormState>();

  late final TextEditingController _tagCtl;
  late final TextEditingController _nameCtl;
  late final TextEditingController _breedCtl;
  late final TextEditingController _dobCtl;
  late final TextEditingController _notesCtl;
  late final TextEditingController _imageCtl;

  String? _selectedFarm;
  bool _lactating = false;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _apiService = ApiService(widget.token);

    final a = widget.initialAnimal;
    _tagCtl = TextEditingController(
      text: a != null ? (a['tag'] ?? '').toString() : '',
    );
    _nameCtl = TextEditingController(
      text: a != null ? (a['name'] ?? '').toString() : '',
    );
    _breedCtl = TextEditingController(
      text: a != null ? (a['breed'] ?? '').toString() : '',
    );
    _dobCtl = TextEditingController(
      text: a != null ? (a['dob'] ?? '').toString() : '',
    );
    _notesCtl = TextEditingController(
      text: a != null ? (a['notes'] ?? '').toString() : '',
    );
    _imageCtl = TextEditingController(
      text: a != null ? (a['image_url'] ?? '').toString() : '',
    );
    _selectedFarm = a != null
        ? (a['farm_id'] ?? '').toString()
        : (widget.userFarmIds.isNotEmpty ? widget.userFarmIds.first : null);
    final lactVal = (a?['lactation'] ?? '').toString().toLowerCase();
    _lactating = (lactVal == 'yes' || lactVal == 'true' || lactVal == '1');
  }

  @override
  void dispose() {
    _tagCtl.dispose();
    _nameCtl.dispose();
    _breedCtl.dispose();
    _dobCtl.dispose();
    _notesCtl.dispose();
    _imageCtl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    final payload = <String, dynamic>{
      'tag': _tagCtl.text.trim(),
      'name': _nameCtl.text.trim().isEmpty ? null : _nameCtl.text.trim(),
      'breed': _breedCtl.text.trim().isEmpty ? null : _breedCtl.text.trim(),
      'birth_date': _dobCtl.text.trim().isEmpty ? null : _dobCtl.text.trim(),
      'notes': _notesCtl.text.trim().isEmpty ? null : _notesCtl.text.trim(),
      'image_url': _imageCtl.text.trim().isEmpty ? null : _imageCtl.text.trim(),
      'farm_id': _selectedFarm,
      'lactation': _lactating ? 'yes' : 'no',
    };

    try {
      if (widget.initialAnimal != null) {
        final id = (widget.initialAnimal!['id'] ?? '').toString();
        final updated = await _apiService.updateAnimal(id, payload);
        if (updated != null) {
          if ((updated['dob'] == null || updated['dob'].toString().isEmpty) &&
              updated['birth_date'] != null) {
            updated['dob'] = updated['birth_date'];
          }
          Navigator.pop(context, updated);
          return;
        }
      } else {
        final created = await _apiService.createAnimal(payload);
        if (created != null) {
          if ((created['dob'] == null || created['dob'].toString().isEmpty) &&
              created['birth_date'] != null) {
            created['dob'] = created['birth_date'];
          }
          Navigator.pop(context, created);
          return;
        }
      }
      // failed
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Failed to save animal.')));
    } catch (e) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Error: $e')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.initialAnimal != null;
    return Scaffold(
      appBar: AppBar(title: Text(isEdit ? 'Edit animal' : 'Add animal')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _tagCtl,
                decoration: const InputDecoration(labelText: 'Tag *'),
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? 'Tag required' : null,
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _nameCtl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _breedCtl,
                decoration: const InputDecoration(labelText: 'Breed'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _dobCtl,
                decoration: const InputDecoration(
                  labelText: 'DOB (YYYY-MM-DD)',
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _imageCtl,
                decoration: const InputDecoration(labelText: 'Image URL'),
              ),
              const SizedBox(height: 8),
              TextFormField(
                controller: _notesCtl,
                decoration: const InputDecoration(labelText: 'Notes'),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String?>(
                      value: _selectedFarm,
                      items: widget.userFarmIds
                          .map(
                            (f) => DropdownMenuItem(
                              value: f,
                              child: Text(widget.farmNames[f] ?? f),
                            ),
                          )
                          .toList(),
                      onChanged: (v) => setState(() => _selectedFarm = v),
                      decoration: const InputDecoration(labelText: 'Farm'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Lactating'),
                      Checkbox(
                        value: _lactating,
                        onChanged: (v) =>
                            setState(() => _lactating = v ?? false),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _saving ? null : _save,
                      child: _saving
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(isEdit ? 'Save changes' : 'Create'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton(
                      onPressed: _saving ? null : () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
