import 'dart:io';

import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../core/themes.dart';
import '../services/http.dart';
import '../services/native.dart';
import '../services/store.dart';
import 'theme_preview.dart';
import 'widgets.dart';

/// Set by CI: --dart-define=BUILD=123 --dart-define=BUILT=22.11 14:58
const _build = String.fromEnvironment('BUILD');
const _built = String.fromEnvironment('BUILT');
String get appVersion => _build.isEmpty ? 'Ncommander 0.1' : 'Ncommander 0.1.$_build${_built.isEmpty ? '' : ' · $_built'}';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> with WidgetsBindingObserver {
  bool? _access;
  int? _latest; // build number of the published APK

  static const _repo = 'razvannicu15/Ncommander';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
    _checkUpdate();
  }

  Future<void> _checkUpdate() async {
    try {
      final r = await Http.send('GET', Uri.parse('https://api.github.com/repos/$_repo/releases/tags/latest'),
          headers: {'Accept': 'application/vnd.github+json', 'User-Agent': 'Ncommander'}).timeout(const Duration(seconds: 10));
      final m = RegExp(r'0\.1\.(\d+)').firstMatch('${r.json['body'] ?? ''}');
      if (mounted && m != null) setState(() => _latest = int.parse(m.group(1)!));
    } catch (_) {}
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final a = await Native.hasAccess();
    if (mounted) setState(() => _access = a);
  }

  Widget _sub(ColorScheme cs, String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(text, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: cs.onSurfaceVariant)),
      );

  void _set(VoidCallback f) {
    f();
    store.save();
    setState(() {});
  }

  Widget _div(ColorScheme cs) => Divider(height: 1, indent: 56, thickness: 0.6, color: cs.outlineVariant.withValues(alpha: 0.6));

  Widget _switch(ColorScheme cs, IconData icon, String title, bool value, ValueChanged<bool> onChanged) => SwitchListTile(
        secondary: Icon(icon),
        title: Text(title),
        value: value,
        onChanged: (v) => _set(() => onChanged(v)),
      );

  Widget _updateTile(ColorScheme cs) {
    final mine = int.tryParse(_build);
    final newer = _latest != null && (mine == null || _latest! > mine);
    return ListTile(
      leading: Icon(newer ? Icons.system_update_rounded : Icons.update_rounded, color: newer ? cs.primary : null),
      title: Text(tr('Actualizări', 'Updates')),
      subtitle: newer ? Text(tr('Versiune nouă: 0.1.$_latest', 'New version: 0.1.$_latest')) : null,
      trailing: _latest == null
          ? Text('…', style: TextStyle(color: cs.onSurfaceVariant))
          : newer
              ? FilledButton.tonal(
                  onPressed: () => Native.openUrl('https://github.com/$_repo/releases/download/latest/${Platform.isWindows ? 'Ncommander-windows.zip' : 'Ncommander-android.apk'}'),
                  child: Text(tr('Descarcă', 'Download')),
                )
              : Text(tr('La zi', 'Up to date'), style: TextStyle(fontWeight: FontWeight.w600, color: cs.primary)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    List<Widget> between(List<Widget> items) => [
          for (var i = 0; i < items.length; i++) ...[if (i > 0) _div(cs), items[i]],
        ];

    return Scaffold(
      appBar: AppBar(title: Text(tr('Setări', 'Settings'))),
      body: MaxWidth(
        child: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
          if (_access == false && !Platform.isWindows) ...[
            const SizedBox(height: 12),
            Group(
              padding: EdgeInsets.zero,
              children: [
                ListTile(
                  leading: Icon(Icons.lock_open_rounded, color: cs.error),
                  title: Text(tr('Acces la toate fișierele', 'All files access')),
                  subtitle: Text(tr('Neacordat', 'Not granted'), style: TextStyle(color: cs.error)),
                  trailing: FilledButton(onPressed: Native.requestAccess, child: Text(tr('Permite', 'Allow'))),
                ),
              ],
            ),
          ],
          SectionTitle(tr('Limbă', 'Language')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<String>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 'system', label: Text(tr('Automat', 'Automatic'))),
                  const ButtonSegment(value: 'ro', label: Text('Română')),
                  const ButtonSegment(value: 'en', label: Text('English')),
                ],
                selected: {store.language},
                onSelectionChanged: (s) => _set(() => store.language = s.first),
              ),
            ),
          ),
          SectionTitle(tr('Aspect', 'Appearance')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<ThemeMode>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: ThemeMode.system, icon: const Icon(Icons.brightness_auto_outlined), label: Text(tr('Auto', 'Auto'))),
                  ButtonSegment(value: ThemeMode.light, icon: const Icon(Icons.light_mode_outlined), label: Text(tr('Luminos', 'Light'))),
                  ButtonSegment(value: ThemeMode.dark, icon: const Icon(Icons.dark_mode_outlined), label: Text(tr('Întunecat', 'Dark'))),
                ],
                selected: {store.themeMode},
                onSelectionChanged: (s) => _set(() => store.themeMode = s.first),
              ),
            ),
          ),
          const SizedBox(height: 18),
          _sub(cs, tr('Temă', 'Theme')),
          SizedBox(
            height: 176,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: baseThemes.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (_, i) {
                final t = baseThemes[i];
                return ThemePreview(
                  scheme: buildScheme(t, accentColor(store.accent), Theme.of(context).brightness),
                  name: t.name,
                  selected: store.base == t.id,
                  onTap: () => _set(() => store.base = t.id),
                );
              },
            ),
          ),
          const SizedBox(height: 10),
          _sub(cs, tr('Accent', 'Accent')),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 4),
            child: Wrap(spacing: 12, runSpacing: 12, children: [
              if (systemAccent != null)
                Tooltip(
                  message: tr('Din tapet', 'From wallpaper'),
                  child: Stack(alignment: Alignment.center, children: [
                    ColorDot(systemAccent!, selected: store.accent == 'system', onTap: () => _set(() => store.accent = 'system')),
                    if (store.accent != 'system') const IgnorePointer(child: Icon(Icons.wallpaper_rounded, size: 16, color: Colors.white)),
                  ]),
                ),
              for (final a in accents)
                Tooltip(
                  message: a.name,
                  child: ColorDot(a.color, selected: store.accent == a.id, onTap: () => _set(() => store.accent = a.id)),
                ),
            ]),
          ),
          SectionTitle(tr('Panouri', 'Panels')),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<PanelLayout>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: PanelLayout.auto, label: Text(layoutLabel(PanelLayout.auto))),
                  ButtonSegment(value: PanelLayout.sideBySide, label: Text(layoutLabel(PanelLayout.sideBySide))),
                  ButtonSegment(value: PanelLayout.stacked, label: Text(layoutLabel(PanelLayout.stacked))),
                ],
                selected: {store.layout},
                onSelectionChanged: (s) => _set(() => store.layout = s.first),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SizedBox(
              width: double.infinity,
              child: SegmentedButton<int>(
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: 0, icon: const Icon(Icons.view_list_outlined), label: Text(tr('Detaliat', 'Detailed'))),
                  ButtonSegment(value: 1, icon: const Icon(Icons.table_rows_outlined), label: Text(tr('Compact', 'Compact'))),
                  ButtonSegment(value: 2, icon: const Icon(Icons.grid_view_rounded), label: Text(tr('Miniaturi', 'Thumbnails'))),
                ],
                selected: {store.grid ? 2 : (store.table ? 1 : 0)},
                onSelectionChanged: (s) => _set(() {
                  store.grid = s.first == 2;
                  if (s.first < 2) store.table = s.first == 1;
                }),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Group(padding: EdgeInsets.zero, children: between([
            ListTile(
              leading: const Icon(Icons.format_size_rounded),
              title: Text(tr('Mărime text', 'Text size')),
              subtitle: Slider(
                value: store.fontScale,
                min: 0.85,
                max: 1.25,
                divisions: 8,
                onChanged: (v) => _set(() => store.fontScale = double.parse(v.toStringAsFixed(2))),
              ),
              trailing: Text('${(store.fontScale * 100).round()}%',
                  style: const TextStyle(fontWeight: FontWeight.w700, fontFeatures: [FontFeature.tabularFigures()])),
            ),
            _switch(cs, Icons.density_small_rounded, tr('Spațiere redusă', 'Tight spacing'), store.compact, (v) => store.compact = v),
            if (!Platform.isWindows) _switch(cs, Icons.photo_outlined, tr('Miniaturi', 'Thumbnails'), store.thumbnails, (v) => store.thumbnails = v),
            _switch(cs, Icons.create_new_folder_outlined, tr('Folderele primele', 'Folders first'), store.foldersFirst, (v) => store.foldersFirst = v),
            _switch(cs, Icons.visibility_outlined, tr('Fișiere ascunse', 'Hidden files'), store.showHidden, (v) => store.showHidden = v),
            _switch(cs, Icons.arrow_upward_rounded, tr('Rândul „..”', '".." row'), store.showParent, (v) => store.showParent = v),
            _switch(cs, Icons.pie_chart_outline_rounded, tr('Bară de ocupare', 'Usage bar'), store.showFreeSpace, (v) => store.showFreeSpace = v),
            if (Platform.isWindows) _switch(cs, Icons.storage_rounded, tr('Butoane de discuri', 'Drive buttons'), store.driveBar, (v) => store.driveBar = v),
          ])),
          SectionTitle(tr('Siguranță', 'Safety')),
          Group(padding: EdgeInsets.zero, children: [
            _switch(cs, Icons.delete_outline, tr('Confirmare la ștergere', 'Confirm before deleting'), store.confirmDelete, (v) => store.confirmDelete = v),
          ]),
          SectionTitle(tr('Despre', 'About')),
          Group(padding: EdgeInsets.zero, children: between([
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: Text(appVersion),
              subtitle: Text(tr('Fără reclame · by norAz', 'No ads · by norAz')),
            ),
            _updateTile(cs),
            if (!Platform.isWindows)
            ListTile(
              leading: Icon(_access == true ? Icons.verified_user_outlined : Icons.lock_outline_rounded),
              title: Text(tr('Acces la fișiere', 'File access')),
              trailing: Text(
                _access == null ? '…' : (_access! ? tr('Acordat', 'Granted') : tr('Neacordat', 'Not granted')),
                style: TextStyle(fontWeight: FontWeight.w600, color: _access == false ? cs.error : cs.primary),
              ),
              onTap: Native.requestAccess,
            ),
          ])),
        ]),
      ),
    );
  }
}
