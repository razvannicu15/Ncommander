import '../core/i18n.dart';
import '../models/entry.dart';
import 'fs.dart';
import 'store.dart';
import 'vfs_ftp.dart';
import 'vfs_gdrive.dart';
import 'vfs_onedrive.dart';
import 'vfs_zip.dart';

/// Called with bytes transferred since the last call.
typedef OnBytes = void Function(int delta);

/// A remote location (FTP server, Google Drive, OneDrive) browsed with
/// paths like "ftp://<connId>/folder/file".
abstract class Vfs {
  Vfs(this.conn);
  final Conn conn;

  String get root => conn.root;

  Future<List<Entry>> list(String path);

  /// Creates [name] in [dir]; returns the new folder's path.
  Future<String> mkdir(String dir, String name);

  /// Deletes (cloud: moves to the bin) a file or a whole folder.
  Future<void> delete(Entry e);

  Future<void> rename(Entry e, String newName);

  /// Existing child of [dir] named [name], or null.
  Future<Entry?> find(String dir, String name) async {
    for (final e in await list(dir)) {
      if (e.name == name) return e;
    }
    return null;
  }

  Future<void> download(Entry e, String localPath, OnBytes onBytes, bool Function() cancelled);

  /// Uploads a local file into [dir] as [name], replacing an existing one.
  Future<void> upload(String localPath, String dir, String name, OnBytes onBytes, bool Function() cancelled);

  /// [total, free] bytes, when the service tells.
  Future<(int, int)?> space() async => null;

  /// Name the file gets on the phone (Google Docs become .docx etc).
  String localName(Entry e) => e.name;

  void close() {}
}

final _cache = <String, Vfs>{};

/// The remote location for [path], or null for local paths / deleted connections.
Vfs? vfsFor(String path) {
  if (!isRemote(path)) return null;
  final root = rootOf(path);
  final id = root.substring(root.indexOf('://') + 3);
  final c = store.conn(id);
  if (c == null) return null;
  final hit = _cache[id];
  if (hit != null && identical(hit.conn, c)) return hit;
  hit?.close();
  final v = switch (c.type) {
    ConnType.ftp => FtpVfs(c),
    ConnType.gdrive => GDriveVfs(c),
    ConnType.onedrive => OneDriveVfs(c),
    ConnType.zip => ZipVfs(c),
  };
  return _cache[id] = v;
}

/// Drops the cached client (after editing or deleting a connection).
void forgetVfs(String id) => _cache.remove(id)?.close();

class RemoteException implements Exception {
  RemoteException(this.message, {this.status});
  final String message;

  /// HTTP status, when it came from a web API.
  final int? status;
  @override
  String toString() => message;
}

String remoteError(Object e) {
  if (e is RemoteException) return e.message;
  final s = e.toString();
  if (s.contains('SocketException') || s.contains('Failed host lookup')) return tr('Fără conexiune la server', 'Can\'t reach the server');
  if (s.contains('TimeoutException')) return tr('Serverul nu răspunde', 'The server doesn\'t respond');
  return s.replaceFirst('Exception: ', '');
}

String connLabel(ConnType t) => switch (t) {
      ConnType.ftp => 'FTP',
      ConnType.gdrive => 'Google Drive',
      ConnType.onedrive => 'OneDrive',
      ConnType.zip => 'ZIP',
    };
