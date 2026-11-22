import 'dart:async';

import 'package:flutter/material.dart';

import '../core/format.dart';
import '../core/i18n.dart';
import '../services/fs.dart';
import '../services/native.dart';
import 'dialogs.dart';

/// Runs file operations one after another and shows their progress.
class JobRunner extends ChangeNotifier {
  JobRunner(this.context, this.onDone);

  final BuildContext Function() context;
  final void Function(Job job) onDone;

  final List<Job> queue = [];
  Job? current;
  StreamSubscription<void>? _sub;

  void add(Job j) {
    queue.add(j);
    notifyListeners();
    if (current == null) _next();
  }

  Future<void> _next() async {
    if (queue.isEmpty) {
      current = null;
      notifyListeners();
      return;
    }
    final j = current = queue.removeAt(0);
    notifyListeners();
    _sub = j.changes.listen((_) => notifyListeners());
    final ops = FileOps((info) => askConflict(context(), info));
    await ops.run(j);
    await _sub?.cancel();
    final local = j.touched.where((p) => !p.contains('://')).toSet().toList();
    if (local.isNotEmpty) Native.scan(local);
    onDone(j);
    await _next();
  }

  void cancel() {
    current?.cancelled = true;
    for (final j in queue) {
      j.cancelled = true;
    }
    queue.clear();
    notifyListeners();
  }
}

String jobVerb(JobKind k, {bool past = false}) => switch (k) {
      JobKind.copy => past ? tr('Copiat', 'Copied') : tr('Copiez', 'Copying'),
      JobKind.move => past ? tr('Mutat', 'Moved') : tr('Mut', 'Moving'),
      JobKind.delete => past ? tr('Șters', 'Deleted') : tr('Șterg', 'Deleting'),
      JobKind.zip => past ? tr('Arhivat', 'Zipped') : tr('Arhivez', 'Zipping'),
      JobKind.extract => past ? tr('Dezarhivat', 'Extracted') : tr('Dezarhivez', 'Extracting'),
    };

IconData jobIcon(JobKind k) => switch (k) {
      JobKind.copy => Icons.file_copy_outlined,
      JobKind.move => Icons.drive_file_move_outline,
      JobKind.delete => Icons.delete_outline,
      JobKind.zip => Icons.folder_zip_outlined,
      JobKind.extract => Icons.unarchive_outlined,
    };

/// Progress card above the bottom bar.
class JobBar extends StatelessWidget {
  const JobBar({super.key, required this.runner});
  final JobRunner runner;

  @override
  Widget build(BuildContext context) {
    final j = runner.current;
    final cs = Theme.of(context).colorScheme;
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: j == null
          ? const SizedBox(width: double.infinity)
          : Container(
              margin: const EdgeInsets.fromLTRB(8, 6, 8, 2),
              padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
              decoration: BoxDecoration(
                color: cs.secondaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(children: [
                Icon(jobIcon(j.kind), color: cs.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Row(children: [
                      Expanded(
                        child: Text(
                          '${jobVerb(j.kind)}${j.totalFiles > 0 ? ' ${j.doneFiles}/${j.totalFiles}' : ''}${runner.queue.isNotEmpty ? '  +${runner.queue.length}' : ''}',
                          style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSecondaryContainer, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                      ),
                      if (j.totalBytes > 0)
                        Text('${fmtSize(j.doneBytes)} / ${fmtSize(j.totalBytes)}',
                            style: TextStyle(fontSize: 12, color: cs.onSecondaryContainer, fontFeatures: const [FontFeature.tabularFigures()])),
                    ]),
                    const SizedBox(height: 2),
                    Text(j.current.isEmpty ? '…' : j.current,
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: cs.onSecondaryContainer.withValues(alpha: 0.8))),
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(value: j.progress, minHeight: 5, backgroundColor: cs.onSecondaryContainer.withValues(alpha: 0.12)),
                    ),
                  ]),
                ),
                IconButton(
                  tooltip: tr('Oprește', 'Stop'),
                  icon: Icon(Icons.close_rounded, color: cs.onSecondaryContainer),
                  onPressed: runner.cancel,
                ),
              ]),
            ),
    );
  }
}
