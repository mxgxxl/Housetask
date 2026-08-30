import 'package:flutter/services.dart';

/// The device's IANA timezone id — the one input P1 cannot afford to guess.
///
/// `EconomyP1Repository` requires a `timeZone` on every read that decides a
/// day or a week, and the whole point of F1 making it required rather than
/// defaulted is that the default IS the bug: a member in Madrid completing a
/// task at 00:30 on Monday would have it counted against Sunday — the one day
/// that releases no coins (PDR-013) — and nothing on screen would look wrong.
///
/// ── Why a MethodChannel and not a package (owner decision D2) ────────────
/// `timezone: ^0.9.4` is already a dependency, but it only maps a zone NAME
/// to a `Location`; it cannot report which zone this device is in. Dart's own
/// `DateTime.timeZoneName` returns an abbreviation ("CEST"), which is
/// ambiguous — several IANA zones share one — and is not an IANA id at all.
/// Obtaining the id therefore needs either a new pub dependency, which D2
/// rules out, or a few lines of platform code, which is what this is.
///
/// ── Why UTC is an acceptable last resort ─────────────────────────────────
/// TD-066-DESIGN's approved decision 1 names UTC as the explicit, documented
/// v1 fallback. It is only reached when the channel is genuinely unavailable
/// — a headless `flutter test` with no platform binding, or a build whose
/// native half predates this change — never as a silent default on a device
/// that could have answered. The server also snapshots the zone it actually
/// used into `PersonalBudget.periodTimeZone`, so a wrong guess here surfaces
/// in the payload instead of hiding.
class DeviceTimeZoneService {
  /// Must match the channel registered in `MainActivity.kt` and
  /// `AppDelegate.swift`. Shared as a constant rather than written out at
  /// each end because a typo degrades to [fallback] silently — the failure
  /// mode is a wrong week, not an exception.
  static const String channelName = 'com.homesync.app/timezone';
  static const String methodName = 'getLocalTimeZone';
  static const String fallback = 'UTC';

  final MethodChannel _channel;

  /// Resolved once per process. A device's zone does change (travel; DST is
  /// not a zone change), but asking the platform on every economy refresh
  /// would put a round trip on the hot path for a value that effectively
  /// never moves within a session. [reset] drops it for tests.
  String? _cached;

  DeviceTimeZoneService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(channelName);

  /// The device's IANA id, or [fallback] when the platform cannot say.
  ///
  /// Never throws: an economy read that failed because the timezone lookup
  /// failed would turn a cosmetic unknown into a blank screen.
  Future<String> resolve() async {
    final cached = _cached;
    if (cached != null) return cached;

    try {
      final id = await _channel.invokeMethod<String>(methodName);
      if (id != null && id.isNotEmpty) {
        _cached = id;
        return id;
      }
    } on MissingPluginException {
      // No handler registered: a widget test, or a build whose native half
      // does not carry this channel yet.
    } on PlatformException {
      // The native handler threw. Falling back beats failing the read.
    }

    _cached = fallback;
    return fallback;
  }

  /// Drop the memoized value. Only tests need this; production resolves once
  /// and keeps it for the life of the process.
  void reset() => _cached = null;
}
