import 'package:zip2/zip2.dart';
import 'package:test/test.dart';

void main() {
  test('test crc 32', () {
    expect(crc32('Hello, Dart Zip Package!'.codeUnits), 0xac787f4b);
  });
}
