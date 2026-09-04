import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/household_governance.dart';
import 'package:homesync/presentation/cubit/household_cubit.dart';

import 'fakes.dart';

/// HouseholdCubit's governance half (TD-067, PDR-022).
///
/// Two behaviours here are easy to get wrong in a way no screen would reveal.
///
/// FIRST, `isCreator` is a getter over the household the cubit holds, not a
/// stored flag. `createdBy` MOVES when ownership is transferred, and a cached
/// boolean would keep showing the admin section to whoever gave it away — and
/// hide it from whoever received it — until the next full reload.
///
/// SECOND, leaving and deleting must forget the active household. Holding on
/// to it would leave the app pointed at a household the user can no longer
/// read, so the next request 403s or 404s into an error state the user cannot
/// act on. The reset is asserted from the repository's side too, because
/// clearing the cubit without clearing the persisted id would still restore
/// the dead household on the next launch.

const _creator = 'creator';
const _other = 'other';

HouseholdCubit _cubit(FakeHouseholdRepository repo) => HouseholdCubit(repo);

/// Put a loaded household into the cubit without going through the network.
void _load(HouseholdCubit cubit, FakeHouseholdRepository repo) {
  cubit.emit(HouseholdState(
    status: HouseholdStatusUi.loaded,
    current: buildHousehold(
      createdBy: _creator,
      memberRoles: const {_creator: 'admin', _other: 'member'},
    ),
  ));
}

void main() {
  group('isCreator (PDR-022 D1)', () {
    test('is true only for the household creator', () {
      final repo = FakeHouseholdRepository();
      final cubit = _cubit(repo);
      _load(cubit, repo);

      expect(cubit.isCreator(_creator), isTrue);
      expect(cubit.isCreator(_other), isFalse);
      expect(cubit.isCreator(null), isFalse);
    });

    test('follows createdBy when ownership moves', () {
      // The reason it is a getter. A flag captured at load time would keep the
      // old owner's permissions alive on their screen.
      final repo = FakeHouseholdRepository();
      final cubit = _cubit(repo);
      _load(cubit, repo);
      expect(cubit.isCreator(_creator), isTrue);

      cubit.emit(cubit.state.copyWith(
        current: buildHousehold(
          createdBy: _other,
          memberRoles: const {_creator: 'admin', _other: 'admin'},
        ),
      ));

      expect(cubit.isCreator(_creator), isFalse);
      expect(cubit.isCreator(_other), isTrue);
    });

    test('is false with no household loaded', () {
      expect(_cubit(FakeHouseholdRepository()).isCreator(_creator), isFalse);
    });
  });

  group('role changes', () {
    blocTest<HouseholdCubit, HouseholdState>(
      'promote stores the household the server returned',
      build: () {
        final repo = FakeHouseholdRepository()
          ..governanceResult = buildHousehold(
            createdBy: _creator,
            memberRoles: const {_creator: 'admin', _other: 'admin'},
          );
        return _cubit(repo);
      },
      seed: () => HouseholdState(
        status: HouseholdStatusUi.loaded,
        current: buildHousehold(
          createdBy: _creator,
          memberRoles: const {_creator: 'admin', _other: 'member'},
        ),
      ),
      act: (cubit) => cubit.promoteMember(_other),
      verify: (cubit) {
        final member = cubit.state.current!.members
            .firstWhere((m) => m.user.id == _other);
        expect(member.isAdmin, isTrue);
        expect(cubit.state.loading, isFalse);
      },
    );

    test('promote and demote hit different endpoints', () async {
      // They produce the same shape of success, so only the call log can catch
      // them being wired the wrong way round.
      final repo = FakeHouseholdRepository()
        ..governanceResult = buildHousehold(
          createdBy: _creator,
          memberRoles: const {_creator: 'admin'},
        );
      final cubit = _cubit(repo);
      _load(cubit, repo);

      await cubit.promoteMember(_other);
      await cubit.demoteMember(_other);
      await cubit.transferOwnership(_other);

      expect(repo.governanceCalls,
          ['promote:$_other', 'demote:$_other', 'transfer:$_other']);
    });

    test('a rejected role change surfaces the server message and changes nothing',
        () async {
      // The server owns these rules (Hard Rule 3), so its refusal is the text
      // worth showing — «El creador del hogar no puede ser degradado» explains
      // the situation in a way a generic client-side string could not.
      final repo = FakeHouseholdRepository()
        ..governanceFailure =
            const ServerFailure('The household creator cannot be demoted');
      final cubit = _cubit(repo);
      _load(cubit, repo);
      final before = cubit.state.current;

      final ok = await cubit.demoteMember(_creator);

      expect(ok, isFalse);
      expect(cubit.state.error, 'The household creator cannot be demoted');
      expect(cubit.state.current, before);
      expect(cubit.state.loading, isFalse);
    });

    test('does nothing without an active household', () async {
      final repo = FakeHouseholdRepository();

      expect(await _cubit(repo).promoteMember(_other), isFalse);
      expect(repo.governanceCalls, isEmpty);
    });
  });

  group('leaving (PDR-022 D3)', () {
    test('resets the cubit and forgets the persisted household', () async {
      final repo = FakeHouseholdRepository()
        ..leaveResult = const LeaveOutcome(
          promotedUserId: _other,
          newOwnerId: _other,
        );
      final cubit = _cubit(repo);
      _load(cubit, repo);

      final outcome = await cubit.leaveHousehold();

      expect(outcome!.promotedUserId, _other);
      expect(outcome.newOwnerId, _other);
      expect(cubit.state.current, isNull);
      expect(cubit.state.status, HouseholdStatusUi.empty);
      // Without this the dead household comes back on the next launch.
      expect(repo.clearedCurrentHousehold, isTrue);
    });

    test('keeps the household when the server refuses', () async {
      // The last member cannot leave (400). Clearing local state on a refusal
      // would strand the user outside a household they are still in.
      final repo = FakeHouseholdRepository()
        ..governanceFailure = const ServerFailure(
            'You are the last member of this household. Delete the household instead of leaving it.');
      final cubit = _cubit(repo);
      _load(cubit, repo);

      final outcome = await cubit.leaveHousehold();

      expect(outcome, isNull);
      expect(cubit.state.current, isNotNull);
      expect(cubit.state.error, contains('Delete the household instead'));
      expect(repo.clearedCurrentHousehold, isFalse);
    });
  });

  group('destruction (PDR-022 D4)', () {
    DestructionStatus pending() => DestructionStatus(
          scheduled: true,
          scheduledAt: DateTime.now().add(const Duration(hours: 24)),
          scheduledBy: _creator,
        );

    test('scheduling stores the deadline', () async {
      final repo = FakeHouseholdRepository()..destructionResult = pending();
      final cubit = _cubit(repo);
      _load(cubit, repo);

      expect(await cubit.scheduleDestruction(), isTrue);
      expect(cubit.state.destruction!.scheduled, isTrue);
      expect(cubit.state.destruction!.isExpired, isFalse);
    });

    test('cancelling clears it without touching the household', () async {
      final repo = FakeHouseholdRepository()..destructionResult = pending();
      final cubit = _cubit(repo);
      _load(cubit, repo);
      await cubit.scheduleDestruction();

      expect(await cubit.cancelDestruction(), isTrue);
      expect(cubit.state.destruction!.scheduled, isFalse);
      // Nothing was destroyed, so the household is still there.
      expect(cubit.state.current, isNotNull);
    });

    test('confirming resets the cubit like leaving does', () async {
      final repo = FakeHouseholdRepository()..destructionResult = pending();
      final cubit = _cubit(repo);
      _load(cubit, repo);

      expect(await cubit.confirmDestruction(), isTrue);
      expect(cubit.state.current, isNull);
      expect(cubit.state.status, HouseholdStatusUi.empty);
      expect(repo.clearedCurrentHousehold, isTrue);
    });

    test('a failed status read is swallowed into "nothing pending"', () async {
      // This runs on entering the profile screen. An error banner about a
      // status nobody asked for would be noise, and the cost of being wrong is
      // a missing banner — every command re-checks server-side anyway.
      final repo = FakeHouseholdRepository();
      final cubit = _cubit(repo);
      _load(cubit, repo);

      await cubit.loadDestructionStatus();

      expect(cubit.state.destruction, const DestructionStatus());
      expect(cubit.state.error, isNull);
    });

    test('isExpired tracks the clock, not the moment it was fetched', () {
      expect(
        DestructionStatus(
          scheduled: true,
          scheduledAt: DateTime.now().subtract(const Duration(seconds: 1)),
        ).isExpired,
        isTrue,
      );
      expect(
        DestructionStatus(
          scheduled: true,
          scheduledAt: DateTime.now().add(const Duration(seconds: 30)),
        ).isExpired,
        isFalse,
      );
      expect(const DestructionStatus().isExpired, isFalse);
    });
  });

  group('realtime (TD-067)', () {
    test('household:destroyed resets instead of refetching a 404', () async {
      // Reloading would ask for a household that no longer exists and surface
      // the 404 as an error the user did not cause.
      final repo = FakeHouseholdRepository();
      final cubit = _cubit(repo);
      _load(cubit, repo);

      await cubit.applyRealtime('household:destroyed', {'householdId': 'h1'});

      expect(cubit.state.current, isNull);
      expect(cubit.state.status, HouseholdStatusUi.empty);
      expect(repo.clearedCurrentHousehold, isTrue);
    });

    test('the schedule events move the banner without a round trip', () async {
      final repo = FakeHouseholdRepository();
      final cubit = _cubit(repo);
      _load(cubit, repo);

      await cubit.applyRealtime('household:destruction_scheduled', {
        'householdId': 'h1',
        'scheduledAt':
            DateTime.now().add(const Duration(hours: 24)).toIso8601String(),
        'scheduledBy': _creator,
      });
      expect(cubit.state.destruction!.scheduled, isTrue);

      await cubit.applyRealtime(
        'household:destruction_cancelled',
        {'householdId': 'h1'},
      );
      expect(cubit.state.destruction!.scheduled, isFalse);
      // Never reached the network for either of them.
      expect(repo.governanceCalls, isEmpty);
    });

    test('ignores events for a different household', () async {
      final repo = FakeHouseholdRepository();
      final cubit = _cubit(repo);
      _load(cubit, repo);

      await cubit.applyRealtime(
        'household:destroyed',
        {'householdId': 'someone-elses'},
      );

      expect(cubit.state.current, isNotNull);
    });
  });
}
