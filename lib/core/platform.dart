import 'dart:io';

/// Desktop layout (mouse, keyboard, denser rows): the Windows build.
bool get desktop => Platform.isWindows;

/// Sizes (icons, row padding) and text get a bit denser on the desktop.
double get dz => desktop ? 0.72 : 1.0;
double get fz => desktop ? 0.9 : 1.0;
