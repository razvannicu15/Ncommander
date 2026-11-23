import 'dart:io';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../models/panel.dart';
import '../services/fs.dart';
import '../services/native.dart';
import '../services/store.dart';
import 'connections.dart';
import 'modern.dart';

/// Modern styles' home for places: storage with usage rings, cloud and FTP
/// connections, common folders and bookmarks. Pops with the chosen path.
class LocationsPage extends StatefulWidget {
  const LocationsPage({super.key, required this.current, required this.onConnMenu, required this.onSettings});
  final String current;
  final Future<void> Function(Conn c, String action) onConnMenu;
  final VoidCallback onSettings;

  @override
  State<LocationsPage> createState() => _LocationsPageState();
}

class _LocationsPageState extends State<LocationsPage> {
  @override
  void initState() {
    super.initState();
    volumes.refresh().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _go(String path) => Navigator.of(context).pop(path);

  Color _connColor(Conn c) => switch (c.type) {
        ConnType.gdrive => const Color(0xFF2F7DF6),
        ConnType.onedrive => const Color(0xFF3B6FE0),
        ConnType.ftp => const Color(0xFFB8742B),
      };

  @override
  Widget build(BuildContext context) {
    final spec = store.spec!;
    final accent = store.accentColor;
    final cs = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final home = volumes.primary;
    final card = spec.shadow ? Colors.white : cs.onSurface.withValues(alpha: 0.06);
    final border = spec.shadow ? spec.idleBorder : cs.onSurface.withValues(alpha: 0.08);
    final dim = cs.onSurfaceVariant;

    final folders = <(String, String, Color)>[
      ('Download', tr('Descărcări', 'Downloads'), accent),
      ('DCIM', tr('Cameră', 'Camera'), const Color(0xFF4ADE80)),
      ('Documents', tr('Documente', 'Documents'), const Color(0xFF6EA8FF)),
      ('Music', tr('Muzică', 'Music'), const Color(0xFFC084FC)),
      ('Pictures', tr('Imagini', 'Pictures'), const Color(0xFFFBBF24)),
      ('Movies', tr('Filme', 'Movies'), const Color(0xFFFF7A7A)),
    ].where((f) => Directory(join(home, f.$1)).existsSync()).toList();

    Widget section(String s) => Padding(
          padding: const EdgeInsets.fromLTRB(4, 22, 4, 10),
          child: Text(s.toUpperCase(), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, letterSpacing: 0.6, color: dim)),
        );

    BoxDecoration box([double r = 24]) => BoxDecoration(color: card, borderRadius: BorderRadius.circular(r), border: Border.all(color: border));

    Widget volumeCard(Volume v) {
      final used = v.total > 0 ? 1 - v.free / v.total : 0.0;
      final on = !isRemote(widget.current) && volumes.of(widget.current)?.path == v.path;
      return Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => _go(v.path),
          child: Ink(
            decoration: box().copyWith(border: Border.all(color: on ? accent.withValues(alpha: 0.7) : border, width: on ? 1.5 : 1)),
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Ring(value: used, color: v.primary ? accent : const Color(0xFF2DD4BF)),
              const SizedBox(height: 14),
              Text(volumes.label(v), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(tr('${fmtSize(v.free)} liberi din ${fmtSize(v.total)}', '${fmtSize(v.free)} free of ${fmtSize(v.total)}'),
                  style: TextStyle(fontSize: 12, color: dim, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
        ),
      );
    }

    final vols = volumes.value;
    return Scaffold(
      backgroundColor: spec.background,
      body: Stack(children: [
        Positioned.fill(child: StyleBackground(spec: spec, accent: accent)),
        SafeArea(
          child: ListView(padding: const EdgeInsets.fromLTRB(18, 8, 18, 32), children: [
            Row(children: [
              IconButton(
                tooltip: tr('Înapoi', 'Back'),
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(width: 4),
              Expanded(child: Text(tr('Locații', 'Locations'), style: t.headlineMedium?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -1))),
              IconButton.filledTonal(
                tooltip: tr('Setări', 'Settings'),
                icon: const Icon(Icons.settings_outlined),
                onPressed: () {
                  Navigator.of(context).pop();
                  widget.onSettings();
                },
              ),
            ]),
            const SizedBox(height: 14),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.08,
              children: [for (final v in vols) volumeCard(v)],
            ),
            section(tr('Cloud și rețea', 'Cloud & network')),
            Material(
              color: card,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: border)),
              clipBehavior: Clip.antiAlias,
              child: Column(children: [
                for (final c in store.conns) ...[
                  ListTile(
                    contentPadding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
                    leading: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(color: _connColor(c), borderRadius: BorderRadius.circular(14)),
                      child: Icon(connIcon(c.type), color: Colors.white, size: 21),
                    ),
                    title: Text(c.name, style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600)),
                    subtitle: Text(connSubtitle(c), maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: dim)),
                    onTap: () => _go(c.root),
                    trailing: PopupMenuButton<String>(
                      icon: Icon(Icons.more_horiz_rounded, color: dim),
                      onSelected: (a) async {
                        await widget.onConnMenu(c, a);
                        if (mounted) setState(() {});
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'rename', child: Text(tr('Redenumește', 'Rename'))),
                        if (c.type == ConnType.ftp) PopupMenuItem(value: 'edit', child: Text(tr('Editează', 'Edit'))),
                        PopupMenuItem(value: 'remove', child: Text(tr('Elimină', 'Remove'))),
                      ],
                    ),
                  ),
                  Divider(height: 1, indent: 70, color: border),
                ],
                ListTile(
                  contentPadding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
                  leading: Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: accent.withValues(alpha: 0.55), width: 1.5),
                    ),
                    child: Icon(Icons.add_rounded, color: accent),
                  ),
                  title: Text(tr('Adaugă conexiune', 'Add connection'), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: accent)),
                  onTap: () async {
                    final c = await addConnection(context);
                    if (c != null && mounted) _go(c.root);
                  },
                ),
              ]),
            ),
            if (folders.isNotEmpty) ...[
              section(tr('Foldere', 'Folders')),
              GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 1.45,
                children: [
                  for (final f in folders)
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () => _go(join(home, f.$1)),
                        child: Ink(
                          decoration: box(20),
                          padding: const EdgeInsets.symmetric(horizontal: 14),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Container(width: 10, height: 10, decoration: BoxDecoration(color: f.$3, shape: BoxShape.circle)),
                            const SizedBox(height: 8),
                            Text(f.$2, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                          ]),
                        ),
                      ),
                    ),
                ],
              ),
            ],
            if (store.bookmarks.isNotEmpty) ...[
              section(tr('Favorite', 'Bookmarks')),
              Material(
                color: card,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24), side: BorderSide(color: border)),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  for (final b in store.bookmarks)
                    ListTile(
                      leading: Icon(Icons.star_rounded, color: accent),
                      title: Text(b.name.isEmpty ? nameOf(b.path) : b.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text(b.path, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: dim)),
                      onTap: () => _go(b.path),
                      trailing: IconButton(
                        icon: Icon(Icons.close_rounded, size: 18, color: dim),
                        onPressed: () => setState(() => store.toggleBookmark(b.path, b.name)),
                      ),
                    ),
                ]),
              ),
            ],
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _go('/'),
                icon: Icon(Icons.storage_rounded, size: 18, color: dim),
                label: Text(tr('Rădăcina sistemului', 'System root'), style: TextStyle(color: dim)),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
