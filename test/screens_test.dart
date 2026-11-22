// Renders the main screens to PNG for visual review (CI uploads them).
// Runs only when SCREEN_FONTS points to a folder with Roboto *.ttf files.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncommander/core/i18n.dart';
import 'package:ncommander/main.dart';
import 'package:ncommander/models/panel.dart';
import 'package:ncommander/services/fs.dart';
import 'package:ncommander/services/native.dart';
import 'package:ncommander/services/store.dart';
import 'package:ncommander/ui/commander_page.dart';
import 'package:ncommander/ui/editor_page.dart';
import 'package:ncommander/ui/settings_page.dart';
import 'package:ncommander/ui/zip_page.dart';

final fontsDir = Platform.environment['SCREEN_FONTS'];
late Directory root;
late String home;

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto');
  for (final f in Directory(fontsDir!).listSync(recursive: true)) {
    final n = f.path.toLowerCase();
    if (n.endsWith('.ttf') && n.contains('roboto') && !n.contains('condensed') && !n.contains('mono') && !n.contains('slab')) {
      roboto.addFont(Future.value(ByteData.view(File(f.path).readAsBytesSync().buffer)));
    }
  }
  await roboto.load();
  final mono = FontLoader('monospace');
  for (final f in Directory(fontsDir!).listSync(recursive: true)) {
    final n = f.path.toLowerCase();
    if (n.endsWith('.ttf') && n.contains('mono') && !n.contains('bold') && !n.contains('italic') && !n.contains('oblique')) {
      mono.addFont(Future.value(ByteData.view(File(f.path).readAsBytesSync().buffer)));
      break;
    }
  }
  await mono.load();
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ??
      File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final icons = File('$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  if (icons.existsSync()) {
    final l = FontLoader('MaterialIcons')..addFont(Future.value(ByteData.view(icons.readAsBytesSync().buffer)));
    await l.load();
  }
}

/// A realistic phone storage tree with fixed dates.
void buildTree() {
  root = Directory.systemTemp.createTempSync('ncshots_');
  home = '${root.path}/storage/emulated/0';
  final t0 = DateTime(2026, 11, 22, 14, 5);
  void file(String rel, int size, DateTime t) {
    final f = File('$home/$rel');
    f.parent.createSync(recursive: true);
    // Sparse files: the size shows without writing hundreds of MB.
    f.openSync(mode: FileMode.write)
      ..truncateSync(size)
      ..closeSync();
    f.setLastModifiedSync(t);
  }

  for (final d in ['Alarms', 'Android', 'Audiobooks', 'DCIM/Camera', 'DCIM/Screenshots', 'Documents', 'Download/Telegram', 'Movies', 'Music', 'Pictures/WhatsApp', 'Podcasts', 'Recordings']) {
    Directory('$home/$d').createSync(recursive: true);
  }
  file('.nomedia', 0, t0);
  file('Download/Factura_noiembrie.pdf', 245760, DateTime(2026, 11, 20, 9, 41));
  file('Download/NetScan-android.apk', 23500000, DateTime(2026, 11, 21, 22, 10));
  file('Download/poze_vacanta.zip', 186000000, DateTime(2026, 8, 14, 18, 2));
  file('Download/Contract inchiriere.docx', 88000, DateTime(2026, 10, 2, 11, 15));
  file('Download/buget 2026.xlsx', 41000, DateTime(2026, 11, 3, 20, 30));
  file('Download/notite.txt', 1800, DateTime(2026, 11, 22, 8, 12));
  file('Download/concert.mp4', 412000000, DateTime(2026, 7, 5, 23, 48));
  file('Download/podcast_ep42.mp3', 54000000, DateTime(2026, 11, 18, 7, 30));
  file('Download/config.json', 2400, DateTime(2025, 12, 1, 10, 0));
  for (var i = 0; i < 14; i++) {
    file('DCIM/Camera/IMG_20261${i % 2 == 0 ? '122' : '121'}_${(140512 + i * 731).toString().padLeft(6, '0')}.jpg', 3200000 + i * 211000,
        DateTime(2026, 11, 22 - (i ~/ 5), 13 - i % 5, 40 - i));
  }
  file('DCIM/Camera/VID_20261120_183022.mp4', 145000000, DateTime(2026, 11, 20, 18, 30));
  file('Documents/notite.md', 4200, DateTime(2026, 11, 22, 9, 0));
  File('$home/Documents/notite.md').writeAsStringSync('''# Ncommander

- două panouri, ca în Total Commander
- copiere / mutare cu progres
- arhive ZIP: răsfoire și dezarhivare
- căutare după mască: *.jpg;*.png

## De făcut
1. FTP / SMB
2. Comparare foldere
''');
}

Future<void> setup(WidgetTester t, {Size size = const Size(1440, 3088), double dpr = 3.5}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = dpr;
  addTearDown(t.view.reset);
}

Widget app(Widget home, Brightness b) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: NcommanderApp.theme(b),
      home: home,
    );

Future<CommanderPageState> commander(WidgetTester t, Brightness b, {String left = '', String right = 'DCIM/Camera', List<String> select = const []}) async {
  store.left = PanelSaved([TabState(left.isEmpty ? home : '$home/$left')], 0);
  store.right = PanelSaved([TabState('$home/$right')], 0);
  store.activePanel = 0;
  await t.pumpWidget(const SizedBox());
  await t.pumpWidget(app(const CommanderPage(autoLoad: false), b));
  final s = t.state<CommanderPageState>(find.byType(CommanderPage));
  await t.runAsync(() => Future.wait(s.panels.map((p) => p.load())));
  s.panels[0].selectNames(select);
  await t.pump(const Duration(milliseconds: 400));
  return s;
}

Future<void> shot(WidgetTester t, String name) async {
  await t.pump(const Duration(milliseconds: 50));
  await expectLater(find.byType(MaterialApp), matchesGoldenFile('screens/$name.png'));
}

void main() {
  final skip = fontsDir == null;

  setUpAll(() async {
    if (skip) return;
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFonts();
    buildTree();
    Panel.watchEnabled = false;
    store.thumbnails = false;
    volumes.value = [Volume(path: home, label: '', removable: false, primary: true, total: 256000000000, free: 61400000000)];
  });

  tearDownAll(() {
    if (!skip) root.deleteSync(recursive: true);
  });

  testWidgets('screens', (t) async {
    debugDisableShadows = false;
    addTearDown(() => debugDisableShadows = true);
    store.language = 'ro';
    setLanguage('ro');

    // Phone portrait: panels stacked.
    await setup(t);
    await commander(t, Brightness.light, left: 'Download', select: ['poze_vacanta.zip', 'concert.mp4']);
    await shot(t, '01_portrait');
    await commander(t, Brightness.dark, left: 'Download');
    await shot(t, '02_portrait_dark');

    // Landscape: side by side.
    await setup(t, size: const Size(3088, 1440));
    await commander(t, Brightness.light, left: 'Download', select: ['NetScan-android.apk']);
    await shot(t, '03_landscape');

    // Fold open: side by side.
    await setup(t, size: const Size(2176, 1812), dpr: 2.6);
    final s = await commander(t, Brightness.dark, left: '', right: 'Download');
    s.panels[0].newTab('$home/DCIM/Camera');
    await t.runAsync(() => s.panels[0].load());
    await t.pump(const Duration(milliseconds: 300));
    await shot(t, '04_fold_tabs_dark');

    // Sheets and dialogs on the phone.
    await setup(t);
    await commander(t, Brightness.light, left: 'Download', select: ['Factura_noiembrie.pdf']);
    await t.tap(find.byIcon(Icons.more_horiz_rounded));
    await t.pumpAndSettle();
    await shot(t, '05_more_sheet');

    await commander(t, Brightness.light, left: 'Download', select: ['poze_vacanta.zip', 'concert.mp4']);
    await t.tap(find.byIcon(Icons.file_copy_outlined).first);
    await t.pumpAndSettle();
    await shot(t, '06_copy_dialog');

    await commander(t, Brightness.light, left: 'Download');
    await t.tap(find.byIcon(Icons.menu_rounded).first);
    await t.pumpAndSettle();
    await shot(t, '07_drawer');

    await commander(t, Brightness.dark, left: 'Download');
    await t.tap(find.byIcon(Icons.more_vert_rounded).first);
    await t.pumpAndSettle();
    await shot(t, '08_panel_menu_dark');

    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(const SettingsPage(), Brightness.light));
    await t.pump(const Duration(milliseconds: 300));
    await shot(t, '09_settings');
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(app(const SettingsPage(), Brightness.dark));
    await t.pump(const Duration(milliseconds: 300));
    await shot(t, '10_settings_dark');

    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await t.pumpWidget(app(EditorPage(path: '$home/Documents/notite.md'), Brightness.light));
      await Future.delayed(const Duration(milliseconds: 400));
    });
    await t.pump(const Duration(milliseconds: 300));
    await shot(t, '11_editor');

    // Properties of a selection (folder size measured in the background).
    await commander(t, Brightness.light, left: '', select: ['Download']);
    await t.tap(find.byIcon(Icons.more_horiz_rounded));
    await t.pumpAndSettle();
    await t.tap(find.text('Proprietăți'));
    await t.pump();
    await t.runAsync(() => Future.delayed(const Duration(milliseconds: 500)));
    await t.pumpAndSettle();
    await shot(t, '13_properties');

    // Browsing inside a ZIP.
    await t.runAsync(() => FileOps((_) async => const ConflictAnswer(ConflictAction.overwrite))
        .run(Job(JobKind.zip, ['$home/Documents', '$home/Download/notite.txt', '$home/Download/config.json'], target: '$home/Download', zipName: 'proiect.zip')));
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() async {
      await t.pumpWidget(app(ZipPage(path: '$home/Download/proiect.zip', extractTo: home, onExtract: (_) {}), Brightness.dark));
      await Future.delayed(const Duration(milliseconds: 500));
    });
    await t.pump(const Duration(milliseconds: 300));
    await shot(t, '14_zip_dark');

    store.language = 'en';
    setLanguage('en');
    await commander(t, Brightness.light, left: 'Download', select: ['poze_vacanta.zip', 'concert.mp4']);
    await shot(t, '12_portrait_en');
    store.language = 'ro';
    setLanguage('ro');
  }, skip: skip);
}
