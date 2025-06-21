import 'dart:io' show Directory, File, FileSystemEntity;

import 'package:zip2/zip2.dart' show ZipFileEntry, ZipEntryItorExt;

Iterable<String> _expand(Iterable<String> files) sync* {
  for (final f in files) {
    if (FileSystemEntity.isDirectorySync(f)) {
      yield* _listRecursive(Directory(f));
    } else {
      yield f;
    }
  }
}

Iterable<String> _listRecursive(Directory dir) {
  return dir
      .listSync(recursive: true)
      .where((e) => !FileSystemEntity.isDirectorySync(e.path))
      .map((e) => e.path);
}

void main(List<String> argv) {
  final target =
      argv.isNotEmpty ? argv[0] : throw Exception('No zip file specified!');
  final entries = _expand(argv.sublist(1))
      .map((f) => ZipFileEntry(name: f, data: File(f).openRead()));

  if (entries.isEmpty) {
    return;
  }
  entries.zip().pipe(File(target).openWrite());
}
