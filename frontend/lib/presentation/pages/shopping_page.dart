import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import '../../config/theme.dart';
import '../../core/utils/ui_helpers.dart';
import '../../data/models/shopping_item.dart';
import '../cubit/shopping_cubit.dart';
import '../widgets/common.dart';
import 'shopping_form_page.dart';

/// Shopping tab: items grouped by category, checkboxes to mark purchased.
class ShoppingPage extends StatelessWidget {
  const ShoppingPage({super.key});

  static const _categoryOrder = ['fridge', 'pantry', 'cleaning', 'personal', 'other'];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Compras',
            style: TextStyle(fontWeight: FontWeight.w800, fontSize: 22)),
      ),
      body: BlocBuilder<ShoppingCubit, ShoppingState>(
        builder: (context, state) {
          if (state.status == ShoppingStatusUi.loading && state.items.isEmpty) {
            return const Center(child: CircularProgressIndicator());
          }
          if (state.items.isEmpty) {
            return const EmptyState(
              icon: Icons.shopping_cart_outlined,
              title: 'Lista de compra vacía',
              subtitle: 'Añade productos con el botón +',
            );
          }

          final grouped = state.byCategory;
          final categories = _categoryOrder.where(grouped.containsKey).toList();

          return RefreshIndicator(
            onRefresh: () => context.read<ShoppingCubit>().refresh(),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
              children: [
                for (final category in categories) ...[
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Icon(shoppingCategoryIcon(category),
                            size: 18, color: AppColors.secondary),
                        const SizedBox(width: 8),
                        Text(
                          shoppingCategoryLabel(category),
                          style: const TextStyle(
                              fontWeight: FontWeight.w700, fontSize: 15),
                        ),
                        const SizedBox(width: 6),
                        Text('(${grouped[category]!.length})',
                            style: const TextStyle(color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  ...grouped[category]!.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ShoppingTile(item: item),
                      )),
                ],
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ShoppingFormPage())),
        icon: const Icon(Icons.add),
        label: const Text('Producto'),
      ),
    );
  }
}

class _ShoppingTile extends StatelessWidget {
  final ShoppingItem item;

  const _ShoppingTile({required this.item});

  @override
  Widget build(BuildContext context) {
    return Slidable(
      key: ValueKey(item.id),
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.5,
        children: [
          SlidableAction(
            onPressed: (_) => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ShoppingFormPage(item: item)),
            ),
            backgroundColor: AppColors.secondary,
            foregroundColor: Colors.white,
            icon: Icons.edit_outlined,
            label: 'Editar',
            borderRadius: BorderRadius.circular(16),
          ),
          SlidableAction(
            onPressed: (_) => context.read<ShoppingCubit>().deleteItem(item.id),
            backgroundColor: AppColors.error,
            foregroundColor: Colors.white,
            icon: Icons.delete_outline,
            label: 'Eliminar',
            borderRadius: BorderRadius.circular(16),
          ),
        ],
      ),
      child: Card(
        child: ListTile(
          onTap: () => context.read<ShoppingCubit>().togglePurchased(item),
          leading: Icon(
            item.isPurchased
                ? Icons.check_box
                : Icons.check_box_outline_blank,
            color: item.isPurchased ? AppColors.priorityLow : AppColors.textSecondary,
          ),
          title: Text(
            item.name,
            style: TextStyle(
              fontWeight: FontWeight.w600,
              decoration: item.isPurchased ? TextDecoration.lineThrough : null,
              color:
                  item.isPurchased ? AppColors.textSecondary : AppColors.textPrimary,
            ),
          ),
          subtitle: Text('${item.quantity} ${item.unit}'),
          trailing: item.isRecurring
              ? const Icon(Icons.repeat, size: 18, color: AppColors.secondary)
              : null,
        ),
      ),
    );
  }
}
