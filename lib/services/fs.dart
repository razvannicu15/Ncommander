import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';

import '../core/file_types.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../models/entry.dart';
import 'remote_ops.dart';

/// Path helpers. Local paths are POSIX; remote ones look like
/// "ftp://<connId>/folder/file" (also gdrive:// and onedrive://).
bool isRemote(String path) => path.contains('://');

/// "ftp://id" for "ftp://id/a/b"; "/" for local paths.
String rootOf(String path) {
  final i = path.indexOf('://');
  if (i < 0) return '/';
  final j = path.indexOf('/', i + 3);
  return j < 0 ? path : path.substring(0, j);
}

/// Path inside the remote location: "/a/b" (or "" at its root).
String relOf(String path) => isRemote(path) ? path.substring(rootOf(path).length) : path;

String parentOf(String path) {
  if (isRemote(path)) {
    final root = rootOf(path);
    if (path.length <= root.length + 1) return root;
    final i = path.lastIndexOf('/');
    return i <= root.length ? root : path.substring(0, i);
  }
  if (path == '/' || path.isEmpty) return '/';
  final p = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
  final i = p.lastIndexOf('/');
  return i <= 0 ? '/' : p.substring(0, i);
}

String nameOf(String path) {
  if (isRemote(path) && path == rootOf(path)) return '';
  final p = path.endsWith('/') && path.length > 1 ? path.substring(0, path.length - 1) : path;
  final i = p.lastIndexOf('/');
  return i < 0 ? p : p.substring(i + 1);
}

String join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

/// True when [path] is [dir] or lies inside it.
bool isInside(String path, String dir) => path == dir || path.startsWith(dir.endsWith('/') ? dir : '$dir/');

class ListResult {
  ListResult(this.entries, {this.error});
  final List<Entry> entries;
  final String? error;
}

/// Lists a folder off the UI thread (thousands of photos in DCIM stay smooth).
Future<ListResult> listDir(String dir) => Isolate.run(() => listDirSync(dir));

ListResult listDirSync(String dir) {
  final out = <Entry>[];
  try {
    for (final e in Directory(dir).listSync(followLinks: false)) {
      try {
        var st = e.statSync();
        final isLink = e is Link;
        if (isLink) {
          // Follow the link for type/size; a broken link stays a file of size 0.
          final t = FileStat.statSync(e.path);
          if (t.type != FileSystemEntityType.notFound) st = t;
        }
        out.add(Entry(
          path: e.path,
          name: nameOf(e.path),
          isDir: st.type == FileSystemEntityType.directory,
          size: st.type == FileSystemEntityType.directory ? 0 : st.size,
          modified: st.modified,
          isLink: isLink,
          mode: st.mode,
        ));
      } catch (_) {}
    }
  } on FileSystemException catch (e) {
    return ListResult(out, error: e.osError?.message ?? e.message);
  }
  return ListResult(out);
}

/// Size of files and folders, counted recursively.
class TreeStats {
  int files = 0;
  int dirs = 0;
  int bytes = 0;
}

Future<TreeStats> measure(List<String> paths) => Isolate.run(() {
      final s = TreeStats();
      for (final p in paths) {
        _measure(p, s);
      }
      return s;
    });

void _measure(String path, TreeStats s) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.directory) {
    s.dirs++;
    try {
      for (final e in Directory(path).listSync(recursive: true, followLinks: false)) {
        if (e is Directory) {
          s.dirs++;
        } else {
          s.files++;
          try {
            s.bytes += e.statSync().size;
          } catch (_) {}
        }
      }
    } catch (_) {}
  } else if (type != FileSystemEntityType.notFound) {
    s.files++;
    try {
      s.bytes += File(path).lengthSync();
    } catch (_) {}
  }
}

// ---------------------------------------------------------------- jobs

enum JobKind { copy, move, delete, zip, extract }

enum ConflictAction { overwrite, skip, rename, cancel }

/// What the conflict dialog shows: the incoming item vs the existing one.
class ConflictInfo {
  ConflictInfo(this.name, {this.srcSize, this.srcTime, this.dstSize, this.dstTime, this.dstIsDir = false});
  final String name;
  final int? srcSize, dstSize;
  final DateTime? srcTime, dstTime;
  final bool dstIsDir;

  static ConflictInfo local(String src, String dst) {
    FileStat? a, b;
    try {
      a = FileStat.statSync(src);
      b = FileStat.statSync(dst);
    } catch (_) {}
    final aFile = a != null && a.type != FileSystemEntityType.directory && a.type != FileSystemEntityType.notFound;
    final bFile = b != null && b.type != FileSystemEntityType.directory && b.type != FileSystemEntityType.notFound;
    return ConflictInfo(nameOf(dst),
        srcSize: aFile ? a.size : null,
        srcTime: a?.modified,
        dstSize: bFile ? b.size : null,
        dstTime: b?.modified,
        dstIsDir: b?.type == FileSystemEntityType.directory);
  }
}

class ConflictAnswer {
  const ConflictAnswer(this.action, {this.forAll = false});
  final ConflictAction action;
  final bool forAll;
}

typedef ConflictAsker = Future<ConflictAnswer> Function(ConflictInfo info);

class JobCancelled implements Exception {}

/// A running file operation; the UI listens to it for progress.
class Job {
  Job(this.kind, this.sources, {this.target = '', this.zipName = '', this.items = const []});

  final JobKind kind;
  final List<String> sources;

  /// The selected entries (remote ones carry their cloud IDs).
  final List<Entry> items;
  final String target;
  final String zipName;

  int totalBytes = 0, doneBytes = 0;
  int totalFiles = 0, doneFiles = 0;
  String current = '';
  bool cancelled = false;
  bool finished = false;
  final List<String> errors = [];

  /// Paths created or changed, for the media scanner.
  final List<String> touched = [];

  final _ctl = StreamController<void>.broadcast();
  Stream<void> get changes => _ctl.stream;
  DateTime _lastPing = DateTime(0);

  void ping({bool force = false}) {
    final now = DateTime.now();
    if (force || now.difference(_lastPing).inMilliseconds > 80) {
      _lastPing = now;
      if (!_ctl.isClosed) _ctl.add(null);
    }
  }

  double? get progress {
    if (totalBytes > 0) return (doneBytes / totalBytes).clamp(0, 1);
    if (totalFiles > 0) return (doneFiles / totalFiles).clamp(0, 1);
    return null;
  }

  void check() {
    if (cancelled) throw JobCancelled();
  }

  void close() {
    finished = true;
    ping(force: true);
    _ctl.close();
  }
}

/// Runs copy / move / delete with progress, conflict questions and cancel.
class FileOps {
  FileOps(this.ask);
  final ConflictAsker ask;
  ConflictAnswer? _all;

  static const _chunk = 1 << 20;

  Future<void> run(Job job) async {
    _all = null;
    try {
      final remote = isRemote(job.target) || job.sources.any(isRemote);
      if (remote && job.kind != JobKind.zip && job.kind != JobKind.extract) {
        await RemoteOps(job, _askRemote).run();
        return;
      }
      switch (job.kind) {
        case JobKind.copy:
        case JobKind.move:
          await _transfer(job);
        case JobKind.delete:
          await _delete(job);
        case JobKind.zip:
          await _zip(job);
        case JobKind.extract:
          await _extract(job);
      }
    } on JobCancelled {
      job.cancelled = true;
    } finally {
      job.close();
    }
  }

  /// Conflict question for remote transfers (same "for all" memory).
  Future<ConflictAction> _askRemote(ConflictInfo info) async {
    var a = _all;
    if (a == null) {
      final ans = await ask(info);
      if (ans.forAll) _all = ans;
      a = ans;
    }
    return a.action;
  }

  Future<void> _transfer(Job job) async {
    final move = job.kind == JobKind.move;
    // Moving a folder onto itself or inside itself would never end.
    for (final s in job.sources) {
      if (isInside(job.target, s)) {
        job.errors.add('${nameOf(s)}: ${tr('nu poate fi copiat în el însuși', 'can\'t be copied into itself')}');
        return;
      }
    }
    final st = await measure(job.sources);
    job.totalBytes = st.bytes;
    job.totalFiles = st.files;
    job.ping(force: true);
    await Directory(job.target).create(recursive: true);

    for (final src in job.sources) {
      job.check();
      final sameDir = parentOf(src) == job.target;
      var dst = join(job.target, nameOf(src));
      if (sameDir) {
        if (move) continue; // nothing to do
        dst = join(job.target, uniqueName(nameOf(src), (n) => FileSystemEntity.typeSync(join(job.target, n), followLinks: false) != FileSystemEntityType.notFound));
      }
      if (move) {
        final (done, next) = await _tryRename(job, src, dst);
        if (done) continue;
        dst = next;
      }
      // Across volumes: copy, removing each source file only once its copy is
      // complete, so skipped or failed files stay where they were.
      await _copyAny(job, src, dst, move: move);
    }
  }

  /// Same volume: a rename is instant. Returns (true, _) when handled
  /// (moved or skipped), otherwise (false, target) and a copy is needed.
  Future<(bool, String)> _tryRename(Job job, String src, String dst) async {
    final isDir = FileSystemEntity.isDirectorySync(src);
    final dstType = FileSystemEntity.typeSync(dst, followLinks: false);
    if (dstType != FileSystemEntityType.notFound) {
      // Folder onto existing folder: merge file by file.
      if (isDir && dstType == FileSystemEntityType.directory) return (false, dst);
      final r = await _resolve(src, dst, dstType == FileSystemEntityType.directory);
      if (r == null) {
        final st = await measure([src]);
        job.doneBytes += st.bytes;
        job.doneFiles += st.files;
        job.ping();
        return (true, dst);
      }
      if (r == dst) {
        try {
          await _deleteAny(dst);
        } catch (e) {
          job.errors.add('${nameOf(dst)}: ${_msg(e)}');
          return (true, dst);
        }
      }
      dst = r;
    }
    try {
      final st = await measure([src]);
      if (isDir) {
        await Directory(src).rename(dst);
      } else {
        await File(src).rename(dst);
      }
      job.doneBytes += st.bytes;
      job.doneFiles += st.files;
      job.touched..add(src)..add(dst);
      job.ping();
      return (true, dst);
    } on FileSystemException {
      return (false, dst);
    }
  }

  /// Asks what to do with an existing target. Returns the path to write
  /// (same or renamed) or null to skip.
  Future<String?> _resolve(String src, String dst, bool dstIsDir) async {
    var a = _all;
    if (a == null) {
      final ans = await ask(ConflictInfo.local(src, dst));
      if (ans.forAll) _all = ans;
      a = ans;
    }
    switch (a.action) {
      case ConflictAction.skip:
        return null;
      case ConflictAction.cancel:
        throw JobCancelled();
      case ConflictAction.overwrite:
        return dst;
      case ConflictAction.rename:
        final dir = parentOf(dst);
        return join(dir, uniqueName(nameOf(dst), (n) => FileSystemEntity.typeSync(join(dir, n), followLinks: false) != FileSystemEntityType.notFound));
    }
  }

  Future<void> _copyAny(Job job, String src, String dst, {bool move = false}) async {
    job.check();
    final type = FileSystemEntity.typeSync(src, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      if (FileSystemEntity.typeSync(dst, followLinks: false) == FileSystemEntityType.file) {
        final r = await _resolve(src, dst, false);
        if (r == null) return;
        if (r == dst) await File(dst).delete();
        dst = r;
      }
      await Directory(dst).create(recursive: true);
      job.touched.add(dst);
      final children = Directory(src).listSync(followLinks: false);
      for (final c in children) {
        await _copyAny(job, c.path, join(dst, nameOf(c.path)), move: move);
      }
      if (move) {
        try {
          await Directory(src).delete(); // only succeeds when emptied
          job.touched.add(src);
        } catch (_) {}
      }
    } else if (type == FileSystemEntityType.link) {
      try {
        final target = Link(src).targetSync();
        if (FileSystemEntity.typeSync(dst, followLinks: false) != FileSystemEntityType.notFound) {
          final r = await _resolve(src, dst, false);
          if (r == null) return;
          if (r == dst) await _deleteAny(dst);
          dst = r;
        }
        await Link(dst).create(target);
        if (move) await Link(src).delete();
      } catch (e) {
        job.errors.add('$src: $e');
      }
    } else {
      await _copyFile(job, src, dst, move: move);
    }
  }

  Future<void> _copyFile(Job job, String src, String dst, {bool move = false}) async {
    final exists = FileSystemEntity.typeSync(dst, followLinks: false);
    if (exists != FileSystemEntityType.notFound) {
      final r = await _resolve(src, dst, exists == FileSystemEntityType.directory);
      if (r == null) {
        final len = File(src).lengthSync();
        job.doneBytes += len;
        job.doneFiles++;
        job.ping();
        return;
      }
      if (r == dst) {
        if (exists == FileSystemEntityType.directory) {
          await Directory(dst).delete(recursive: true);
        }
      }
      dst = r;
    }
    job.current = nameOf(src);
    job.ping(force: true);
    final part = '$dst.ncpart';
    RandomAccessFile? in_, out;
    try {
      in_ = await File(src).open();
      out = await File(part).open(mode: FileMode.write);
      while (true) {
        job.check();
        final bytes = await in_.read(_chunk);
        if (bytes.isEmpty) break;
        await out.writeFrom(bytes);
        job.doneBytes += bytes.length;
        job.ping();
      }
      await out.close();
      out = null;
      await in_.close();
      in_ = null;
      final f = File(part);
      if (FileSystemEntity.typeSync(dst) == FileSystemEntityType.file) await File(dst).delete();
      await f.rename(dst);
      try {
        await File(dst).setLastModified(File(src).lastModifiedSync());
      } catch (_) {}
      job.doneFiles++;
      job.touched.add(dst);
      if (move) {
        await File(src).delete();
        job.touched.add(src);
      }
      job.ping();
    } on JobCancelled {
      await _cleanup(in_, out, part);
      rethrow;
    } catch (e) {
      await _cleanup(in_, out, part);
      job.errors.add('$src: ${_msg(e)}');
    }
  }

  Future<void> _cleanup(RandomAccessFile? a, RandomAccessFile? b, String part) async {
    try {
      await a?.close();
    } catch (_) {}
    try {
      await b?.close();
    } catch (_) {}
    try {
      final f = File(part);
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  Future<void> _delete(Job job) async {
    job.totalFiles = job.sources.length;
    job.ping(force: true);
    for (final p in job.sources) {
      job.check();
      job.current = nameOf(p);
      job.ping();
      try {
        await _deleteAny(p);
        job.touched.add(p);
      } catch (e) {
        job.errors.add('${nameOf(p)}: ${_msg(e)}');
      }
      job.doneFiles++;
    }
  }

  static Future<void> _deleteAny(String p) async {
    final type = FileSystemEntity.typeSync(p, followLinks: false);
    switch (type) {
      case FileSystemEntityType.directory:
        await Directory(p).delete(recursive: true);
      case FileSystemEntityType.link:
        await Link(p).delete();
      case FileSystemEntityType.notFound:
        break;
      default:
        await File(p).delete();
    }
  }

  // ----------------------------------------------------------- archives

  Future<void> _zip(Job job) async {
    final out = join(job.target, job.zipName);
    if (FileSystemEntity.typeSync(out) != FileSystemEntityType.notFound) {
      final r = await _resolve(job.sources.first, out, false);
      if (r == null) return;
      if (r != out) {
        await _runIsolate(job, _zipWorker, [job.sources, r]);
        job.touched.add(r);
        return;
      }
    }
    await _runIsolate(job, _zipWorker, [job.sources, out]);
    job.touched.add(out);
  }

  Future<void> _extract(Job job) async {
    // Conflicts inside archives: overwrite (TC asks once; keep it simple and safe
    // by extracting into a folder named after the archive when needed).
    await _runIsolate(job, _extractWorker, [job.sources.first, job.target]);
    job.touched.add(job.target);
  }

  /// Runs [worker] in an isolate; it reports [done, total, name] lists and
  /// finally an error list.
  Future<void> _runIsolate(Job job, void Function(List<Object?>) worker, List<Object?> args) async {
    final port = ReceivePort();
    final iso = await Isolate.spawn(worker, [port.sendPort, ...args], onExit: port.sendPort);
    final c = Completer<void>();
    final sub = port.listen((m) {
      if (m == null) {
        if (!c.isCompleted) c.complete();
      } else if (m is List && m.length == 3) {
        job.doneFiles = m[0] as int;
        job.totalFiles = m[1] as int;
        job.current = m[2] as String;
        job.ping();
      } else if (m is List && m.length == 1) {
        job.errors.addAll((m[0] as List).cast<String>());
      }
    });
    final watcher = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (job.cancelled) {
        iso.kill(priority: Isolate.immediate);
        if (!c.isCompleted) c.complete();
      }
    });
    await c.future;
    watcher.cancel();
    await sub.cancel();
    port.close();
    if (job.cancelled) {
      // A half-written zip is useless.
      if (job.kind == JobKind.zip) {
        try {
          final f = File(args[1] as String);
          if (f.existsSync()) f.deleteSync();
        } catch (_) {}
      }
      throw JobCancelled();
    }
  }
}


String _msg(Object e) {
  if (e is FileSystemException) return e.osError?.message ?? e.message;
  return e.toString();
}

void _zipWorker(List<Object?> a) {
  final send = a[0] as SendPort;
  final sources = (a[1] as List).cast<String>();
  final out = a[2] as String;
  final errors = <String>[];
  // Flat list of every file with its name inside the archive.
  final items = <(String, String, bool)>[];
  for (final s in sources) {
    final base = parentOf(s);
    if (FileSystemEntity.isDirectorySync(s)) {
      items.add((s, s.substring(base.length + (base == '/' ? 0 : 1)), true));
      try {
        for (final e in Directory(s).listSync(recursive: true, followLinks: false)) {
          final rel = e.path.substring(base.length + (base == '/' ? 0 : 1));
          items.add((e.path, rel, e is Directory));
        }
      } catch (e) {
        errors.add('$s: $e');
      }
    } else {
      items.add((s, nameOf(s), false));
    }
  }
  final enc = ZipFileEncoder();
  enc.create(out);
  var done = 0;
  for (final (path, rel, dir) in items) {
    try {
      if (dir) {
        enc.addArchiveFile(ArchiveFile.directory(rel));
      } else {
        enc.addFileSync(File(path), rel);
      }
    } catch (e) {
      errors.add('$rel: $e');
    }
    done++;
    send.send([done, items.length, nameOf(path)]);
  }
  enc.closeSync();
  send.send([errors]);
}

void _extractWorker(List<Object?> a) {
  final send = a[0] as SendPort;
  final zip = a[1] as String;
  final outDir = a[2] as String;
  final errors = <String>[];
  final input = InputFileStream(zip);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final files = archive.files;
    var done = 0;
    final root = Directory(outDir).absolute.path;
    for (final f in files) {
      final rel = f.name.replaceAll('\\', '/');
      final dest = Directory('$root/$rel').absolute.path;
      final norm = Uri.file(dest).normalizePath().toFilePath();
      // Zip-slip guard: entries must stay inside the target folder.
      if (!isInside(norm, root)) {
        errors.add('$rel: path outside target');
        continue;
      }
      try {
        if (f.isDirectory) {
          Directory(norm).createSync(recursive: true);
        } else {
          Directory(parentOf(norm)).createSync(recursive: true);
          final out = OutputFileStream(norm);
          f.writeContent(out);
          out.closeSync();
          try {
            File(norm).setLastModifiedSync(f.lastModDateTime);
          } catch (_) {}
        }
      } catch (e) {
        errors.add('$rel: $e');
      }
      done++;
      send.send([done, files.length, nameOf(rel)]);
    }
  } catch (e) {
    errors.add('${nameOf(zip)}: $e');
  } finally {
    input.closeSync();
  }
  send.send([errors]);
}

/// Entries inside a zip, for browsing.
class ZipItem {
  ZipItem(this.name, this.size, this.isDir, this.modified);
  final String name; // full path inside the archive, "/" separated
  final int size;
  final bool isDir;
  final DateTime modified;
}

Future<List<ZipItem>> readZip(String path) => Isolate.run(() {
      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        return [
          for (final f in archive.files)
            ZipItem(f.name.replaceAll('\\', '/'), f.size, f.isDirectory, f.lastModDateTime),
        ];
      } finally {
        input.closeSync();
      }
    });

/// Extracts one entry to [dest] (used to open a file from inside an archive).
Future<void> extractOne(String zip, String entryName, String dest) => Isolate.run(() {
      final input = InputFileStream(zip);
      try {
        final archive = ZipDecoder().decodeStream(input);
        final f = archive.files.firstWhere((f) => f.name.replaceAll('\\', '/') == entryName);
        Directory(parentOf(dest)).createSync(recursive: true);
        final out = OutputFileStream(dest);
        f.writeContent(out);
        out.closeSync();
      } finally {
        input.closeSync();
      }
    });

/// What to look for. Plain data so it can go to the search isolate.
class SearchQuery {
  const SearchQuery({
    this.mask = '',
    this.kinds = const {},
    this.minSize,
    this.maxSize,
    this.after,
    this.content = '',
    this.recursive = true,
    this.hidden = false,
    this.foldersOnly = false,
  });
  final String mask;
  final Set<String> kinds; // Kind names
  final int? minSize, maxSize;
  final DateTime? after;
  final String content;
  final bool recursive, hidden, foldersOnly;

  bool get isEmpty => mask.trim().isEmpty && kinds.isEmpty && minSize == null && maxSize == null && after == null && content.trim().isEmpty && !foldersOnly;
}

bool _matches(Entry e, SearchQuery q, String needle) {
  if (q.foldersOnly && !e.isDir) return false;
  if (!e.isDir) {
    if (q.kinds.isNotEmpty && !q.kinds.contains(e.kind.name)) return false;
    if (q.minSize != null && e.size < q.minSize!) return false;
    if (q.maxSize != null && e.size > q.maxSize!) return false;
  } else if (q.kinds.isNotEmpty || q.minSize != null || q.maxSize != null || needle.isNotEmpty) {
    return false;
  }
  if (q.after != null && e.modified.isBefore(q.after!)) return false;
  if (q.mask.trim().isNotEmpty && !matchesMask(e.name, q.mask)) return false;
  if (needle.isNotEmpty) {
    if (e.size > 4 * 1024 * 1024 || e.size == 0) return false;
    final k = e.kind;
    if (k != Kind.text && k != Kind.code && k != Kind.other && !(k == Kind.sheet && e.ext == 'csv')) return false;
    try {
      final text = utf8.decode(File(e.path).readAsBytesSync(), allowMalformed: true).toLowerCase();
      if (!text.contains(needle)) return false;
    } catch (_) {
      return false;
    }
  }
  return true;
}

/// Recursive search in one background isolate; results stream in batches.
/// Cancel the subscription to stop.
Stream<List<Entry>> search(String root, SearchQuery query) {
  late StreamController<List<Entry>> ctl;
  Isolate? iso;
  final port = ReceivePort();
  ctl = StreamController<List<Entry>>(
    onListen: () async {
      port.listen((m) {
        if (m == null) {
          ctl.close();
          port.close();
        } else if (m is List<Entry>) {
          ctl.add(m);
        }
      });
      iso = await Isolate.spawn(_searchWorker, [port.sendPort, root, query], onExit: port.sendPort);
    },
    onCancel: () {
      iso?.kill(priority: Isolate.immediate);
      port.close();
    },
  );
  return ctl.stream;
}

void _searchWorker(List<Object?> a) {
  final send = a[0] as SendPort;
  final root = a[1] as String;
  final q = a[2] as SearchQuery;
  final needle = q.content.trim().toLowerCase();
  final queue = <String>[root];
  var batch = <Entry>[];
  var n = 0;
  var last = DateTime.now();
  while (queue.isNotEmpty && n < 5000) {
    final r = listDirSync(queue.removeAt(0));
    for (final e in r.entries) {
      if (!q.hidden && e.hidden) continue;
      if (q.recursive && e.isDir && !e.isLink) queue.add(e.path);
      if (_matches(e, q, needle)) {
        batch.add(e);
        n++;
      }
    }
    if (batch.isNotEmpty && DateTime.now().difference(last).inMilliseconds > 120) {
      send.send(batch);
      batch = <Entry>[];
      last = DateTime.now();
    }
  }
  if (batch.isNotEmpty) send.send(batch);
}
