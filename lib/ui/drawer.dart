import 'dart:io';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import '../services/native.dart';
import '../services/store.dart';
import '../services/win.dart';
import 'connections.dart';

/// Storage volumes, common folders and bookmarks.
class LocationsDrawer extends StatefulWidget {
  const LocationsDrawer({super.key, required this.panel, required this.onGo, required this.onSettings, required this.onAddConn, required this.onConnMenu});
  final Panel panel;
  final void Function(String path) onGo;
  final VoidCallback onSettings;
  final VoidCallback onAddConn;
  final void Function(Conn c, String action) onConnMenu;

  @override
  State<LocationsDrawer> createState() => _LocationsDrawerState();
}

class _LocationsDrawerState extends State<LocationsDrawer> {
  @override
  void initState() {
    super.initState();
    volumes.refresh().then((_) {
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final cur = widget.panel.path;
    final home = Platform.isWindows ? winHome : volumes.primary;
    final common = <(String, IconData, String)>[
      if (Platform.isWindows) ...[
        ('Desktop', Icons.desktop_windows_outlined, tr('Desktop', 'Desktop')),
        ('Downloads', Icons.download_rounded, tr('Descărcări', 'Downloads')),
        ('Documents', Icons.description_outlined, tr('Documente', 'Documents')),
        ('Pictures', Icons.image_outlined, tr('Imagini', 'Pictures')),
        ('Music', Icons.music_note_outlined, tr('Muzică', 'Music')),
        ('Videos', Icons.movie_outlined, tr('Videoclipuri', 'Videos')),
      ] else ...[
        ('Download', Icons.download_rounded, tr('Descărcări', 'Downloads')),
        ('DCIM', Icons.photo_camera_outlined, tr('Cameră', 'Camera')),
        ('Pictures', Icons.image_outlined, tr('Imagini', 'Pictures')),
        ('Documents', Icons.description_outlined, tr('Documente', 'Documents')),
        ('Music', Icons.music_note_outlined, tr('Muzică', 'Music')),
        ('Movies', Icons.movie_outlined, tr('Filme', 'Movies')),
      ],
    ].where((c) => Directory(join(home, c.$1)).existsSync()).toList();

    Widget item(IconData icon, String label, String path, {String? sub, Widget? trailing, VoidCallback? onLong, Color? tint}) {
      final on = cur == path || (isRemote(path) && path == rootOf(path) && rootOf(cur) == path);
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
        child: ListTile(
          dense: true,
          tileColor: tint,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          selected: on,
          selectedTileColor: cs.secondaryContainer,
          selectedColor: cs.onSecondaryContainer,
          leading: Icon(icon),
          title: Text(label, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
          subtitle: sub == null ? null : Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: trailing,
          onTap: () => widget.onGo(path),
          onLongPress: onLong,
        ),
      );
    }

    Widget head(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(28, 18, 16, 6),
          child: Text(s, style: t.labelLarge?.copyWith(color: cs.primary, fontWeight: FontWeight.w700)),
        );

    return NavigationDrawer(
      backgroundColor: cs.surfaceContainerLow,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 18, 16, 4),
          child: Row(children: [
            Text('Ncommander', style: t.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
            const Spacer(),
            IconButton(icon: const Icon(Icons.settings_outlined), tooltip: tr('Setări', 'Settings'), onPressed: widget.onSettings),
          ]),
        ),
        // On Windows drives, FTP and cloud sit in the bar above each panel;
        // the side list keeps only folders and bookmarks.
        if (!Platform.isWindows) ...[
        head(tr('Stocare', 'Storage')),
        for (final v in volumes.value) _volume(v, cs, cur),
        head(tr('Rețea și cloud', 'Network & cloud')),
        for (final c in store.conns)
          item(
            connIcon(c.type),
            c.name,
            c.root,
            sub: connSubtitle(c),
            trailing: PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert_rounded, size: 20),
              onSelected: (a) => widget.onConnMenu(c, a),
              itemBuilder: (_) => [
                PopupMenuItem(value: 'rename', child: Text(tr('Redenumește', 'Rename'))),
                if (c.type == ConnType.ftp) PopupMenuItem(value: 'edit', child: Text(tr('Editează', 'Edit'))),
                PopupMenuItem(value: 'remove', child: Text(tr('Elimină', 'Remove'))),
              ],
            ),
          ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
          child: ListTile(
            dense: true,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
            leading: Icon(Icons.add_rounded, color: cs.primary),
            title: Text(tr('Adaugă conexiune', 'Add connection'), style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: cs.primary)),
            onTap: widget.onAddConn,
          ),
        ),
        ],
        if (common.isNotEmpty) head(tr('Foldere', 'Folders')),
        for (final c in common) item(c.$2, c.$3, join(home, c.$1)),
        if (store.bookmarks.isNotEmpty) head(tr('Favorite', 'Bookmarks')),
        for (final b in store.bookmarks)
          item(
            Icons.star_rounded,
            b.name.isEmpty ? nameOf(b.path) : b.name,
            b.path,
            sub: _short(b.path),
            // Same rows as the folders, on a light wash so they read as yours.
            tint: Platform.isWindows ? cs.primary.withValues(alpha: 0.06) : null,
            trailing: IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close_rounded, size: 18),
              onPressed: () => setState(() => store.toggleBookmark(b.path, b.name)),
            ),
          ),
        if (!Platform.isWindows) ...[
          head(tr('Sistem', 'System')),
          item(Icons.storage_rounded, tr('Rădăcină', 'Root'), '/', sub: '/'),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  String _short(String p) {
    final v = volumes.of(p);
    if (v == null) return p;
    return '${volumes.label(v)}${p.substring(v.path.length)}';
  }

  Widget _volume(Volume v, ColorScheme cs, String cur) {
    final on = !isRemote(cur) && volumes.of(cur)?.path == v.path;
    final used = v.total > 0 ? 1 - v.free / v.total : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: Material(
        color: on ? cs.secondaryContainer : Colors.transparent,
        borderRadius: BorderRadius.circular(20),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: () => widget.onGo(v.path),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Row(children: [
              Icon(Platform.isWindows ? (v.removable ? Icons.usb_rounded : Icons.storage_rounded) : (v.primary ? Icons.smartphone_rounded : (v.removable ? Icons.sd_card_outlined : Icons.usb_rounded)),
                  color: on ? cs.onSecondaryContainer : cs.onSurfaceVariant),
              const SizedBox(width: 16),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(volumes.label(v), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: on ? cs.onSecondaryContainer : null)),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: used,
                      minHeight: 5,
                      backgroundColor: cs.outlineVariant.withValues(alpha: 0.5),
                      color: used > 0.9 ? cs.error : cs.primary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tr('${fmtSize(v.free)} liber din ${fmtSize(v.total)}', '${fmtSize(v.free)} free of ${fmtSize(v.total)}'),
                    style: TextStyle(fontSize: 11.5, color: cs.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
