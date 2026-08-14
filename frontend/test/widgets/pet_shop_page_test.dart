import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:homesync/config/pet_config.dart';
import 'package:homesync/data/models/economy.dart';
import 'package:homesync/presentation/cubit/pet_cubit.dart';
import 'package:homesync/presentation/pages/pet_shop_page.dart';

import '../fakes.dart';

Widget _host(PetCubit cubit) {
  return MaterialApp(
    home: BlocProvider<PetCubit>.value(value: cubit, child: const PetShopPage()),
  );
}

void main() {
  final cheapest = kCosmeticsCatalog.first; // hat, 20 coins

  group('PetShopPage', () {
    testWidgets('renders the balance and every catalog item with its price', (tester) async {
      final cubit = PetCubit(
        FakePetRepository(pet: buildPet('p1'), economy: const Economy(balance: 100)),
      );
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      expect(find.text('100 monedas'), findsOneWidget);
      for (final cosmetic in kCosmeticsCatalog) {
        expect(find.text(cosmetic.name), findsOneWidget);
        expect(find.text('${cosmetic.price} 🪙'), findsOneWidget);
      }
      expect(find.text('Comprar'), findsNWidgets(kCosmeticsCatalog.length));
    });

    testWidgets('buying a cosmetic calls the repository and deducts the balance', (tester) async {
      final repo = FakePetRepository(
        pet: buildPet('p1'),
        economy: Economy(balance: cheapest.price + 10),
      );
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      await tester.tap(find.text('Comprar').first);
      await tester.pump();
      await tester.pump();

      expect(repo.boughtCosmeticIds, [cheapest.id]);
      expect(find.text('10 monedas'), findsOneWidget);
    });

    testWidgets('the buy button is disabled when the balance is insufficient', (tester) async {
      final cubit = PetCubit(
        FakePetRepository(pet: buildPet('p1'), economy: Economy(balance: cheapest.price - 1)),
      );
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      final button = tester.widget<ElevatedButton>(
        find.ancestor(of: find.text('Comprar').first, matching: find.byType(ElevatedButton)),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('an owned cosmetic shows "Usar" instead of "Comprar"', (tester) async {
      final cubit = PetCubit(
        FakePetRepository(
          pet: buildPet('p1', cosmetics: [cheapest.id]),
          economy: const Economy(balance: 0),
        ),
      );
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      expect(find.text('Usar'), findsOneWidget);
      expect(find.text('Comprar'), findsNWidgets(kCosmeticsCatalog.length - 1));
    });

    testWidgets('setting a cosmetic active calls the repository and shows "En uso"', (tester) async {
      final repo = FakePetRepository(
        pet: buildPet('p1', cosmetics: [cheapest.id]),
        economy: const Economy(balance: 0),
      );
      final cubit = PetCubit(repo);
      await cubit.load('h1', 'me');

      await tester.pumpWidget(_host(cubit));
      await tester.pump();

      await tester.tap(find.text('Usar'));
      await tester.pump();
      await tester.pump();

      expect(repo.activeCosmeticCalls, [cheapest.id]);
      expect(find.text('En uso'), findsOneWidget);
      expect(find.text('Usar'), findsNothing);
    });
  });
}
