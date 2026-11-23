import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/i18n.dart';
import 'core/themes.dart';
import 'models/panel.dart';
import 'services/native.dart';
import 'services/store.dart';
import 'ui/commander_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  Native.init();
  await store.load();
  await volumes.refresh();
  accessGranted = await Native.hasAccess();
  runApp(const NcommanderApp());
}

/// Survives the app rebuild that a language change causes.
bool accessGranted = false;

class NcommanderApp extends StatelessWidget {
  const NcommanderApp({super.key});

  static ThemeData theme(Brightness b, {String? id}) {
    final spec = store.spec;
    final scheme = spec != null ? spec.scheme(store.accentColor) : themeById(id ?? store.themeId).scheme(b);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      fontFamily: spec != null ? 'Geist' : null,
      scaffoldBackgroundColor: spec?.background,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 2,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
      bottomSheetTheme: const BottomSheetThemeData(showDragHandle: true),
      popupMenuTheme: PopupMenuThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {
        TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) => MaterialApp(
        key: ValueKey(currentLang),
        title: 'Ncommander',
        debugShowCheckedModeBanner: false,
        themeMode: store.spec == null ? store.themeMode : (store.spec!.dark ? ThemeMode.dark : ThemeMode.light),
        theme: theme(Brightness.light),
        darkTheme: theme(Brightness.dark),
        home: const AccessGate(),
      ),
    );
  }
}

/// Asks for "All files access" once; the commander opens as soon as it's granted.
class AccessGate extends StatefulWidget {
  const AccessGate({super.key});
  @override
  State<AccessGate> createState() => _AccessGateState();
}

class _AccessGateState extends State<AccessGate> with WidgetsBindingObserver {
  bool _ok = accessGranted;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) async {
    if (s == AppLifecycleState.resumed && !_ok) {
      final a = await Native.hasAccess();
      if (a) {
        accessGranted = true;
        await volumes.refresh();
        if (mounted) setState(() => _ok = true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ok) return const CommanderPage();
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(color: cs.primaryContainer, borderRadius: BorderRadius.circular(28)),
                child: Icon(Icons.folder_copy_rounded, size: 44, color: cs.onPrimaryContainer),
              ),
              const SizedBox(height: 24),
              Text('Ncommander', style: t.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
              const SizedBox(height: 8),
              Text(tr('Are nevoie de acces la toate fișierele.', 'Needs access to all files.'),
                  textAlign: TextAlign.center, style: t.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 28),
              FilledButton.icon(
                style: FilledButton.styleFrom(minimumSize: const Size(220, 52)),
                icon: const Icon(Icons.lock_open_rounded),
                label: Text(tr('Permite accesul', 'Allow access')),
                onPressed: Native.requestAccess,
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
