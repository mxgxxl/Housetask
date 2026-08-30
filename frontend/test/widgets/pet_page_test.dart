import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/presentation/cubit/economy_p1_cubit.dart';
import 'package:homesync/presentation/cubit/pet_cubit.dart';
import 'package:homesync/presentation/pages/pet_page.dart';

import '../fakes.dart';

/// TD-066 F2: PetPage now hosts the "Mi progreso" section, which reads
/// EconomyP1Cubit. Defaulted to a fresh one — its state is `initial`, so the
/// section renders a zero-height box and every assertion below is unaffected.
Widget _host(PetCubit cubit, {EconomyP1Cubit? economyP1Cubit}) {
  return MaterialApp(
    home: MultiBlocProvider(
      providers: [
        BlocProvider<PetCubit>.value(value: cubit),
        BlocProvider<EconomyP1Cubit>.value(
          value: economyP1Cubit ??
              EconomyP1Cubit(
                FakeEconomyP1Repository(),
                connectivity: FakeConnectivityService(),
              ),
        ),
      ],
      child: const PetPage(),
    ),
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

  // PDR-001 A4: live countdown — Timer.periodic(1s) in _LiveCareStats.
  group('PetPage — live cooldown countdown', () {
    testWidgets('ticks the remaining-time label down as the cooldown elapses', (tester) async {
      final lastFedAt = DateTime.now().subtract(const Duration(minutes: 58));
      final cubit = PetCubit(FakePetRepository(pet: buildPet('p1', lastFedAt: lastFedAt)));
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      String textOf(Finder finder) =>
          (tester.widget<Text>(finder)).data ?? '';
      final before = textOf(find.textContaining('Disponible en'));

      // 90s of ticks: crosses at least one more full minute boundary, so
      // the "Disponible en N min" label must have counted down.
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      final after = textOf(find.textContaining('Disponible en'));
      expect(after, isNot(before));
    });

    testWidgets('ticks the countdown to zero and enables the button once the cooldown expires',
        (tester) async {
      // 3s left on a 1h cooldown — comfortably crossed by the loop below,
      // but non-zero at mount so the initial state is still "disabled".
      final lastFedAt =
          DateTime.now().subtract(const Duration(hours: 1)).add(const Duration(seconds: 3));
      final cubit = PetCubit(FakePetRepository(pet: buildPet('p1', lastFedAt: lastFedAt)));
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      ElevatedButton feedButton() => tester.widget<ElevatedButton>(
            find.ancestor(of: find.text('Alimentar'), matching: find.byType(ElevatedButton)),
          );

      expect(feedButton().onPressed, isNull);
      expect(find.textContaining('Disponible en'), findsOneWidget);

      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(seconds: 1));
      }

      expect(feedButton().onPressed, isNotNull);
      expect(find.textContaining('Disponible en'), findsNothing);
    });

    testWidgets('disposes the timer when the page is removed from the tree', (tester) async {
      final cubit = PetCubit(FakePetRepository(pet: buildPet('p1')));
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      // Replacing the tree unmounts _LiveCareStatsState. If dispose() did
      // not cancel its Timer.periodic, flutter_test's binding fails this
      // test on teardown with "A Timer is still pending" — so a clean pass
      // here is itself the assertion that the timer was cancelled.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pumpAndSettle();
    });
  });
}
