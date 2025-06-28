A small zip library totally based on stream and transformer.

## Usage

* zip a file

```dart
import 'dart:convert';
import 'dart:io';

import 'package:zip2/zip2.dart';

void main() async {
  final data = File('large.txt').openRead();
  final archive = ZipArchive([
    ZipFileEntry(
      name: 'hello.txt',
      data: Stream.fromIterable([
        utf8.encode('Hello, Dart Zip Package!'),
      ]),
      method: ZipMethod.stored, // STORED (no compression)
    ),
    ZipFileEntry(
      name: 'large.txt',
      data: data,
      method: ZipMethod.deflated, // DEFLATED
    ),
  ]);
  await archive.zip().pipe(File('example.zip').openWrite());
}
```
* unzip a file
```dart
import 'dart:io';

import 'package:zip2/zip2.dart';

void main() async {
  final file = await File('example.zip').open();
  final archive = file.unzip();
  final entry = archive['hello.txt'];
  await entry?.data.pipe(File('hello.txt').openWrite());
}
```
also cli commands are available.

* zip a file
```bash
dart bin/zip.dart example.zip a.txt b.docx
```

* unzip a file
```bash
dart bin/unzip.dart example.zip
```
