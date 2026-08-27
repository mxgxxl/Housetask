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
class ShoppingPage extends StatefulWidget {
  const ShoppingPage({super.key});

  @override
  State<ShoppingPage> createState() => _ShoppingPageState();
}

class _ShoppingPageState extends State<ShoppingPage> {
  static const _categoryOrder = [
    'fridge',
    'pantry',
    'cleaning',
    'personal',
    'other'
  ];

  final ScrollController _controller = ScrollController();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  /// Fetch the next page before the bottom is reached. The cubit's
  /// isLoadingMore guard absorbs the repeated calls this fires while the user
  /// scrolls through the trigger zone.
  void _onScroll() {
    if (!_controller.hasClients) return;
    final position = _controller.position;
    if (position.pixels > position.maxScrollExtent * 0.8) {
      context.read<ShoppingCubit>().loadMore();
    }
  }

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
          if (state.status == ShoppingStatusUi.error && state.items.isEmpty) {
            return _ErrorRetry(
              message: state.error ?? 'No se pudo cargar la lista',
              onRetry: () => context.read<ShoppingCubit>().refresh(),
            );
          }
          if (state.items.isEmpty) {
            return RefreshIndicator(
              onRefresh: () => context.read<ShoppingCubit>().refresh(),
              // AlwaysScrollable keeps pull-to-refresh reachable when empty.
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                children: [
                  SizedBox(
                    height: MediaQuery.of(context).size.height * 0.6,
                    child: const EmptyState(
                      icon: Icons.shopping_cart_outlined,
                      title: 'Lista de compra vacía',
                      subtitle: 'Añade productos con el botón +',
                    ),
                  ),
                ],
              ),
            );
          }

          final grouped = state.byCategory;
          final categories = _categoryOrder.where(grouped.containsKey).toList();

          return RefreshIndicator(
            onRefresh: () => context.read<ShoppingCubit>().refresh(),
            child: ListView(
              controller: _controller,
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
                            style: const TextStyle(
                                color: AppColors.textSecondary)),
                      ],
                    ),
                  ),
                  ...grouped[category]!.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _ShoppingTile(item: item),
                      )),
                ],
                // Footer: spinner only while a page is in flight; nothing once
                // the list is exhausted.
                if (state.isLoadingMore)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        // See home_page.dart's FAB: distinct tags because the IndexedStack
        // keeps all three alive simultaneously.
        heroTag: 'shopping-fab',
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const ShoppingFormPage())),
        icon: const Icon(Icons.add),
        label: const Text('Producto'),
      ),
    );
  }
}

/// Error state with a retry action, shown when the first page fails.
class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;

  const _ErrorRetry({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off,
                size: 48, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Reintentar'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShoppingTile extends StatelessWidget {
  final ShoppingItem item;

  const _ShoppingTile({required this.item});

  @override
  Widget build(BuildContext context) {
    // isDeleted implies isSynced == false (ShoppingRepository sets both
    // together for an offline delete): the strike-through and the
    // pending-sync cloud below combine into "queued to be removed once back
    // online" without needing a third state.
    final struckThrough = item.isPurchased || item.isDeleted;

    // A mutation on this item is in flight, waiting for the server (TD-007).
    // Actions are disabled for the window it lasts so a second tap cannot
    // race the first. The cue is deliberately quiet — a slight fade, no
    // banner, no snackbar, no dialog: the window is typically ~200ms and
    // anything louder would disrupt more than the problem it prevents. A
    // failure is reported by the rollback path; nothing announces the block.
    final isPending = context.watch<ShoppingCubit>().state.pendingIds.contains(item.id);

    return Opacity(
      // Reuses the existing fade rather than adding a layer: a queued delete
      // (0.5) reads as "on its way out", an in-flight mutation (0.7) as
      // "settling".
      opacity: item.isDeleted
          ? 0.5
          : isPending
              ? 0.7
              : 1,
      child: Slidable(
        key: ValueKey(item.id),
        // Same reasoning as tasks_page: the slide actions live outside the
        // tile, so isPending alone would leave them reachable on a row whose
        // create has not confirmed yet.
        endActionPane: isPending
            ? null
            : ActionPane(
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
              onPressed: (_) =>
                  context.read<ShoppingCubit>().deleteItem(item.id),
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
            onTap: isPending
                ? null
                : () => context.read<ShoppingCubit>().togglePurchased(item),
            leading: Icon(
              item.isPurchased
                  ? Icons.check_box
                  : Icons.check_box_outline_blank,
              color: item.isPurchased
                  ? AppColors.priorityLow
                  : AppColors.textSecondary,
            ),
            title: Text(
              item.name,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                decoration: struckThrough ? TextDecoration.lineThrough : null,
                color: struckThrough
                    ? AppColors.textSecondary
                    : AppColors.textPrimary,
              ),
            ),
            subtitle: Text('${item.quantity} ${item.unit}'),
            trailing: (item.isRecurring || !item.isSynced)
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (item.isRecurring) ...[
                        const Icon(Icons.repeat,
                            size: 18, color: AppColors.secondary),
                        const SizedBox(width: 6),
                      ],
                      if (!item.isSynced) const _ShoppingPendingSyncIndicator(),
                    ],
                  )
                : null,
          ),
        ),
      ),
    );
  }
}

/// Mirrors task_tile.dart's _PendingSyncIndicator: a shopping item created,
/// edited, or deleted offline (TD-003) still waiting on
/// ShoppingCubit.syncPending to replay it against the server.
class _ShoppingPendingSyncIndicator extends StatelessWidget {
  const _ShoppingPendingSyncIndicator();

  @override
  Widget build(BuildContext context) {
    return const Tooltip(
      message: 'Pendiente de sincronizar',
      child: SizedBox(
        width: 26,
        height: 18,
        child: Stack(
          alignment: Alignment.centerLeft,
          children: [
            Icon(Icons.cloud_queue, size: 16, color: AppColors.secondary),
            Positioned(
              right: 0,
              child: SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.secondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
