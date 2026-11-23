import 'package:flutter/material.dart';

import 'i18n.dart';

/// Surfaces and text tones for one brightness, lightest layer first.
class Surf {
  const Surf(this.c, {required this.on, required this.onVariant, required this.line});
  final List<int> c; // surface, lowest, low, container, high, highest
  final int on, onVariant, line;
}

/// A background: the character of the app (warm, neutral, cool, black…).
/// Colour comes separately from the [Accent], so any pair works.
class BaseTheme {
  const BaseTheme(this.id, this.ro, this.en, {required this.light, required this.dark});
  final String id, ro, en;
  final Surf light, dark;
  String get name => tr(ro, en);
}

class Accent {
  const Accent(this.id, this.ro, this.en, this.color);
  final String id, ro, en;
  final Color color;
  String get name => tr(ro, en);
}

const baseThemes = <BaseTheme>[
  BaseTheme('paper', 'Hârtie', 'Paper',
      light: Surf([0xFFFFFBF7, 0xFFFFFFFF, 0xFFFBF4EC, 0xFFF5ECE2, 0xFFEFE5DA, 0xFFE8DDD1], on: 0xFF221A12, onVariant: 0xFF5A4E42, line: 0xFFD9CCBE),
      dark: Surf([0xFF17130F, 0xFF120F0C, 0xFF1E1915, 0xFF241E19, 0xFF2C251F, 0xFF352D26], on: 0xFFEDE2D8, onVariant: 0xFFC9BCAF, line: 0xFF4A4038)),
  BaseTheme('graphite', 'Grafit', 'Graphite',
      light: Surf([0xFFF8F8F9, 0xFFFFFFFF, 0xFFF2F2F4, 0xFFECECEF, 0xFFE6E6E9, 0xFFDFDFE3], on: 0xFF1B1C1E, onVariant: 0xFF4A4C50, line: 0xFFD5D6DA),
      dark: Surf([0xFF141516, 0xFF0F1011, 0xFF1A1B1D, 0xFF1F2022, 0xFF26272A, 0xFF2E2F32], on: 0xFFE6E7E9, onVariant: 0xFFB9BBBF, line: 0xFF3A3C40)),
  BaseTheme('slate', 'Ardezie', 'Slate',
      light: Surf([0xFFF6F8FB, 0xFFFFFFFF, 0xFFEEF2F7, 0xFFE7ECF3, 0xFFE0E6EE, 0xFFD8DFE9], on: 0xFF151C26, onVariant: 0xFF46505E, line: 0xFFCDD5E0),
      dark: Surf([0xFF0F141B, 0xFF0B0F15, 0xFF151B23, 0xFF1A212A, 0xFF212933, 0xFF29323D], on: 0xFFE2E8F0, onVariant: 0xFFB3BDCA, line: 0xFF333D49)),
  BaseTheme('nord', 'Nord', 'Nord',
      light: Surf([0xFFECEFF4, 0xFFF5F7FA, 0xFFE5E9F0, 0xFFDFE4EC, 0xFFD8DEE9, 0xFFCFD6E3], on: 0xFF2E3440, onVariant: 0xFF4C566A, line: 0xFFC5CDDA),
      dark: Surf([0xFF2E3440, 0xFF292E39, 0xFF323845, 0xFF3B4252, 0xFF434C5E, 0xFF4C566A], on: 0xFFECEFF4, onVariant: 0xFFD8DEE9, line: 0xFF4C566A)),
  BaseTheme('sage', 'Salvie', 'Sage',
      light: Surf([0xFFF7F9F6, 0xFFFFFFFF, 0xFFF0F4EF, 0xFFE9EFE8, 0xFFE2E9E1, 0xFFDAE2D9], on: 0xFF1A1F1A, onVariant: 0xFF4A544A, line: 0xFFCFD8CE),
      dark: Surf([0xFF121612, 0xFF0E110E, 0xFF181D18, 0xFF1D231D, 0xFF242B24, 0xFF2C342C], on: 0xFFE3EAE2, onVariant: 0xFFB8C2B7, line: 0xFF364036)),
  BaseTheme('ink', 'Cerneală', 'Ink',
      light: Surf([0xFFF5F7FF, 0xFFFFFFFF, 0xFFEDF0FB, 0xFFE6EAF7, 0xFFDFE4F3, 0xFFD7DDEF], on: 0xFF141A2E, onVariant: 0xFF444C66, line: 0xFFCBD2E6),
      dark: Surf([0xFF0B1020, 0xFF070B17, 0xFF111729, 0xFF161D31, 0xFF1D253B, 0xFF252E46], on: 0xFFE1E6F5, onVariant: 0xFFB0B8D0, line: 0xFF2F3852)),
  BaseTheme('oled', 'Negru OLED', 'OLED black',
      light: Surf([0xFFFFFFFF, 0xFFFFFFFF, 0xFFF6F7F8, 0xFFF0F1F2, 0xFFEAEBED, 0xFFE3E5E7], on: 0xFF111214, onVariant: 0xFF45484C, line: 0xFFDADCDF),
      dark: Surf([0xFF000000, 0xFF000000, 0xFF0B0C0D, 0xFF111314, 0xFF181A1C, 0xFF202325], on: 0xFFECEEF0, onVariant: 0xFFB4B8BC, line: 0xFF2A2D30)),
];

/// No pink unless asked for.
const accents = <Accent>[
  Accent('amber', 'Chihlimbar', 'Amber', Color(0xFFD9822B)),
  Accent('coral', 'Coral', 'Coral', Color(0xFFE5604D)),
  Accent('red', 'Rubin', 'Ruby', Color(0xFFC8383B)),
  Accent('olive', 'Măslin', 'Olive', Color(0xFF7D8F2A)),
  Accent('green', 'Verde', 'Green', Color(0xFF2E9D5B)),
  Accent('teal', 'Turcoaz', 'Teal', Color(0xFF0E9AA7)),
  Accent('blue', 'Albastru', 'Blue', Color(0xFF2F6FE4)),
  Accent('violet', 'Violet', 'Violet', Color(0xFF7C5CE0)),
];

/// Wallpaper colour from Android 12+, when available ("system" accent).
Color? systemAccent;

BaseTheme baseById(String id) => baseThemes.firstWhere((t) => t.id == id, orElse: () => baseThemes.first);

Color accentColor(String id) =>
    id == 'system' ? (systemAccent ?? accents.first.color) : accents.firstWhere((a) => a.id == id, orElse: () => accents.first).color;

/// Accent drives every coloured role; the background supplies surfaces and text.
ColorScheme buildScheme(BaseTheme base, Color accent, Brightness b) {
  final s = b == Brightness.light ? base.light : base.dark;
  final a = ColorScheme.fromSeed(seedColor: accent, brightness: b, dynamicSchemeVariant: DynamicSchemeVariant.fidelity);
  final on = Color(s.on), line = Color(s.line);
  return a.copyWith(
    surface: Color(s.c[0]),
    surfaceContainerLowest: Color(s.c[1]),
    surfaceContainerLow: Color(s.c[2]),
    surfaceContainer: Color(s.c[3]),
    surfaceContainerHigh: Color(s.c[4]),
    surfaceContainerHighest: Color(s.c[5]),
    surfaceBright: Color(s.c[b == Brightness.light ? 1 : 5]),
    surfaceDim: Color(s.c[b == Brightness.light ? 5 : 1]),
    onSurface: on,
    onSurfaceVariant: Color(s.onVariant),
    outlineVariant: line,
    outline: Color.lerp(line, on, 0.35),
    surfaceTint: Colors.transparent,
  );
}

/// Old single-theme ids map onto a background + accent pair.
(String, String) migrateTheme(String old) => switch (old) {
      'ocean' => ('slate', 'teal'),
      'graphite' => ('graphite', 'blue'),
      'forest' => ('sage', 'green'),
      'dusk' => ('ink', 'violet'),
      'nord' => ('nord', 'blue'),
      'black' => ('oled', 'teal'),
      _ => ('paper', 'amber'),
    };

/// Header colour of the active panel: a clear wash of the accent.
Color activeHeader(ColorScheme cs) =>
    Color.alphaBlend(cs.primary.withValues(alpha: cs.brightness == Brightness.light ? 0.17 : 0.24), cs.surfaceContainer);
