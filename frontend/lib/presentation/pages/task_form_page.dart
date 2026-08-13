import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/task.dart';
import '../cubit/household_cubit.dart';
import '../cubit/task_cubit.dart';
import '../widgets/assignee_selector.dart';
import '../widgets/common.dart';

/// Create or edit a task.
class TaskFormPage extends StatefulWidget {
  final Task? task;

  const TaskFormPage({super.key, this.task});

  bool get isEditing => task != null;

  @override
  State<TaskFormPage> createState() => _TaskFormPageState();
}

class _TaskFormPageState extends State<TaskFormPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _description;
  late final TextEditingController _interval;

  final Set<String> _assignedIds = {};
  DateTime? _dueDate;
  String _priority = 'medium';
  String _category = 'other';
  bool _isRecurring = false;
  String _recurrenceType = 'weekly';

  static const _categories = ['cleaning', 'cooking', 'shopping', 'maintenance', 'other'];
  static const _priorities = ['low', 'medium', 'high'];
  static const _recurrenceTypes = ['daily', 'weekly', 'monthly', 'custom'];

  @override
  void initState() {
    super.initState();
    final t = widget.task;
    _title = TextEditingController(text: t?.title ?? '');
    _description = TextEditingController(text: t?.description ?? '');
    _interval = TextEditingController(text: t?.recurrenceRule?.interval?.toString() ?? '1');
    if (t != null) {
      _assignedIds.addAll(t.assignedTo.map((u) => u.id));
      _dueDate = t.dueDate;
      _priority = t.priority;
      _category = t.category;
      _isRecurring = t.isRecurring;
      _recurrenceType = t.recurrenceRule?.type ?? 'weekly';
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _interval.dispose();
    super.dispose();
  }

  Future<void> _pickDueDate() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _dueDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 3),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_dueDate ?? now),
    );
    setState(() {
      _dueDate = DateTime(
        date.year,
        date.month,
        date.day,
        time?.hour ?? 9,
        time?.minute ?? 0,
      );
    });
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;

    final payload = <String, dynamic>{
      'title': _title.text.trim(),
      'description': _description.text.trim(),
      'assignedTo': _assignedIds.toList(),
      'priority': _priority,
      'category': _category,
      'dueDate': _dueDate?.toIso8601String(),
      'isRecurring': _isRecurring,
    };
    if (_isRecurring) {
      payload['recurrenceRule'] = {
        'type': _recurrenceType,
        'interval': int.tryParse(_interval.text) ?? 1,
      };
    }

    final cubit = context.read<TaskCubit>();
    if (widget.isEditing) {
      cubit.updateTask(widget.task!.id, payload);
    } else {
      cubit.createTask(payload);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final members = context.watch<HouseholdCubit>().state.current?.members ?? [];
    final memberUsers = members.map((m) => m.user).toList();

    return Scaffold(
      appBar: AppBar(title: Text(widget.isEditing ? 'Editar tarea' : 'Nueva tarea')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
          children: [
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(labelText: 'Título'),
              textCapitalization: TextCapitalization.sentences,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'El título es obligatorio' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Descripción (opcional)'),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 20),
            const SectionHeader(title: 'Asignar a'),
            AssigneeSelector(
              users: memberUsers,
              selectedIds: _assignedIds,
              onToggle: (id) => setState(() {
                _assignedIds.contains(id) ? _assignedIds.remove(id) : _assignedIds.add(id);
              }),
              onClearAll: () => setState(_assignedIds.clear),
            ),
            const SizedBox(height: 12),
            _FieldTile(
              icon: Icons.event_outlined,
              label: 'Fecha límite',
              value: _dueDate == null
                  ? 'Sin fecha'
                  : DateFormat("d MMM y · HH:mm", 'es').format(_dueDate!),
              onTap: _pickDueDate,
              onClear: _dueDate == null ? null : () => setState(() => _dueDate = null),
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'Prioridad'),
            Wrap(
              spacing: 8,
              children: _priorities.map((p) {
                final selected = _priority == p;
                return ChoiceChip(
                  label: Text(priorityLabel(p)),
                  selected: selected,
                  onSelected: (_) => setState(() => _priority = p),
                  selectedColor: priorityColor(p).withValues(alpha: 0.18),
                  labelStyle: TextStyle(
                    color: selected ? priorityColor(p) : AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            const SectionHeader(title: 'Categoría'),
            DropdownButtonFormField<String>(
              value: _category,
              items: _categories
                  .map((c) => DropdownMenuItem(
                        value: c,
                        child: Row(
                          children: [
                            Icon(taskCategoryIcon(c), size: 18),
                            const SizedBox(width: 8),
                            Text(taskCategoryLabel(c)),
                          ],
                        ),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _category = v ?? 'other'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Tarea recurrente'),
              value: _isRecurring,
              activeColor: AppColors.primary,
              onChanged: (v) => setState(() => _isRecurring = v),
            ),
            if (_isRecurring)
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      value: _recurrenceType,
                      decoration: const InputDecoration(labelText: 'Repetir'),
                      items: _recurrenceTypes
                          .map((t) => DropdownMenuItem(value: t, child: Text(_recurrenceLabel(t))))
                          .toList(),
                      onChanged: (v) => setState(() => _recurrenceType = v ?? 'weekly'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 96,
                    child: TextFormField(
                      controller: _interval,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Cada'),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: ElevatedButton(
            onPressed: _save,
            child: Text(widget.isEditing ? 'Guardar cambios' : 'Crear tarea'),
          ),
        ),
      ),
    );
  }

  String _recurrenceLabel(String t) {
    switch (t) {
      case 'daily':
        return 'Diaria';
      case 'weekly':
        return 'Semanal';
      case 'monthly':
        return 'Mensual';
      default:
        return 'Personalizada';
    }
  }
}

class _FieldTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const _FieldTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon, color: AppColors.primary),
        title: Text(label),
        subtitle: Text(value),
        trailing: onClear != null
            ? IconButton(icon: const Icon(Icons.close), onPressed: onClear)
            : const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
