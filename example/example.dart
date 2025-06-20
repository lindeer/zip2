import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:zip2/zip2.dart';

void main() async {
  final entries = Stream.fromIterable([
    ZipFileEntry(
      name: 'hello.txt',
      data: Stream.fromIterable([
        utf8.encode('Hello, Dart Zip Package!'),
      ]),
      lastModified: DateTime.now(),
      method: ZipMethod.deflated, // DEFLATED
    ),
    ZipFileEntry(
      name: 'empty.txt',
      data: Stream.fromIterable([
        Uint8List(0), // Empty file
      ]),
      lastModified: DateTime.now(),
      method: ZipMethod.stored, // STORED (no compression)
    ),
  ]);
  await entries
      .transform(zip2.encoder)
      .pipe(File('example.zip').openWrite());

  final file = await File('example.zip').open(mode: FileMode.read);
  await for (final entry in file.unzip()) {
    await entry.data.pipe(File(entry.name).openWrite());
  }
}
