import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/core/errors/failures.dart';
import 'package:homesync/data/models/economy.dart';
import 'package:homesync/presentation/cubit/pet_cubit.dart';

import 'fakes.dart';

void main() {
  group('PetCubit.load', () {
    blocTest<PetCubit, PetState>(
      'emits noPet when there is no pet and no pending request',
      build: () => PetCubit(FakePetRepository()),
      act: (cubit) => cubit.load('h1', 'me'),
      expect: () => [
        isA<PetState>().having((s) => s.status, 'status', PetStatusUi.loading),
        isA<PetState>().having((s) => s.status, 'status', PetStatusUi.noPet),
      ],
    );

    blocTest<PetCubit, PetState>(
      'emits pendingRequest with requestedByMe=true when the current user proposed it',
      build: () => PetCubit(
        FakePetRepository(pendingRequest: buildAdoptionRequest('req1', requestedBy: 'me')),
      ),
      act: (cubit) => cubit.load('h1', 'me'),
      expect: () => [
        isA<PetState>().having((s) => s.status, 'status', PetStatusUi.loading),
        isA<PetState>()
            .having((s) => s.status, 'status', PetStatusUi.pendingRequest)
            .having((s) => s.requestedByMe, 'requestedByMe', true),
      ],
    );

    blocTest<PetCubit, PetState>(
      'emits pendingRequest with requestedByMe=false when a different member proposed it',
      build: () => PetCubit(
        FakePetRepository(pendingRequest: buildAdoptionRequest('req1', requestedBy: 'other-user')),
      ),
      act: (cubit) => cubit.load('h1', 'me'),
      expect: () => [
        isA<PetState>().having((s) => s.status, 'status', PetStatusUi.loading),
        isA<PetState>()
            .having((s) => s.status, 'status', PetStatusUi.pendingRequest)
            .having((s) => s.requestedByMe, 'requestedByMe', false),
      ],
    );

    blocTest<PetCubit, PetState>(
      'emits hasPet with the pet and economy when a pet exists',
      build: () => PetCubit(
        FakePetRepository(
          pet: buildPet('p1', name: 'Michi'),
          economy: const Economy(balance: 15, dailyEarned: 5),
        ),
      ),
      act: (cubit) => cubit.load('h1', 'me'),
      expect: () => [
        isA<PetState>().having((s) => s.status, 'status', PetStatusUi.loading),
        isA<PetState>()
            .having((s) => s.status, 'status', PetStatusUi.hasPet)
            .having((s) => s.pet?.name, 'pet.name', 'Michi')
            .having((s) => s.economy.balance, 'economy.balance', 15),
      ],
    );

    blocTest<PetCubit, PetState>(
      'emits error when getPet fails',
      build: () => PetCubit(FakePetRepository(failGetPetWith: const ServerFailure('caído'))),
      act: (cubit) => cubit.load('h1', 'me'),
      expect: () => [
        isA<PetState>().having((s) => s.status, 'status', PetStatusUi.loading),
        isA<PetState>()
            .having((s) => s.status, 'status', PetStatusUi.error)
            .having((s) => s.error, 'error', 'caído'),
      ],
    );
  });

  group('PetCubit adoption flow', () {
    test('proposeAdoption calls the repository and moves to pendingRequest', () async {
      final repo = FakePetRepository();
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await cubit.proposeAdoption(species: 'dog', name: 'Firulais');

      expect(repo.adoptCalls, [
        {'species': 'dog', 'name': 'Firulais'}
      ]);
      expect(cubit.state.status, PetStatusUi.pendingRequest);
      expect(cubit.state.requestedByMe, isTrue);
    });

    test('confirmAdoption calls the repository and moves to hasPet', () async {
      final repo = FakePetRepository(
        pendingRequest: buildAdoptionRequest('req1', requestedBy: 'other-user'),
      );
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await cubit.confirmAdoption();

      expect(repo.confirmCalls, 1);
      expect(cubit.state.status, PetStatusUi.hasPet);
      expect(cubit.state.pendingRequest, isNull);
    });

    test('cancelAdoption calls the repository and moves to noPet', () async {
      final repo = FakePetRepository(
        pendingRequest: buildAdoptionRequest('req1', requestedBy: 'me'),
      );
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await cubit.cancelAdoption();

      expect(repo.cancelCalls, 1);
      expect(cubit.state.status, PetStatusUi.noPet);
    });
  });

  group('PetCubit care actions', () {
    test('feed calls the repository and updates the pet in place', () async {
      final repo = FakePetRepository(pet: buildPet('p1', hunger: 40));
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await cubit.feed();

      expect(repo.feedCalls, 1);
      expect(cubit.state.pet?.hunger, 100);
      expect(cubit.state.status, PetStatusUi.hasPet);
    });

    test('play calls the repository and updates the pet in place', () async {
      final repo = FakePetRepository(pet: buildPet('p1', mood: 40));
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await cubit.play();

      expect(repo.playCalls, 1);
      expect(cubit.state.pet?.mood, 100);
    });

    test('feed sets the error message and does not crash when the backend returns 409', () async {
      final repo = FakePetRepository(
        pet: buildPet('p1'),
        failFeedWith: const ServerFailure('cooldown', statusCode: 409),
      );
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await cubit.feed();

      expect(cubit.state.error, 'cooldown');
      expect(cubit.state.actionInProgress, isFalse);
    });
  });
}
