import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/shopping_item.dart';
import '../cubit/shopping_cubit.dart';

/// Create or edit a shopping item.
class ShoppingFormPage extends StatefulWidget {
  final ShoppingItem? item;

  const ShoppingFormPage({super.key, this.item});

  bool get isEditing => item != null;

  @override
  State<ShoppingFormPage> createState() => _ShoppingFormPageState();
}

class _ShoppingFormPageState extends State<ShoppingFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _quantity;
  late final TextEditingController _interval;
  String _unit = 'uds';
  String _category = 'other';
  bool _isRecurring = false;

  static const _units = ['uds', 'kg', 'g', 'litros', 'ml', 'bandejas', 'paquetes'];
  static const _categories = ['fridge', 'pantry', 'cleaning', 'personal', 'other'];

  @override
  void initState() {
    super.initState();
    final it = widget.item;
    _name = TextEditingController(text: it?.name ?? '');
    _quantity = TextEditingController(text: (it?.quantity ?? 1).toString());
    _interval =
        TextEditingController(text: it?.recurrenceIntervalDays?.toString() ?? '7');
    if (it != null) {
      _unit = _units.contains(it.unit) ? it.unit : 'uds';
      _category = it.category;
      _isRecurring = it.isRecurring;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _quantity.dispose();
    _interval.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final payload = <String, dynamic>{
      'name': _name.text.trim(),
      'quantity': num.tryParse(_quantity.text) ?? 1,
      'unit': _unit,
      'category': _category,
      'isRecurring': _isRecurring,
      if (_isRecurring)
        'recurrenceIntervalDays': int.tryParse(_interval.text) ?? 7,
    };

    final cubit = context.read<ShoppingCubit>();
    if (widget.isEditing) {
      cubit.updateItem(widget.item!.id, payload);
    } else {
      cubit.createItem(payload);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
          title: Text(widget.isEditing ? 'Editar producto' : 'Nuevo producto')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            TextFormField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Nombre del producto'),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'El nombre es obligatorio' : null,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _quantity,
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Cantidad'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<String>(
                    value: _unit,
                    decoration: const InputDecoration(labelText: 'Unidad'),
                    items: _units
                        .map((u) => DropdownMenuItem(value: u, child: Text(u)))
                        .toList(),
                    onChanged: (v) => setState(() => _unit = v ?? 'uds'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _category,
              decoration: const InputDecoration(labelText: 'Categoría'),
              items: _categories
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Row(
                          children: [
                            Icon(shoppingCategoryIcon(c), size: 18),
                            const SizedBox(width: 8),
                            Text(shoppingCategoryLabel(c)),
                          ],
                        ),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _category = v ?? 'other'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Producto recurrente'),
              subtitle: const Text('Se sugiere volver a añadir cada X días'),
              value: _isRecurring,
              activeColor: AppColors.primary,
              onChanged: (v) => setState(() => _isRecurring = v),
            ),
            if (_isRecurring)
              TextFormField(
                controller: _interval,
                keyboardType: TextInputType.number,
                decoration:
                    const InputDecoration(labelText: 'Repetir cada (días)'),
              ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton(
            onPressed: _save,
            child: Text(widget.isEditing ? 'Guardar cambios' : 'Añadir producto'),
          ),
        ),
      ),
    );
  }
}
