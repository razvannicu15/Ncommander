import 'package:flutter/material.dart';

import 'i18n.dart';

/// A hand-tuned look: seed + scheme style, with optional surface overrides
/// for the light and dark variants. Every theme works in both modes.
class AppTheme {
  const AppTheme(this.id, this.ro, this.en, this.seed,
      {this.variant = DynamicSchemeVariant.tonalSpot, this.light, this.dark});

  final String id, ro, en;
  final Color seed;
  final DynamicSchemeVariant variant;
  final ColorScheme Function(ColorScheme)? light, dark;

  String get name => tr(ro, en);

  ColorScheme scheme(Brightness b) {
    final base = ColorScheme.fromSeed(seedColor: seed, brightness: b, dynamicSchemeVariant: variant);
    final f = b == Brightness.light ? light : dark;
    return f == null ? base : f(base);
  }
}

ColorScheme _surfaces(ColorScheme s, List<int> c) => s.copyWith(
      surface: Color(c[0]),
      surfaceContainerLowest: Color(c[1]),
      surfaceContainerLow: Color(c[2]),
      surfaceContainer: Color(c[3]),
      surfaceContainerHigh: Color(c[4]),
      surfaceContainerHighest: Color(c[5]),
    );

/// The curated set (no pink unless asked for).
final appThemes = <AppTheme>[
  // norAz amber: warm, the app's own colour.
  const AppTheme('amber', 'Chihlimbar', 'Amber', Color(0xFFD9822B)),

  // Calm blue-teal, crisp surfaces.
  AppTheme('ocean', 'Ocean', 'Ocean', const Color(0xFF00708F),
      light: (s) => _surfaces(s, [0xFFF7FAFC, 0xFFFFFFFF, 0xFFF0F5F8, 0xFFE9F0F4, 0xFFE2EAEF, 0xFFDAE4EA]),
      dark: (s) => _surfaces(s, [0xFF0E1519, 0xFF0A1013, 0xFF131C21, 0xFF172227, 0xFF1D2A30, 0xFF243238])),

  // Almost monochrome with a quiet blue accent: the "pro tool" look.
  AppTheme('graphite', 'Grafit', 'Graphite', const Color(0xFF4F7BB5),
      variant: DynamicSchemeVariant.neutral,
      light: (s) => _surfaces(s, [0xFFF8F8F9, 0xFFFFFFFF, 0xFFF2F2F4, 0xFFECECEF, 0xFFE6E6E9, 0xFFDFDFE3])
          .copyWith(primary: const Color(0xFF3D6AA8), primaryContainer: const Color(0xFFDCE6F5)),
      dark: (s) => _surfaces(s, [0xFF141516, 0xFF0F1011, 0xFF1A1B1D, 0xFF1F2022, 0xFF26272A, 0xFF2E2F32])
          .copyWith(primary: const Color(0xFF9DBEEB), primaryContainer: const Color(0xFF2A3D57))),

  // Soft sage green.
  const AppTheme('forest', 'Pădure', 'Forest', Color(0xFF3A7D57)),

  // Indigo dusk, a little more colourful.
  const AppTheme('dusk', 'Amurg', 'Dusk', Color(0xFF5C5FD6), variant: DynamicSchemeVariant.vibrant),

  // Nord palette: arctic greys, frost blue.
  AppTheme('nord', 'Nord', 'Nord', const Color(0xFF5E81AC),
      light: (s) => _surfaces(s, [0xFFECEFF4, 0xFFF5F7FA, 0xFFE5E9F0, 0xFFDFE4EC, 0xFFD8DEE9, 0xFFCFD6E3]).copyWith(
            primary: const Color(0xFF5E81AC),
            onPrimary: Colors.white,
            primaryContainer: const Color(0xFFD3DEEC),
            onSurface: const Color(0xFF2E3440),
            onSurfaceVariant: const Color(0xFF4C566A),
            tertiary: const Color(0xFFB48EAD),
          ),
      dark: (s) => _surfaces(s, [0xFF2E3440, 0xFF292E39, 0xFF323845, 0xFF3B4252, 0xFF434C5E, 0xFF4C566A]).copyWith(
            primary: const Color(0xFF88C0D0),
            onPrimary: const Color(0xFF2E3440),
            primaryContainer: const Color(0xFF3E5A6B),
            onSurface: const Color(0xFFECEFF4),
            onSurfaceVariant: const Color(0xFFD8DEE9),
            secondaryContainer: const Color(0xFF434C5E),
            onSecondaryContainer: const Color(0xFFE5E9F0),
            outlineVariant: const Color(0xFF4C566A),
            tertiary: const Color(0xFFB48EAD),
          )),

  // True black for OLED screens, cyan accent; clean white by day.
  AppTheme('black', 'Negru OLED', 'OLED black', const Color(0xFF00A5C0),
      light: (s) => _surfaces(s, [0xFFFFFFFF, 0xFFFFFFFF, 0xFFF6F7F8, 0xFFF0F1F2, 0xFFEAEBED, 0xFFE3E5E7]),
      dark: (s) => _surfaces(s, [0xFF000000, 0xFF000000, 0xFF0B0C0D, 0xFF111314, 0xFF181A1C, 0xFF202325])
          .copyWith(outlineVariant: const Color(0xFF2A2D30))),
];

AppTheme themeById(String id) => appThemes.firstWhere((t) => t.id == id, orElse: () => appThemes.first);
