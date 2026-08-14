/// Client-side mirror of backend/src/config/economy.ts's PDR-001 constants.
///
/// There is no GET endpoint exposing the cosmetics catalog or the cooldown
/// windows — the backend treats them as internal tuning, not API surface —
/// so the shop and the feed/play cooldown countdown need a local copy to
/// render anything at all. This duplication is a known gap (see the A3
/// commit notes): a catalog/config endpoint would remove it, but Fase A's
/// "tienda pequeña" scope doesn't yet justify the extra endpoint.
/// Keep these values in sync with backend/src/config/economy.ts by hand.
library;

class Cosmetic {
  final String id;
  final String name;
  final int price;
  final String emoji;

  const Cosmetic({
    required this.id,
    required this.name,
    required this.price,
    required this.emoji,
  });
}

/// Mirrors backend COSMETICS exactly (id/name/price) plus a placeholder
/// emoji per item — the backend has no concept of "emoji", art is a
/// frontend-only presentation detail (PDR-001 A3: emoji placeholder,
/// Rive/Lottie deferred).
const List<Cosmetic> kCosmeticsCatalog = [
  Cosmetic(id: 'hat', name: 'Sombrero', price: 20, emoji: '🎩'),
  Cosmetic(id: 'scarf', name: 'Bufanda', price: 30, emoji: '🧣'),
  Cosmetic(id: 'glasses', name: 'Gafas', price: 40, emoji: '🕶️'),
];

/// Mirrors backend FEED_COOLDOWN_HOURS.
const int kFeedCooldownHours = 1;

/// Mirrors backend PLAY_COOLDOWN_HOURS.
const int kPlayCooldownHours = 1;

/// Mirrors backend HUNGER_DECAY_PER_HOUR — used for the live countdown's
/// client-side decay extrapolation (PDR-001 A4, see pet_page.dart).
const int kHungerDecayPerHour = 2;

/// Mirrors backend MOOD_DECAY_PER_HOUR.
const int kMoodDecayPerHour = 2;

/// Species → placeholder emoji (PDR-001 A3: art is emoji, Rive/Lottie later).
const Map<String, String> kSpeciesEmoji = {
  'cat': '🐱',
  'dog': '🐶',
};
