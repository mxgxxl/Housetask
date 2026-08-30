import 'package:flutter/material.dart';

import '../../config/theme.dart';

/// The shape every modal-class P1 celebration takes: a glyph, a heading, a
/// sentence, the unlocks it came with, and one way out.
///
/// Extracted in TD-066 F3, when the household track needed the same card with
/// different words. What varies between a personal level-up and a shared one
/// is entirely COPY — «¡Subiste de nivel!» against «Lo habéis conseguido
/// juntos», a title against a shared cosmetic — and copy is the one thing
/// UX-P1-SPEC pins down exactly. Two hand-maintained cards would let the two
/// tracks drift apart in padding and type while the spec says they are the
/// same weight of moment (§3: the intensity of a celebration is inverse to
/// how often the event happens, and both of these are rare).
///
/// ── Why a light overlay and not confetti ─────────────────────────────────
/// §3 puts a level at modal intensity — above the completion chip and the ice
/// banner, below nothing in P1's scope — and owner decision D4 asks for
/// something coherent with the banners already in the app. So: a small card,
/// not a full-screen takeover.
class CelebrationDialog extends StatelessWidget {
  final String emoji;
  final String title;
  final String message;

  /// Rendered as chips under [unlocksLabel]; empty hides the whole block.
  final List<String> unlocks;
  final String unlocksLabel;
  final String buttonLabel;

  const CelebrationDialog({
    super.key,
    required this.emoji,
    required this.title,
    required this.message,
    this.unlocks = const [],
    this.unlocksLabel = 'Has desbloqueado',
    this.buttonLabel = 'Genial',
  });

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emoji, style: const TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            if (unlocks.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                unlocksLabel,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final unlock in unlocks)
                    Chip(
                      label: Text(unlock),
                      backgroundColor:
                          AppColors.secondary.withValues(alpha: 0.12),
                      labelStyle: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: AppColors.secondary,
                      ),
                    ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(buttonLabel),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
