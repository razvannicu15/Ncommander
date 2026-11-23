import 'dart:io';

import 'package:flutter/material.dart';

import '../core/i18n.dart';
import '../services/store.dart';
import '../services/vfs.dart';
import '../services/vfs_ftp.dart';
import '../services/vfs_gdrive.dart';
import '../services/vfs_onedrive.dart';
import 'widgets.dart';

String _newId() => DateTime.now().microsecondsSinceEpoch.toRadixString(36);

IconData connIcon(ConnType t) => switch (t) {
      ConnType.ftp => Icons.dns_outlined,
      ConnType.gdrive => Icons.add_to_drive_rounded,
      ConnType.onedrive => Icons.cloud_outlined,
      ConnType.zip => Icons.folder_zip_outlined,
    };

String connSubtitle(Conn c) => switch (c.type) {
      ConnType.ftp => '${c.tls ? 'FTPS' : 'FTP'} · ${c.user.isEmpty ? '' : '${c.user}@'}${c.host}${c.port == 21 ? '' : ':${c.port}'}',
      ConnType.gdrive => 'Google Drive · ${c.account}',
      ConnType.onedrive => 'OneDrive · ${c.account}',
      ConnType.zip => c.host,
    };

/// Picks the type, then sets it up. Returns the new connection.
/// [type] skips the picker (the "+ Google Drive" row in the Cloud list).
Future<Conn?> addConnection(BuildContext context, {ConnType? type}) async {
  if (!await store.ensureUnlocked()) return null;
  if (!context.mounted) return null;
  final t = type ?? await showModalBottomSheet<ConnType>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        SheetTitle(tr('Conexiune nouă', 'New connection')),
        for (final t in ConnType.values.where((t) => t != ConnType.zip))
          ListTile(
            leading: Icon(connIcon(t)),
            title: Text(connLabel(t)),
            onTap: () => Navigator.pop(ctx, t),
          ),
        const SizedBox(height: 8),
      ]),
    ),
  );
  if (t == null || !context.mounted) return null;
  switch (t) {
    case ConnType.ftp:
      return editFtp(context);
    case ConnType.gdrive:
      return _signIn(context, () async {
        final have = store.conns.where((c) => c.type == ConnType.gdrive).map((c) => c.account.toLowerCase()).toSet();
        final (email, token) = await connectGoogle(existing: have);
        if (have.contains(email.toLowerCase())) throw RemoteException(tr('Contul $email e deja adăugat', '$email is already added'));
        // Two Drive accounts: tell them apart by name.
        final name = have.isEmpty ? 'Google Drive' : 'Drive · ${email.split('@').first}';
        return Conn(id: _newId(), type: ConnType.gdrive, name: name, account: email, token: token);
      });
    case ConnType.onedrive:
      var id = store.onedriveClientId;
      if (id.isEmpty) {
        final v = await _askClientId(context);
        if (v == null || !context.mounted) return null;
        store.onedriveClientId = id = v;
        await store.save(notify: false);
      }
      if (!context.mounted) return null;
      return _signIn(context, () async {
        final (name, token) = await connectOneDrive(id);
        return Conn(id: _newId(), type: ConnType.onedrive, name: 'OneDrive', account: name, token: token);
      });
    case ConnType.zip:
      return null; // archives are opened from the panel, not added
  }
}

Future<Conn?> _signIn(BuildContext context, Future<Conn> Function() run) async {
  final nav = Navigator.of(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(children: [
          const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2.5)),
          const SizedBox(width: 18),
          Expanded(child: Text(tr('Autentificare…', 'Signing in…'))),
        ]),
      ),
    ),
  );
  try {
    final c = await run();
    nav.pop();
    store.conns.add(c);
    await store.save();
    return c;
  } catch (e) {
    nav.pop();
    if (context.mounted) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          icon: Icon(Icons.error_outline, color: Theme.of(ctx).colorScheme.error),
          title: Text(tr('Nu s-a putut conecta', 'Couldn\'t connect')),
          content: Text(remoteError(e)),
          actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('OK'))],
        ),
      );
    }
    return null;
  }
}

Future<String?> _askClientId(BuildContext context) {
  final ctl = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: const Icon(Icons.key_rounded),
      title: const Text('OneDrive'),
      content: TextField(
        controller: ctl,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Application (client) ID', hintText: '00000000-0000-0000-0000-000000000000'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
        FilledButton(
          onPressed: () {
            final v = ctl.text.trim();
            if (RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(v)) Navigator.pop(ctx, v);
          },
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// FTP server form with a "Test" button. Edits [existing] in place.
Future<Conn?> editFtp(BuildContext context, [Conn? existing]) async {
  // Passwords can only be shown / saved once the master password is entered.
  if (!await store.ensureUnlocked()) return null;
  if (!context.mounted) return null;
  final name = TextEditingController(text: existing?.name ?? '');
  final host = TextEditingController(text: existing?.host ?? '');
  final port = TextEditingController(text: '${existing?.port ?? 21}');
  final user = TextEditingController(text: existing?.user ?? '');
  final pass = TextEditingController(text: existing?.password ?? '');
  final folder = TextEditingController(text: existing?.folder ?? '/');
  var tls = existing?.tls ?? false;
  var showPass = false;
  String? status;
  bool? ok;
  var testing = false;

  Conn build() => Conn(
        id: existing?.id ?? _newId(),
        type: ConnType.ftp,
        name: name.text.trim().isEmpty ? host.text.trim() : name.text.trim(),
        host: host.text.trim(),
        port: int.tryParse(port.text.trim()) ?? 21,
        user: user.text.trim(),
        password: pass.text,
        tls: tls,
        folder: folder.text.trim().isEmpty ? '/' : folder.text.trim(),
      );

  final r = await showDialog<Conn>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final cs = Theme.of(ctx).colorScheme;
      InputDecoration dec(String label, {Widget? suffix, String? hint}) =>
          InputDecoration(labelText: label, hintText: hint, isDense: true, suffixIcon: suffix);
      Future<void> test() async {
        if (host.text.trim().isEmpty) return;
        set(() {
          testing = true;
          status = null;
        });
        final err = await testFtp(build());
        set(() {
          testing = false;
          ok = err == null;
          status = err ?? tr('Conectat', 'Connected');
        });
      }

      return AlertDialog(
        icon: const Icon(Icons.dns_outlined),
        title: Text(existing == null ? tr('Server FTP', 'FTP server') : existing.name),
        scrollable: true,
        content: SizedBox(
          width: 420,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: host, keyboardType: TextInputType.url, autofocus: existing == null, decoration: dec(tr('Server', 'Server'), hint: '192.168.1.10')),
            const SizedBox(height: 10),
            Row(children: [
              SizedBox(width: 96, child: TextField(controller: port, keyboardType: TextInputType.number, decoration: dec('Port'))),
              const SizedBox(width: 10),
              Expanded(
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('TLS (FTPS)'),
                  value: tls,
                  onChanged: (v) => set(() => tls = v),
                ),
              ),
            ]),
            const SizedBox(height: 10),
            TextField(controller: user, decoration: dec(tr('Utilizator', 'User'), hint: tr('gol = anonim', 'empty = anonymous'))),
            const SizedBox(height: 10),
            TextField(
              controller: pass,
              obscureText: !showPass,
              decoration: dec(tr('Parolă', 'Password'),
                  suffix: IconButton(
                    icon: Icon(showPass ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => set(() => showPass = !showPass),
                  )),
            ),
            const SizedBox(height: 10),
            TextField(controller: folder, decoration: dec(tr('Folder de pornire', 'Start folder'))),
            const SizedBox(height: 10),
            TextField(controller: name, decoration: dec(tr('Nume afișat', 'Display name'), hint: tr('ex. NAS', 'e.g. NAS'))),
            const SizedBox(height: 12),
            Row(children: [
              OutlinedButton.icon(
                onPressed: testing ? null : test,
                icon: testing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.network_check_rounded, size: 18),
                label: Text(tr('Testează', 'Test')),
              ),
              const SizedBox(width: 12),
              if (status != null)
                Expanded(
                  child: Text(status!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ok == true ? cs.primary : cs.error)),
                ),
            ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Anulează', 'Cancel'))),
          FilledButton(
            onPressed: () {
              if (host.text.trim().isEmpty) return;
              Navigator.pop(ctx, build());
            },
            child: Text(tr('Salvează', 'Save')),
          ),
        ],
      );
    }),
  );
  if (r == null) return null;
  if (existing != null) {
    existing
      ..name = r.name
      ..host = r.host
      ..port = r.port
      ..user = r.user
      ..password = r.password
      ..tls = r.tls
      ..folder = r.folder;
    forgetVfs(existing.id);
    await store.save();
    return existing;
  }
  store.conns.add(r);
  await store.save();
  return r;
}

Future<bool> confirmRemoveConn(BuildContext context, Conn c) async {
  final cs = Theme.of(context).colorScheme;
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      icon: Icon(Icons.link_off_rounded, color: cs.error),
      title: Text(tr('Elimini „${c.name}”?', 'Remove "${c.name}"?')),
      content: Text(connSubtitle(c), textAlign: TextAlign.center),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Anulează', 'Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: cs.error, foregroundColor: cs.onError),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(tr('Elimină', 'Remove')),
        ),
      ],
    ),
  );
  if (r != true) return false;
  store.conns.removeWhere((x) => x.id == c.id);
  forgetVfs(c.id);
  await store.save();
  return true;
}

/// Total Commander's FTP connect dialog (Ctrl+F): the saved FTP servers,
/// connect / new / edit / remove. Returns the server to open.
Future<Conn?> ftpConnectDialog(BuildContext context) => showDialog<Conn>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final cs = Theme.of(ctx).colorScheme;
        final ftp = store.conns.where((c) => c.type == ConnType.ftp).toList();
        return AlertDialog(
          icon: const Icon(Icons.dns_outlined),
          title: Text(tr('Conectare FTP', 'FTP connect')),
          contentPadding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
          content: SizedBox(
            width: 480,
            child: ftp.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(tr('Niciun server salvat.', 'No saved servers.'), textAlign: TextAlign.center, style: TextStyle(color: cs.onSurfaceVariant)),
                  )
                : ListView(shrinkWrap: true, children: [
                    for (final (i, c) in ftp.indexed)
                      ListTile(
                        autofocus: i == 0,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        leading: Icon(c.tls ? Icons.lock_outline_rounded : Icons.dns_outlined),
                        title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(connSubtitle(c), maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(ctx, c),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                            tooltip: tr('Editează', 'Edit'),
                            icon: const Icon(Icons.edit_outlined, size: 20),
                            onPressed: () async {
                              await editFtp(ctx, c);
                              set(() {});
                            },
                          ),
                          IconButton(
                            tooltip: tr('Elimină', 'Remove'),
                            icon: Icon(Icons.delete_outline, size: 20, color: cs.error),
                            onPressed: () async {
                              await confirmRemoveConn(ctx, c);
                              set(() {});
                            },
                          ),
                        ]),
                      ),
                  ]),
          ),
          actions: [
            TextButton.icon(
              icon: const Icon(Icons.add_rounded, size: 18),
              label: Text(tr('Server nou', 'New server')),
              onPressed: () async {
                final c = await editFtp(ctx);
                if (c != null && ctx.mounted) Navigator.pop(ctx, c);
              },
            ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text(tr('Închide', 'Close'))),
          ],
        );
      }),
    );
