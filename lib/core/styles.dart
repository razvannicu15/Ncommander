import 'package:flutter/material.dart';

import 'i18n.dart';

/// Interface styles. Classic = the Total Commander-like look with colour
/// themes; the others are the modern "floating cards" layout.
enum UiStyle { classic, aurora, porcelain, oled }

class StyleSpec {
  const StyleSpec({
    required this.brightness,
    required this.accents,
    required this.background,
    required this.surfaces,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.cardActive,
    required this.cardIdle,
    required this.idleBorder,
    required this.bar,
    this.glow = false,
    this.shadow = false,
  });

  final Brightness brightness;
  final List<int> accents;
  final Color background;

  /// lowest, low, container, high, highest — opaque, for sheets and dialogs.
  final List<int> surfaces;
  final Color onSurface, onSurfaceVariant;
  final Color cardActive, cardIdle, idleBorder, bar;

  /// Aurora: soft coloured lights behind the panels.
  final bool glow;

  /// Porcelain: cards lift off the page with a soft shadow.
  final bool shadow;

  bool get dark => brightness == Brightness.dark;

  ColorScheme scheme(Color accent) {
    final base = ColorScheme.fromSeed(seedColor: accent, brightness: brightness);
    final onAccent = ThemeData.estimateBrightnessForColor(accent) == Brightness.dark ? Colors.white : const Color(0xFF0A0C12);
    return base.copyWith(
      primary: accent,
      onPrimary: onAccent,
      surface: background,
      onSurface: onSurface,
      onSurfaceVariant: onSurfaceVariant,
      surfaceContainerLowest: Color(surfaces[0]),
      surfaceContainerLow: Color(surfaces[1]),
      surfaceContainer: Color(surfaces[2]),
      surfaceContainerHigh: Color(surfaces[3]),
      surfaceContainerHighest: Color(surfaces[4]),
      outlineVariant: dark ? const Color(0x24FFFFFF) : const Color(0xFFE1E3E8),
    );
  }
}

const styleSpecs = <UiStyle, StyleSpec>{
  UiStyle.aurora: StyleSpec(
    brightness: Brightness.dark,
    accents: [0xFFA3AEFF, 0xFF5EEAD4, 0xFFFBBF77, 0xFFF0ABFC],
    background: Color(0xFF0A0C12),
    surfaces: [0xFF0E1018, 0xFF151821, 0xFF1A1D28, 0xFF222533, 0xFF2A2E3E],
    onSurface: Color(0xFFEEF0F7),
    onSurfaceVariant: Color(0xFF9EA3B5),
    cardActive: Color(0x14FFFFFF),
    cardIdle: Color(0x0BFFFFFF),
    idleBorder: Color(0x14FFFFFF),
    bar: Color(0xC21C1F2C),
    glow: true,
  ),
  UiStyle.porcelain: StyleSpec(
    brightness: Brightness.light,
    accents: [0xFF2F5BEA, 0xFF0F8A6A, 0xFFC2410C, 0xFF7C3AED],
    background: Color(0xFFEEF0F3),
    surfaces: [0xFFFFFFFF, 0xFFF8F9FA, 0xFFF2F3F6, 0xFFEAECF0, 0xFFE2E4E9],
    onSurface: Color(0xFF15171C),
    onSurfaceVariant: Color(0xFF6B7080),
    cardActive: Color(0xFFFFFFFF),
    cardIdle: Color(0xFFF8F9FA),
    idleBorder: Color(0xFFE3E5EA),
    bar: Color(0xE6FFFFFF),
    shadow: true,
  ),
  UiStyle.oled: StyleSpec(
    brightness: Brightness.dark,
    accents: [0xFF5EEAD4, 0xFFA3AEFF, 0xFFFBBF77, 0xFF86EFAC],
    background: Color(0xFF000000),
    surfaces: [0xFF000000, 0xFF0D0F10, 0xFF131617, 0xFF1A1D1F, 0xFF222628],
    onSurface: Color(0xFFF2F4F5),
    onSurfaceVariant: Color(0xFF8A9295),
    cardActive: Color(0xFF0D0F10),
    cardIdle: Color(0xFF0A0B0C),
    idleBorder: Color(0x14FFFFFF),
    bar: Color(0xCC181C1E),
  ),
};

String styleName(UiStyle s) => switch (s) {
      UiStyle.classic => tr('Clasic', 'Classic'),
      UiStyle.aurora => 'Aurora',
      UiStyle.porcelain => tr('Porțelan', 'Porcelain'),
      UiStyle.oled => tr('Negru OLED', 'OLED black'),
    };
