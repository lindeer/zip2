import 'dart:async' show Completer, StreamController, StreamTransformerBase;
import 'dart:convert' show utf8;
import 'dart:io' show RandomAccessFile, ZLibDecoder, ZLibEncoder;
import 'dart:math' as m;
import 'dart:typed_data' show ByteData, BytesBuilder, Endian, Uint8List;
import 'package:meta/meta.dart' show visibleForTesting;

import 'zip_file_entry.dart';

part 'zip_decoder.dart';
part 'zip_encoder.dart';

/// Calculates the CRC-32 checksum of a list of bytes.
///
/// This implementation uses the polynomial 0xEDB88320, which is the reversed
/// form of the standard CRC-32 polynomial 0x04C11DB7.
///
/// Returns the CRC-32 checksum as an unsigned 32-bit integer.
class _Crc32 {
  static const _polynomial = 0xEDB88320;

  /// Generates the lookup table for CRC-32 calculation.
  static final _crcTable = List<int>.generate(256, (i) {
    int crc = i;
    for (var j = 0; j < 8; j++) {
      crc = (crc & 1) == 1 ? (crc >> 1) ^ _polynomial : crc >> 1;
    }
    return crc;
  });

  int _crc = 0xFFFFFFFF;

  int get value => _crc ^ 0xFFFFFFFF;

  @override
  String toString() => '0x${_crc.toRadixString(16).padLeft(8, '0')}';

  /// Updates the CRC-32 checksum with the given data.
  ///
  /// [bytes] The list of bytes to add to the checksum.
  ///
  void update(List<int> bytes) {
    var c = _crc;
    for (var byte in bytes) {
      c = _crcTable[(c ^ byte) & 0xFF] ^ (c >> 8);
    }
    _crc = c;
  }

  /// Calculates the CRC-32 checksum for a full list of bytes.
  ///
  /// [bytes] The list of bytes to calculate the checksum for.
  ///
  /// Returns the CRC-32 checksum as an unsigned 32-bit integer.
  static int calculate(List<int> bytes) {
    final crc = _Crc32()..update(bytes);
    return crc.value;
  }
}

@visibleForTesting
int crc32(List<int> bytes) => _Crc32.calculate(bytes);

// Constants for ZIP file format signatures and offsets
const _localFileHeaderSignature = 0x04034b50;
const _centralDirectoryFileHeaderSignature = 0x02014b50;
const _endOfCentralDirectorySignature = 0x06054b50;
const _dataDescriptorSignature = 0x08074b50; // Optional, but good to know

// Fixed sizes of headers
const _localFileHeaderBaseSize = 30; // Without filename and extra field
// Without filename, extra field, and comment
const _centralDirectoryFileHeaderBaseSize = 46;
// Without comment
const _endOfCentralDirectoryBaseSize = 22;
// CRC-32, compressed size, uncompressed size (no signature)
const _dataDescriptorSize = 12;
// With signature
const _dataDescriptorWithSignatureSize = 16;

/// Internal class to hold information for Central Directory Record creation.
/// Not exposed publicly.
class _CentralDirectoryRecord {
  final String fileName;
  final int fileNameLength;
  final int compressedSize;
  final int uncompressedSize;
  final int crc32;
  final int compressionMethod;
  final int lastModifiedTime;
  final int lastModifiedDate;
  final int localHeaderOffset;

  _CentralDirectoryRecord({
    required this.fileName,
    required this.fileNameLength,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.crc32,
    required this.compressionMethod,
    required this.lastModifiedTime,
    required this.lastModifiedDate,
    required this.localHeaderOffset,
  });
}

/// A const variable for convenience, just like utf8 in 'dart:convert'.
const zip = ZipLib();

class _BytesWrapper {
  final ByteData _data;
  int _position;

  _BytesWrapper._(this._data) : _position = 0;

  int get position => _position;

  int get length => _data.lengthInBytes;
}

/// A holder class for [ZipEncoder] and [ZipDecoder].
final class ZipLib {
  const ZipLib();

  ZipEncoder get encoder => const ZipEncoder();

  ZipDecoder get decoder => const ZipDecoder();
}
