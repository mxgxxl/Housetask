import 'package:uuid/uuid.dart';

import '../../services/cache_service.dart';
import '../datasources/remote/api_service.dart';
import '../models/economy_p1/economy_p1.dart';
import '../models/economy_p1/economy_p1_snapshot.dart';

/// The P1 economy's data layer (TD-066 F1).
///
/// ── Why timeZone is required everywhere ──────────────────────────────────
/// Nothing on the server persists a member's timezone yet, so it travels on
/// every request that decides a day or a week. It is a REQUIRED parameter
/// rather than an optional one with a UTC default, because the default is
/// precisely the bug: a member in Madrid completing a task at 00:30 on Monday
/// would have it counted against Sunday — the one day that releases no coins
/// (PDR-013) — and nothing would look wrong. Making it required moves that
/// mistake from runtime to compile time.
///
/// ── Reads fall back to cache, writes never do ────────────────────────────
/// A stale wallet is worth showing; a queued spend is not. Offline reads
/// return the last snapshot, while every write throws so the caller can tell
/// the member it did not happen. TD-066-DESIGN §7 is explicit that
/// contributing, cancelling and buying ice must NOT be queued until their
/// offline compensation is designed: a monetary debit must not quietly adopt
/// last-write-wins.
class EconomyP1Repository {
  final ApiService _api;
  final CacheService _cache;
  final Uuid _uuid;

  EconomyP1Repository(this._api, this._cache, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  /// Whether the last [load] was served from cache instead of the network.
  ///
  /// [load] deliberately swallows a failed fetch and returns the last
  /// snapshot, which leaves the caller unable to tell a fresh wallet from a
  /// three-day-old one — and "stale" is a thing the UI must say out loud
  /// (TD-066-DESIGN §7). Same flag-beside-the-call shape as
  /// `TaskRepository.lastListWasFromCache`, for the same reason: threading a
  /// wrapper type through every read would change the signature of a
  /// contract F1 already settled.
  bool lastLoadWasFromCache = false;

  String _base(String householdId) => '/households/$householdId/economy/p1';

  /// Both halves of the economy, cached as one snapshot.
  ///
  /// The two endpoints are fetched together and stored together: they are one
  /// coherent reading, and a screen that mixed a fresh personal half with a
  /// stale household half would show a state that never existed.
  Future<EconomyP1> load(String householdId, {required String timeZone}) async {
    try {
      final personalJson = await _api.get(
        '${_base(householdId)}/me',
        query: {'timeZone': timeZone},
      );
      final householdJson = await _api.get('${_base(householdId)}/household');

      final snapshot = EconomyP1Snapshot(
        householdId: householdId,
        personal: PersonalEconomy.fromJson(Map<String, dynamic>.from(personalJson as Map)),
        household: HouseholdEconomy.fromJson(Map<String, dynamic>.from(householdJson as Map)),
        refreshedAt: DateTime.now().toUtc(),
      );
      await _cache.saveEconomyP1(householdId, snapshot);
      lastLoadWasFromCache = false;
      return snapshot.toEconomy();
    } catch (_) {
      // Offline, or the server is unhappy. A stale wallet beats an error
      // screen, and `refreshedAt` lets the UI say how stale.
      final cached = _cache.economyP1(householdId);
      if (cached != null) {
        lastLoadWasFromCache = true;
        return cached.toEconomy();
      }
      rethrow;
    }
  }

  /// The cached snapshot without touching the network, for a first frame that
  /// should not be a spinner.
  EconomyP1? cached(String householdId) => _cache.economyP1(householdId)?.toEconomy();

  /// Rewrite the caller's weekly plan.
  ///
  /// [mode] is `automatic` — the "Volver a automático" button, which drops
  /// every manual override and recomputes — or `manual`, which applies
  /// [allocations] on top of that same recomputation.
  ///
  /// Only `coinAmount` is sent per line: `expectedFrequency` is an observation
  /// about the household's work, not a preference, and the server rejects an
  /// attempt to change it.
  Future<PersonalBudget> adjustBudget(
    String householdId, {
    required String timeZone,
    required String mode,
    String? weekKey,
    List<BudgetAllocation> allocations = const [],
  }) async {
    final data = await _api.patch(
      '${_base(householdId)}/budget',
      body: {
        'mode': mode,
        'timeZone': timeZone,
        if (weekKey != null) 'weekKey': weekKey,
        if (mode == 'manual')
          'allocations': allocations
              .map((a) => {'allocationKey': a.allocationKey, 'coinAmount': a.coinAmount})
              .toList(growable: false),
      },
    );

    final map = Map<String, dynamic>.from(data as Map);
    return PersonalBudget.fromJson(Map<String, dynamic>.from(map['weeklyBudget'] as Map));
  }

  /// Buy one streak ice from the personal wallet (PDR-019).
  ///
  /// [operationId] is generated once per tap and reused across retries, so a
  /// timeout that actually reached the server replays instead of buying a
  /// second ice. Exposed as a parameter rather than minted here: the caller
  /// owns the retry, so the caller has to own the id.
  Future<Map<String, dynamic>> buyIce(
    String householdId, {
    required String operationId,
  }) async {
    final data = await _api.post(
      '${_base(householdId)}/ice',
      body: const <String, dynamic>{},
      headers: {'Idempotency-Key': operationId},
    );
    return Map<String, dynamic>.from(data as Map);
  }

  /// Open the household's one active savings goal (PDR-018).
  ///
  /// The price is NOT sent: it comes from the server-side catalog, because a
  /// client that could name its own target would unlock a 40-coin cosmetic by
  /// declaring the target to be 1.
  Future<SavingsGoal> createSavingsGoal(
    String householdId, {
    required String itemType,
    required String itemId,
    String? operationId,
  }) async {
    final data = await _api.post(
      '${_base(householdId)}/savings-goals',
      body: {'itemType': itemType, 'itemId': itemId},
      headers: {'Idempotency-Key': operationId ?? _uuid.v4()},
    );
    final map = Map<String, dynamic>.from(data as Map);
    return SavingsGoal.fromJson(Map<String, dynamic>.from(map['goal'] as Map));
  }

  /// Move coins from the personal wallet into the goal.
  ///
  /// Never queued offline: a debit that replayed under last-write-wins could
  /// charge twice for one tap (TD-066-DESIGN §7).
  Future<SavingsGoal> contribute(
    String householdId,
    String goalId, {
    required int amount,
    required String operationId,
  }) async {
    final data = await _api.post(
      '${_base(householdId)}/savings-goals/$goalId/contributions',
      body: {'amount': amount},
      headers: {'Idempotency-Key': operationId},
    );
    final map = Map<String, dynamic>.from(data as Map);
    return SavingsGoal.fromJson(Map<String, dynamic>.from(map['goal'] as Map));
  }

  /// Cancel the goal and refund every contributor.
  ///
  /// A POST, not a DELETE: the goal survives as history with
  /// `status: 'cancelled'`, and the server would be lying if it answered a
  /// DELETE.
  ///
  /// [operationId] is required for the same reason it is on [buyIce], and is
  /// the one this method most needs: cancelling writes a refund entry per
  /// contributor, so it is a resource-creating POST under Hard Rule 13. Minted
  /// once per logical cancel and reused across retries — a fresh id per ATTEMPT
  /// would defeat the point, since the server keys the replay on it. Without
  /// it, a cancel whose response was lost to a timeout comes back 409
  /// "already cancelled" on retry, and the client cannot tell its own
  /// successful cancel from someone else's.
  Future<SavingsGoal> cancelSavingsGoal(
    String householdId,
    String goalId, {
    required String operationId,
  }) async {
    final data = await _api.post(
      '${_base(householdId)}/savings-goals/$goalId/cancel',
      headers: {'Idempotency-Key': operationId},
    );
    final map = Map<String, dynamic>.from(data as Map);
    return SavingsGoal.fromJson(Map<String, dynamic>.from(map['goal'] as Map));
  }

  /// Drop this household's cached economy — on logout, or when the cache is
  /// found to belong to someone else (TD-062).
  Future<void> clearCache(String householdId) => _cache.clearEconomyP1(householdId);
}
