import 'package:flutter/material.dart';

import 'format.dart';

enum Kind { folder, image, video, audio, archive, apk, pdf, doc, sheet, slides, text, code, other }

const _map = <String, Kind>{
  // images
  'jpg': Kind.image, 'jpeg': Kind.image, 'png': Kind.image, 'gif': Kind.image, 'webp': Kind.image,
  'bmp': Kind.image, 'heic': Kind.image, 'heif': Kind.image, 'svg': Kind.image, 'dng': Kind.image, 'avif': Kind.image,
  // video
  'mp4': Kind.video, 'mkv': Kind.video, 'avi': Kind.video, 'mov': Kind.video, 'webm': Kind.video,
  '3gp': Kind.video, 'm4v': Kind.video, 'ts': Kind.video, 'wmv': Kind.video,
  // audio
  'mp3': Kind.audio, 'm4a': Kind.audio, 'aac': Kind.audio, 'flac': Kind.audio, 'wav': Kind.audio,
  'ogg': Kind.audio, 'opus': Kind.audio, 'amr': Kind.audio, 'wma': Kind.audio, 'mid': Kind.audio,
  // archives
  'zip': Kind.archive, 'rar': Kind.archive, '7z': Kind.archive, 'tar': Kind.archive, 'gz': Kind.archive,
  'tgz': Kind.archive, 'bz2': Kind.archive, 'xz': Kind.archive,
  'apk': Kind.apk, 'apks': Kind.apk, 'xapk': Kind.apk,
  'pdf': Kind.pdf,
  'doc': Kind.doc, 'docx': Kind.doc, 'odt': Kind.doc, 'rtf': Kind.doc,
  'xls': Kind.sheet, 'xlsx': Kind.sheet, 'ods': Kind.sheet, 'csv': Kind.sheet,
  'ppt': Kind.slides, 'pptx': Kind.slides, 'odp': Kind.slides,
  'txt': Kind.text, 'md': Kind.text, 'log': Kind.text, 'ini': Kind.text, 'cfg': Kind.text, 'conf': Kind.text,
  'nfo': Kind.text, 'srt': Kind.text, 'vtt': Kind.text, 'prop': Kind.text, 'properties': Kind.text,
  'json': Kind.code, 'xml': Kind.code, 'html': Kind.code, 'htm': Kind.code, 'css': Kind.code, 'js': Kind.code,
  'dart': Kind.code, 'kt': Kind.code, 'java': Kind.code, 'py': Kind.code, 'sh': Kind.code, 'bat': Kind.code,
  'c': Kind.code, 'cpp': Kind.code, 'h': Kind.code, 'php': Kind.code, 'yaml': Kind.code, 'yml': Kind.code,
  'sql': Kind.code, 'gradle': Kind.code, 'kts': Kind.code, 'toml': Kind.code, 'ps1': Kind.code,
};

Kind kindOf(String name, {bool dir = false}) => dir ? Kind.folder : (_map[extOf(name)] ?? Kind.other);

/// Opens in the built-in editor.
bool isTextKind(Kind k) => k == Kind.text || k == Kind.code;

extension KindX on Kind {
  IconData get icon => switch (this) {
        Kind.folder => Icons.folder_rounded,
        Kind.image => Icons.image_rounded,
        Kind.video => Icons.movie_rounded,
        Kind.audio => Icons.music_note_rounded,
        Kind.archive => Icons.folder_zip_rounded,
        Kind.apk => Icons.android_rounded,
        Kind.pdf => Icons.picture_as_pdf_rounded,
        Kind.doc => Icons.description_rounded,
        Kind.sheet => Icons.table_chart_rounded,
        Kind.slides => Icons.slideshow_rounded,
        Kind.text => Icons.article_rounded,
        Kind.code => Icons.code_rounded,
        Kind.other => Icons.insert_drive_file_rounded,
      };

  /// Fixed hues so a type is recognisable in any theme colour.
  Color color(ColorScheme cs) => switch (this) {
        Kind.folder => cs.primary,
        Kind.image => const Color(0xFF2E9E5B),
        Kind.video => const Color(0xFFD9483B),
        Kind.audio => const Color(0xFF8E5BD8),
        Kind.archive => const Color(0xFFC98A1B),
        Kind.apk => const Color(0xFF3DA35D),
        Kind.pdf => const Color(0xFFD23F31),
        Kind.doc => const Color(0xFF2F6FD6),
        Kind.sheet => const Color(0xFF1E8E4E),
        Kind.slides => const Color(0xFFE0682A),
        Kind.text => const Color(0xFF607D8B),
        Kind.code => const Color(0xFF00897B),
        Kind.other => cs.onSurfaceVariant,
      };

  /// MIME type for "Open with" / "Share".
  String mimeFor(String name) {
    final e = extOf(name);
    const exact = {
      'jpg': 'image/jpeg', 'jpeg': 'image/jpeg', 'png': 'image/png', 'gif': 'image/gif', 'webp': 'image/webp',
      'heic': 'image/heic', 'svg': 'image/svg+xml', 'bmp': 'image/bmp',
      'mp4': 'video/mp4', 'mkv': 'video/x-matroska', 'webm': 'video/webm', 'mov': 'video/quicktime', '3gp': 'video/3gpp',
      'avi': 'video/x-msvideo',
      'mp3': 'audio/mpeg', 'm4a': 'audio/mp4', 'aac': 'audio/aac', 'flac': 'audio/flac', 'wav': 'audio/wav',
      'ogg': 'audio/ogg', 'opus': 'audio/opus', 'amr': 'audio/amr',
      'pdf': 'application/pdf', 'zip': 'application/zip', 'rar': 'application/vnd.rar', '7z': 'application/x-7z-compressed',
      'apk': 'application/vnd.android.package-archive',
      'doc': 'application/msword', 'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xls': 'application/vnd.ms-excel', 'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'ppt': 'application/vnd.ms-powerpoint', 'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'odt': 'application/vnd.oasis.opendocument.text', 'ods': 'application/vnd.oasis.opendocument.spreadsheet',
      'csv': 'text/csv', 'html': 'text/html', 'htm': 'text/html', 'json': 'application/json', 'xml': 'text/xml',
      'txt': 'text/plain', 'md': 'text/markdown', 'vcf': 'text/x-vcard', 'ics': 'text/calendar',
    };
    if (exact[e] case final m?) return m;
    return switch (this) {
      Kind.image => 'image/*',
      Kind.video => 'video/*',
      Kind.audio => 'audio/*',
      Kind.text || Kind.code => 'text/plain',
      _ => '*/*',
    };
  }
}
