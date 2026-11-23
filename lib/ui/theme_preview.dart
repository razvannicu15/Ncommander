import 'package:flutter/material.dart';

import '../core/themes.dart';

/// A miniature commander drawn in [scheme]: header, two panels with rows,
/// bottom bar. Tapping picks the theme.
class ThemePreview extends StatelessWidget {
  const ThemePreview({super.key, required this.scheme, required this.name, required this.selected, required this.onTap});
  final ColorScheme scheme;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = scheme;
    final outer = Theme.of(context).colorScheme;
    const w = 104.0, h = 140.0;

    Widget row(Color icon, double nameW, {bool sel = false}) => Container(
          height: 11,
          color: sel ? cs.primary.withValues(alpha: 0.16) : null,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: icon, borderRadius: BorderRadius.circular(2.5))),
            const SizedBox(width: 4),
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: nameW,
                  height: 3,
                  decoration: BoxDecoration(color: (sel ? cs.primary : cs.onSurface).withValues(alpha: 0.55), borderRadius: BorderRadius.circular(2)),
                ),
              ),
            ),
          ]),
        );

    Widget line() => Container(height: 0.6, margin: const EdgeInsets.only(left: 16), color: cs.outlineVariant.withValues(alpha: 0.6));

    Widget panel({required bool active, required List<Widget> rows}) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Container(
              height: 13,
              decoration: BoxDecoration(
                color: active ? activeHeader(cs) : cs.surfaceContainerLow,
                border: Border(bottom: BorderSide(color: active ? cs.primary : cs.outlineVariant, width: active ? 1.4 : 0.6)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              alignment: Alignment.centerLeft,
              child: Container(width: 26, height: 3, decoration: BoxDecoration(color: (active ? cs.primary : cs.onSurfaceVariant).withValues(alpha: active ? 0.9 : 0.6), borderRadius: BorderRadius.circular(2))),
            ),
            Opacity(
              opacity: active ? 1 : 0.62,
              child: Column(children: [for (var i = 0; i < rows.length; i++) ...[rows[i], if (i < rows.length - 1) line()]]),
            ),
          ]),
        );

    final folder = cs.primary;
    return GestureDetector(
      onTap: onTap,
      child: Column(children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: w,
          height: h,
          padding: const EdgeInsets.all(2.5),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: selected ? outer.primary : outer.outlineVariant.withValues(alpha: 0.6), width: selected ? 2.5 : 1),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Container(
              color: cs.surface,
              child: Stack(children: [
                Column(children: [
                  panel(active: true, rows: [
                    row(folder, 34),
                    row(const Color(0xFF2E9E5B), 40, sel: true),
                    row(const Color(0xFFD23F31), 30),
                  ]),
                  Container(height: 0.8, color: cs.outlineVariant),
                  panel(active: false, rows: [
                    row(const Color(0xFF2E9E5B), 38),
                    row(const Color(0xFF2E9E5B), 32),
                    row(const Color(0xFF8E5BD8), 24),
                  ]),
                  Container(
                    height: 16,
                    decoration: BoxDecoration(
                      color: cs.surfaceContainer,
                      border: Border(top: BorderSide(color: cs.outlineVariant.withValues(alpha: 0.6), width: 0.6)),
                    ),
                    child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                      for (var i = 0; i < 5; i++)
                        Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: (i == 4 ? cs.error : cs.onSurface).withValues(alpha: i == 4 ? 0.8 : 0.5),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                    ]),
                  ),
                ]),
                if (selected)
                  Positioned(
                    right: 5,
                    top: 18,
                    child: Container(
                      width: 18,
                      height: 18,
                      decoration: BoxDecoration(color: outer.primary, shape: BoxShape.circle),
                      child: Icon(Icons.check_rounded, size: 13, color: outer.onPrimary),
                    ),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(name,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? outer.primary : outer.onSurfaceVariant,
            )),
      ]),
    );
  }
}

