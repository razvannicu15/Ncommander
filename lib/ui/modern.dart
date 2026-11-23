import 'dart:ui';

import 'package:flutter/material.dart';

import '../core/styles.dart';
import '../services/store.dart';

/// Page background of the modern styles: soft coloured lights for Aurora,
/// a plain ground for the others.
class StyleBackground extends StatelessWidget {
  const StyleBackground({super.key, required this.spec, required this.accent});
  final StyleSpec spec;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    if (!spec.glow) return ColoredBox(color: spec.background);
    Widget blob(Color c, double size, double opacity) => Container(
          width: size,
          height: size,
          decoration: BoxDecoration(shape: BoxShape.circle, color: c.withValues(alpha: opacity)),
        );
    return ColoredBox(
      color: spec.background,
      child: LayoutBuilder(builder: (_, c) {
        final w = c.maxWidth, h = c.maxHeight;
        return ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 80, sigmaY: 80, tileMode: TileMode.decal),
          child: Stack(children: [
            Positioned(left: -w * 0.35, top: -h * 0.12, child: blob(accent, w * 1.0, 0.34)),
            Positioned(right: -w * 0.4, top: h * 0.36, child: blob(const Color(0xFF1FB5A6), w * 0.85, 0.24)),
            Positioned(left: -w * 0.15, bottom: -h * 0.15, child: blob(const Color(0xFFE0873A), w * 0.75, 0.2)),
          ]),
        );
      }),
    );
  }
}

/// The floating card a panel lives in.
BoxDecoration panelCard(StyleSpec spec, Color accent, {required bool active}) {
  final radius = BorderRadius.circular(28);
  if (spec.shadow) {
    return BoxDecoration(
      color: active ? spec.cardActive : spec.cardIdle,
      borderRadius: radius,
      border: Border.all(color: active ? accent : spec.idleBorder, width: active ? 2 : 1),
      boxShadow: active
          ? const [
              BoxShadow(color: Color(0x0F141828), blurRadius: 2, offset: Offset(0, 1)),
              BoxShadow(color: Color(0x14141828), blurRadius: 30, offset: Offset(0, 10)),
            ]
          : null,
    );
  }
  return BoxDecoration(
    color: active ? spec.cardActive : spec.cardIdle,
    borderRadius: radius,
    border: Border.all(color: active ? accent.withValues(alpha: 0.6) : spec.idleBorder, width: active ? 1.5 : 1),
    boxShadow: active && spec.glow
        ? [
            BoxShadow(color: accent.withValues(alpha: 0.10), spreadRadius: 4),
            const BoxShadow(color: Color(0x59000000), blurRadius: 40, offset: Offset(0, 18)),
          ]
        : null,
  );
}

/// Translucent pill used by the floating bar and its buttons.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 32, this.padding = EdgeInsets.zero, this.height});
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final double? height;

  @override
  Widget build(BuildContext context) {
    final spec = store.spec!;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
        child: Container(
          height: height,
          padding: padding,
          decoration: BoxDecoration(
            color: spec.bar,
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: spec.dark ? const Color(0x1AFFFFFF) : const Color(0xE6FFFFFF)),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Soft drop shadow under floating elements.
List<BoxShadow> floatShadow(StyleSpec spec) => [
      BoxShadow(color: spec.dark ? const Color(0x73000000) : const Color(0x24141828), blurRadius: 28, offset: const Offset(0, 12)),
    ];

/// Ring gauge for storage usage.
class Ring extends StatelessWidget {
  const Ring({super.key, required this.value, required this.color, this.size = 62});
  final double value;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            value: value.clamp(0, 1),
            strokeWidth: 7,
            strokeCap: StrokeCap.round,
            color: color,
            backgroundColor: cs.onSurface.withValues(alpha: 0.10),
          ),
        ),
        Text('${(value * 100).round()}%', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}
