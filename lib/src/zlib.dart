import 'dart:async' show Completer, StreamController, StreamTransformerBase;
import 'dart:convert' show utf8;
import 'dart:io' show ZLibEncoder;
import 'dart:typed_data' show ByteData, BytesBuilder, Endian, Uint8List;

import 'zip_file_entry.dart';

part 'zip_encoder.dart';

/// Calculates the CRC-32 checksum of a list of bytes.
///
/// This implementation uses the polynomial 0xEDB88320, which is the reversed
/// form of the standard CRC-32 polynomial 0x04C11DB7.
///
/// Returns the CRC-32 checksum as an unsigned 32-bit integer.
class _Crc32 {
  static const _polynomial = 0xEDB88320;
  static final _crcTable = _generateCrcTable();

  /// Generates the lookup table for CRC-32 calculation.
  static List<int> _generateCrcTable() {
    final table = List<int>.filled(256, 0);
    for (var i = 0; i < 256; i++) {
      var entry = i;
      for (var j = 0; j < 8; j++) {
        if ((entry & 1) == 1) {
          entry = (entry >> 1) ^ _polynomial;
        } else {
          entry >>= 1;
        }
      }
      table[i] = entry;
    }
    return table;
  }

  /// Updates the CRC-32 checksum with the given data.
  ///
  /// [crc] The current CRC-32 checksum. For a new calculation, start with `0xFFFFFFFF`.
  /// [bytes] The list of bytes to add to the checksum.
  ///
  /// Returns the updated CRC-32 checksum.
  static int update(int crc, List<int> bytes) {
    var c = crc ^ 0xFFFFFFFF;
    for (var i = 0; i < bytes.length; i++) {
      c = (c >> 8) ^ _crcTable[(c ^ bytes[i]) & 0xFF];
    }
    return c ^ 0xFFFFFFFF;
  }

  /// Calculates the CRC-32 checksum for a full list of bytes.
  ///
  /// [bytes] The list of bytes to calculate the checksum for.
  ///
  /// Returns the CRC-32 checksum as an unsigned 32-bit integer.
  static int calculate(List<int> bytes) => update(0xFFFFFFFF, bytes);
}

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

const zip = ZipLib();

class _BytesWrapper {
  final ByteData _data;
  int _position;

  _BytesWrapper._(this._data) : _position = 0;

  int get position => _position;

  int get length => _data.lengthInBytes;
}

final class ZipLib {
  const ZipLib();

  ZipEncoder get encoder => const ZipEncoder();
}
