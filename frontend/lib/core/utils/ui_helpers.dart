import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../config/theme.dart';

/// Maps a task priority to its accent color.
Color priorityColor(String priority) {
  switch (priority) {
    case 'high':
      return AppColors.priorityHigh;
    case 'low':
      return AppColors.priorityLow;
    case 'medium':
    default:
      return AppColors.priorityMedium;
  }
}

String priorityLabel(String priority) {
  switch (priority) {
    case 'high':
      return 'Alta';
    case 'low':
      return 'Baja';
    default:
      return 'Media';
  }
}

/// Task category → (icon, human label).
IconData taskCategoryIcon(String category) {
  switch (category) {
    case 'cleaning':
      return Icons.cleaning_services_outlined;
    case 'cooking':
      return Icons.restaurant_outlined;
    case 'shopping':
      return Icons.shopping_cart_outlined;
    case 'maintenance':
      return Icons.build_outlined;
    default:
      return Icons.checklist_outlined;
  }
}

String taskCategoryLabel(String category) {
  switch (category) {
    case 'cleaning':
      return 'Limpieza';
    case 'cooking':
      return 'Cocina';
    case 'shopping':
      return 'Compras';
    case 'maintenance':
      return 'Mantenimiento';
    default:
      return 'Otros';
  }
}

/// Shopping category → (icon, human label).
IconData shoppingCategoryIcon(String category) {
  switch (category) {
    case 'fridge':
      return Icons.kitchen_outlined;
    case 'pantry':
      return Icons.inventory_2_outlined;
    case 'cleaning':
      return Icons.cleaning_services_outlined;
    case 'personal':
      return Icons.person_outline;
    default:
      return Icons.category_outlined;
  }
}

String shoppingCategoryLabel(String category) {
  switch (category) {
    case 'fridge':
      return 'Frigorífico';
    case 'pantry':
      return 'Despensa';
    case 'cleaning':
      return 'Limpieza';
    case 'personal':
      return 'Personal';
    default:
      return 'Otros';
  }
}

/// Friendly relative date label (Hoy / Mañana / dd MMM).
String formatDueDate(DateTime? date) {
  if (date == null) return 'Sin fecha';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(date.year, date.month, date.day);
  final diff = target.difference(today).inDays;

  if (diff == 0) return 'Hoy';
  if (diff == 1) return 'Mañana';
  if (diff == -1) return 'Ayer';
  return DateFormat('d MMM', 'es').format(date);
}

String formatTime(DateTime date) => DateFormat('HH:mm').format(date);
