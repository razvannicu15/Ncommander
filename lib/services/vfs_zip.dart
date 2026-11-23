import '../core/i18n.dart';
import '../models/entry.dart';
import 'fs.dart';
import 'vfs.dart';

/// A ZIP archive browsed in a panel like a folder (Total Commander style).
/// Read-only: files come out with copy (F5) or open (Enter/F3).
class ZipVfs extends Vfs {
  ZipVfs(super.conn);

  String get _zip => conn.host;
  List<ZipItem>? _items;

  Future<List<ZipItem>> _all() async => _items ??= await readZip(_zip);

  /// "dir/sub" for "zip://id/dir/sub" ("" at the root).
  String _inner(String path) => relOf(path).replaceFirst(RegExp('^/+'), '');

  @override
  Future<List<Entry>> list(String path) async {
    final dir = _inner(path);
    final prefix = dir.isEmpty ? '' : '$dir/';
    final out = <String, Entry>{};
    for (final it in await _all()) {
      if (!it.name.startsWith(prefix) || it.name.length == prefix.length) continue;
      final rest = it.name.substring(prefix.length);
      final slash = rest.indexOf('/');
      final child = slash < 0 ? rest : rest.substring(0, slash);
      if (child.isEmpty) continue;
      // Folders may exist only as part of a file's path.
      final isDir = slash >= 0 || it.isDir;
      final p = join(path, child);
      final had = out[child];
      if (had == null || (isDir && !had.isDir)) {
        out[child] = Entry(
          path: p,
          name: child,
          isDir: isDir,
          size: isDir ? 0 : it.size,
          modified: it.modified,
          id: isDir ? null : it.name,
        );
      }
    }
    return out.values.toList();
  }

  @override
  Future<void> download(Entry e, String localPath, OnBytes onBytes, bool Function() cancelled) async {
    await extractOne(_zip, e.id ?? _inner(e.path), localPath);
    onBytes(e.size);
  }

  Never _ro() => throw RemoteException(tr('Arhiva se poate doar citi', 'The archive is read-only'));

  @override
  Future<String> mkdir(String dir, String name) async => _ro();

  @override
  Future<void> delete(Entry e) async => _ro();

  @override
  Future<void> rename(Entry e, String newName) async => _ro();

  @override
  Future<void> upload(String localPath, String dir, String name, OnBytes onBytes, bool Function() cancelled) async => _ro();
}
