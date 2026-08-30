/// `title:constante` → «Constante», `cosmetic:dragon_skin` → «Dragon skin».
///
/// Both P1 tracks need this and neither can avoid it: the server sends
/// namespaced unlock ids and no display names, so something has to humanise
/// them rather than print `cosmetic:dragon_skin` at a member. An unrecognised
/// shape falls back to the id itself instead of vanishing — a badge nobody
/// can read still beats a badge that silently disappeared.
///
/// Lifted out of the personal section in TD-066 F3, when the household track
/// needed the identical mapping. Two copies would drift, and they would drift
/// in the direction of showing two different names for the same unlock.
///
/// This is a stopgap, not a design: an unlock's display name belongs in a
/// catalog the server owns, alongside its icon and description. See the PR's
/// Proposed Improvements.
String unlockLabel(String unlock) {
  final value = unlock.contains(':') ? unlock.split(':').last : unlock;
  if (value.isEmpty) return unlock;
  final spaced = value.replaceAll('_', ' ').replaceAll('-', ' ');
  return spaced[0].toUpperCase() + spaced.substring(1);
}
