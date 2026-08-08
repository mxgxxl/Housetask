import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'app.dart';
import 'services/notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Locale data for date formatting (Spanish labels).
  await initializeDateFormatting('es', null);

  // Initialize local notifications (permissions + timezone db).
  await NotificationService().init();

  runApp(const HomeSyncApp());
}
