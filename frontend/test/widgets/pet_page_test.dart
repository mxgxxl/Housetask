import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/presentation/cubit/pet_cubit.dart';
import 'package:homesync/presentation/pages/pet_page.dart';

import '../fakes.dart';

Widget _host(PetCubit cubit) {
  return MaterialApp(
    home: BlocProvider<PetCubit>.value(value: cubit, child: const PetPage()),
  );
}

void main() {
  group('PetPage — noPet state', () {
    testWidgets('renders the adoption proposal form', (tester) async {
      final cubit = PetCubit(FakePetRepository());
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      expect(find.text('Adopten una mascota juntos'), findsOneWidget);
      expect(find.text('Proponer adopción'), findsOneWidget);
      expect(find.text('Gato'), findsOneWidget);
      expect(find.text('Perro'), findsOneWidget);
    });

    testWidgets('proposing an adoption calls the repository with the chosen species and name',
        (tester) async {
      final repo = FakePetRepository();
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      await tester.tap(find.text('Perro'));
      await tester.pump();
      await tester.enterText(find.byType(TextField), 'Firulais');
      await tester.pump();
      await tester.tap(find.text('Proponer adopción'));
      await tester.pump();
      await tester.pump();

      expect(repo.adoptCalls, [
        {'species': 'dog', 'name': 'Firulais'}
      ]);
      expect(find.text('Esperando confirmación de tu pareja'), findsOneWidget);
    });
  });

  group('PetPage — pendingRequest state', () {
    testWidgets('shows "waiting" and no confirm button when requestedByMe', (tester) async {
      final cubit = PetCubit(
        FakePetRepository(pendingRequest: buildAdoptionRequest('req1', requestedBy: 'me')),
      );
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      expect(find.text('Esperando confirmación de tu pareja'), findsOneWidget);
      expect(find.text('Confirmar adopción'), findsNothing);
      expect(find.text('Cancelar'), findsOneWidget);
    });

    testWidgets('shows the confirm button when the other member requested it', (tester) async {
      final cubit = PetCubit(
        FakePetRepository(
          pendingRequest: buildAdoptionRequest('req1', requestedBy: 'other-user'),
        ),
      );
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      expect(find.text('Confirmar adopción'), findsOneWidget);
    });

    testWidgets('confirming calls the repository and switches to hasPet', (tester) async {
      final repo = FakePetRepository(
        pendingRequest: buildAdoptionRequest('req1', requestedBy: 'other-user'),
      );
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();
      await tester.tap(find.text('Confirmar adopción'));
      await tester.pump();
      await tester.pump();

      expect(repo.confirmCalls, 1);
      expect(find.text('Firulais'), findsOneWidget);
    });

    testWidgets('cancelling calls the repository and switches to noPet', (tester) async {
      final repo = FakePetRepository(
        pendingRequest: buildAdoptionRequest('req1', requestedBy: 'me'),
      );
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();
      await tester.tap(find.text('Cancelar'));
      await tester.pump();
      await tester.pump();

      expect(repo.cancelCalls, 1);
      expect(find.text('Adopten una mascota juntos'), findsOneWidget);
    });
  });

  group('PetPage — hasPet state', () {
    testWidgets('renders the pet name, emoji, and stat bars', (tester) async {
      final cubit = PetCubit(FakePetRepository(pet: buildPet('p1', name: 'Michi', hunger: 70, mood: 40)));
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      expect(find.text('Michi'), findsOneWidget);
      expect(find.text('🐱'), findsOneWidget);
      expect(find.text('70%'), findsOneWidget);
      expect(find.text('40%'), findsOneWidget);
      expect(find.text('Alimentar'), findsOneWidget);
      expect(find.text('Jugar'), findsOneWidget);
    });

    testWidgets('feed and play buttons call the repository and update stats', (tester) async {
      final repo = FakePetRepository(pet: buildPet('p1', hunger: 50, mood: 50));
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      await tester.tap(find.text('Alimentar'));
      await tester.pump();
      await tester.pump();
      expect(repo.feedCalls, 1);
      expect(find.text('100%'), findsOneWidget);

      await tester.tap(find.text('Jugar'));
      await tester.pump();
      await tester.pump();
      expect(repo.playCalls, 1);
    });

    testWidgets('feed button is disabled and shows remaining time during cooldown', (tester) async {
      final cubit = PetCubit(
        FakePetRepository(pet: buildPet('p1', lastFedAt: DateTime.now())),
      );
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      final button = tester.widget<ElevatedButton>(
        find.ancestor(of: find.text('Alimentar'), matching: find.byType(ElevatedButton)),
      );
      expect(button.onPressed, isNull);
      expect(find.textContaining('Disponible en'), findsOneWidget);
    });

    testWidgets('feed button is enabled when the cooldown has elapsed', (tester) async {
      final longAgo = DateTime.now().subtract(const Duration(hours: 5));
      final cubit = PetCubit(
        FakePetRepository(pet: buildPet('p1', lastFedAt: longAgo)),
      );
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      final button = tester.widget<ElevatedButton>(
        find.ancestor(of: find.text('Alimentar'), matching: find.byType(ElevatedButton)),
      );
      expect(button.onPressed, isNotNull);
      expect(find.textContaining('Disponible en'), findsNothing);
    });
  });
}
