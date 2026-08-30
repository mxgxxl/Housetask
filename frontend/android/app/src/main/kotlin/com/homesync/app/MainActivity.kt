package com.homesync.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.TimeZone

class MainActivity : FlutterActivity() {
    // Serves DeviceTimeZoneService (TD-066 F2). Dart cannot obtain an IANA
    // zone id on its own — DateTime.timeZoneName gives an ambiguous
    // abbreviation — and owner decision D2 rules out a new pub dependency.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "com.homesync.app/timezone")
            .setMethodCallHandler { call, result ->
                if (call.method == "getLocalTimeZone") {
                    result.success(TimeZone.getDefault().id)
                } else {
                    result.notImplemented()
                }
            }
    }
}
