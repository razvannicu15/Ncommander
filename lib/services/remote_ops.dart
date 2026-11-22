import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import 'fs.dart';
import 'vfs.dart';

/// Copy / move / delete when at least one side is FTP or a cloud drive.
class RemoteOps {
  RemoteOps(this.job, this.ask);
  final Job job;
  final Future<ConflictAction> Function(ConflictInfo) ask;

  bool _cancelled() => job.cancelled;
  void _bytes(int d) {
    job.doneBytes += d;
    job.ping();
  }

  Future<void> run() async {
    final items = job.items.isNotEmpty ? job.items : job.sources.map(_localEntry).whereType<Entry>().toList();
    switch (job.kind) {
      case JobKind.delete:
        await _delete(items);
      case JobKind.copy:
      case JobKind.move:
        await _transfer(items, move: job.kind == JobKind.move);
      default:
        break;
    }
  }

  static Entry? _localEntry(String p) {
    final st = FileStat.statSync(p);
    if (st.type == FileSystemEntityType.notFound) return null;
    final dir = st.type == FileSystemEntityType.directory;
    return Entry(path: p, name: nameOf(p), isDir: dir, size: dir ? 0 : st.size, modified: st.modified);
  }

  Future<void> _delete(List<Entry> items) async {
    job.totalFiles = items.length;
    job.ping(force: true);
    for (final e in items) {
      job.check();
      job.current = e.name;
      job.ping();
      try {
        final v = vfsFor(e.path);
        if (v != null) {
          await v.delete(e);
        } else if (e.isDir) {
          await Directory(e.path).delete(recursive: true);
        } else {
          await File(e.path).delete();
        }
        job.touched.add(e.path);
      } catch (err) {
        job.errors.add('${e.name}: ${remoteError(err)}');
      }
      job.doneFiles++;
    }
  }

  Future<void> _transfer(List<Entry> items, {required bool move}) async {
    final target = job.target;
    final dstV = vfsFor(target);
    if (isRemote(target) && dstV == null) {
      job.errors.add(tr('Conexiunea nu mai există', 'The connection no longer exists'));
      return;
    }
    for (final e in items) {
      if (isInside(target, e.path)) {
        job.errors.add('${e.name}: ${tr('nu poate fi copiat în el însuși', 'can\'t be copied into itself')}');
        return;
      }
    }
    job.current = '…';
    job.ping(force: true);
    // Totals first, so the bar moves evenly.
    for (final e in items) {
      job.check();
      await _count(e);
    }
    final bothRemote = items.any((e) => isRemote(e.path)) && dstV != null;
    if (bothRemote) job.totalBytes *= 2; // download + upload
    job.ping(force: true);
    if (dstV == null) await Directory(target).create(recursive: true);

    for (final e in items) {
      job.check();
      // Same folder: a move does nothing, a copy gets a new name below.
      if (parentOf(e.path) == target && move) continue;
      await _item(e, target, move);
    }
  }

  Future<void> _count(Entry e) async {
    final v = vfsFor(e.path);
    if (v == null) {
      final st = await measure([e.path]);
      job.totalBytes += st.bytes;
      job.totalFiles += st.files;
      return;
    }
    if (!e.isDir) {
      job.totalBytes += e.size;
      job.totalFiles++;
      return;
    }
    for (final c in await v.list(e.path)) {
      job.check();
      await _count(c);
    }
  }

  Future<List<Entry>> _children(Entry dir) async {
    final v = vfsFor(dir.path);
    if (v != null) return v.list(dir.path);
    return listDirSync(dir.path).entries;
  }

  /// Copies one item into [dstDir]. Returns true when everything arrived
  /// (only then is a moved source removed).
  Future<bool> _item(Entry src, String dstDir, bool move) async {
    job.check();
    final srcV = vfsFor(src.path);
    final dstV = vfsFor(dstDir);

    if (src.isDir) {
      String newDir;
      try {
        if (dstV == null) {
          newDir = join(dstDir, src.name);
          if (parentOf(src.path) == dstDir) {
            newDir = join(dstDir, uniqueName(src.name, (n) => FileSystemEntity.typeSync(join(dstDir, n)) != FileSystemEntityType.notFound));
          }
          await Directory(newDir).create(recursive: true);
        } else {
          final existing = parentOf(src.path) == dstDir ? null : await dstV.find(dstDir, src.name);
          if (existing != null && existing.isDir) {
            newDir = existing.path;
          } else {
            var name = src.name;
            if (existing != null || parentOf(src.path) == dstDir) {
              final names = (await dstV.list(dstDir)).map((e) => e.name).toSet();
              name = uniqueName(name, names.contains);
            }
            newDir = await dstV.mkdir(dstDir, name);
          }
        }
      } catch (err) {
        job.errors.add('${src.name}: ${remoteError(err)}');
        return false;
      }
      var ok = true;
      List<Entry> kids;
      try {
        kids = await _children(src);
      } catch (err) {
        job.errors.add('${src.name}: ${remoteError(err)}');
        return false;
      }
      for (final c in kids) {
        ok = await _item(c, newDir, move) && ok;
      }
      if (move && ok) {
        try {
          if (srcV != null) {
            await srcV.delete(src);
          } else {
            await Directory(src.path).delete(recursive: true);
          }
          job.touched.add(src.path);
        } catch (err) {
          job.errors.add('${src.name}: ${remoteError(err)}');
        }
      }
      return ok;
    }

    // ---- a file
    var name = srcV?.localName(src) ?? src.name;
    job.current = name;
    job.ping(force: true);
    final factor = srcV != null && dstV != null ? 2 : 1;

    // Existing target?
    Entry? existing;
    bool existsLocal = false;
    try {
      if (dstV == null) {
        final t = FileSystemEntity.typeSync(join(dstDir, name), followLinks: false);
        existsLocal = t != FileSystemEntityType.notFound;
        if (existsLocal) existing = _localEntry(join(dstDir, name));
      } else {
        existing = await dstV.find(dstDir, name);
      }
    } catch (err) {
      job.errors.add('$name: ${remoteError(err)}');
      return false;
    }
    final sameDir = parentOf(src.path) == dstDir;
    if (existing != null || existsLocal) {
      final action = sameDir
          ? ConflictAction.rename
          : await ask(ConflictInfo(name,
              srcSize: src.size, srcTime: src.modified, dstSize: existing?.isDir == true ? null : existing?.size, dstTime: existing?.modified, dstIsDir: existing?.isDir ?? false));
      switch (action) {
        case ConflictAction.cancel:
          throw JobCancelled();
        case ConflictAction.skip:
          job.doneBytes += src.size * factor;
          job.doneFiles++;
          job.ping();
          return false;
        case ConflictAction.rename:
          if (dstV == null) {
            name = uniqueName(name, (n) => FileSystemEntity.typeSync(join(dstDir, n), followLinks: false) != FileSystemEntityType.notFound);
          } else {
            final names = (await dstV.list(dstDir)).map((e) => e.name).toSet();
            name = uniqueName(name, names.contains);
          }
        case ConflictAction.overwrite:
          if (existing?.isDir == true) {
            try {
              if (dstV == null) {
                await Directory(existing!.path).delete(recursive: true);
              } else {
                await dstV.delete(existing!);
              }
            } catch (_) {}
          }
      }
    }

    String? tmp;
    try {
      if (srcV == null && dstV != null) {
        await dstV.upload(src.path, dstDir, name, _bytes, _cancelled);
      } else if (srcV != null && dstV == null) {
        final dst = join(dstDir, name);
        final part = '$dst.ncpart';
        await srcV.download(src, part, _bytes, _cancelled);
        job.check();
        if (FileSystemEntity.typeSync(dst) == FileSystemEntityType.file) await File(dst).delete();
        await File(part).rename(dst);
        try {
          await File(dst).setLastModified(src.modified);
        } catch (_) {}
        job.touched.add(dst);
      } else if (srcV != null && dstV != null) {
        tmp = await _tempFile(name);
        await srcV.download(src, tmp, _bytes, _cancelled);
        job.check();
        await dstV.upload(tmp, dstDir, name, _bytes, _cancelled);
      }
      job.doneFiles++;
      if (move) {
        if (srcV != null) {
          await srcV.delete(src);
        } else {
          await File(src.path).delete();
        }
        job.touched.add(src.path);
      }
      job.ping();
      return true;
    } on JobCancelled {
      _cleanPart(dstV == null ? '${join(dstDir, name)}.ncpart' : null);
      rethrow;
    } catch (err) {
      if (job.cancelled) {
        _cleanPart(dstV == null ? '${join(dstDir, name)}.ncpart' : null);
        throw JobCancelled();
      }
      _cleanPart(dstV == null ? '${join(dstDir, name)}.ncpart' : null);
      job.errors.add('$name: ${remoteError(err)}');
      return false;
    } finally {
      if (tmp != null) {
        try {
          File(tmp).deleteSync();
        } catch (_) {}
      }
    }
  }

  void _cleanPart(String? p) {
    if (p == null) return;
    try {
      final f = File(p);
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }
}

/// A fresh temporary file path in the app cache.
Future<String> _tempFile(String name) async {
  Directory base;
  try {
    base = await getTemporaryDirectory();
  } catch (_) {
    base = Directory.systemTemp;
  }
  final d = Directory('${base.path}/xfer/${DateTime.now().microsecondsSinceEpoch}');
  await d.create(recursive: true);
  return '${d.path}/$name';
}

/// Downloads a remote file to the cache so it can be opened or shared.
Future<String> fetchToCache(Entry e, {OnBytes? onBytes, bool Function()? cancelled}) async {
  final v = vfsFor(e.path)!;
  final path = await _tempFile(v.localName(e));
  await v.download(e, path, onBytes ?? (_) {}, cancelled ?? () => false);
  return path;
}

/// Name check used by the rename dialog on remote folders.
Future<bool> remoteExists(String dir, String name) async {
  final v = vfsFor(dir);
  if (v == null) return false;
  return (await v.find(dir, name)) != null;
}
