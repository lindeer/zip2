import 'dart:io' show Directory, File, FileMode;

import 'package:path/path.dart' as p;
import 'package:zip2/src/zip_file_entry.dart';
import 'package:zip2/src/zlib.dart';

Future<void> _unzip(ZipFileEntry entry) async {
  final f = entry.name;
  final isDirectory = f.endsWith('/');
  final dir = Directory(isDirectory ? f : p.dirname(f));
  if (!dir.existsSync()) {
    dir.createSync(recursive: true);
  }
  if (!isDirectory) {
    await entry.data.pipe(File(f).openWrite());
  }
}

void main(List<String> argv) async {
  for (final f in argv) {
    final entries = File(f).openSync(mode: FileMode.read).unzip().entries;
    for (final entry in entries) {
      await _unzip(entry);
    }
  }
}
