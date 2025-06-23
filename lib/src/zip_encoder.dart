part of 'zlib.dart';

/// A util  class that transform from raw data to zip compressed data.
final class _Compressor extends StreamTransformerBase<List<int>, List<int>> {
  int? _uncompressSize;
  int? _crc;
  Completer<int>? _sizeCompleter;
  Completer<int>? _crcCompleter;

  Future<int> get uncompressedSize {
    if (_uncompressSize == null) {
      final c = _sizeCompleter ??= Completer<int>();
      return c.future;
    } else {
      return Future.value(_uncompressSize);
    }
  }

  Future<int> get crc {
    if (_crc == null) {
      final c = _crcCompleter ??= Completer<int>();
      return c.future;
    } else {
      return Future.value(_crc);
    }
  }

  @override
  Stream<List<int>> bind(Stream<List<int>> bytes) {
    // Create a controller for the compressed data stream from the encoder
    final ctrl = StreamController<List<int>>();
    // Set up the ZLibEncoder for chunked conversion
    final encoder = ZLibEncoder(raw: true);
    final sink = encoder.startChunkedConversion(ctrl.sink);
    _pipe(bytes, sink);
    return ctrl.stream;
  }

  Future<void> _pipe(Stream<List<int>> bytes, Sink<List<int>> sink) async {
    int uncompressedSize = 0;
    final c = _Crc32();
    await for (final chunk in bytes) {
      uncompressedSize += chunk.length;
      c.update(chunk);
      sink.add(chunk); // Send chunk to compressor
    }
    final crc = c.value;
    sink.close(); // Signal end of input to compressor
    _uncompressSize = uncompressedSize;
    _crc = crc;
    _sizeCompleter?.complete(uncompressedSize);
    _crcCompleter?.complete(crc);
  }
}

/// An extension that could directly handle file entries by
/// [ZipArchive]
extension ZipEntryItorExt on ZipArchive {
  Stream<List<int>> zip() => ZipEncoder().zip(this);
}

/// A utility class to handle Zipping of file entries.
///
/// This class reads each entry's data, calculates its CRC-32 checksum and
/// sizes, compresses the data (if specified), and then constructs the
/// necessary ZIP headers (Local File Header, Data Descriptor, Central
/// Directory, and End of Central Directory Record) to form a valid ZIP archive.
final class ZipEncoder {
  const ZipEncoder();

  /// Transforms a stream of [ZipFileEntry] objects into a stream of raw bytes
  /// representing a .zip file.
  /// [entries] A stream of [ZipFileEntry] objects to be zipped.
  ///
  /// Returns a [Stream<List<int>>] representing the zipped file content.
  Stream<List<int>> zip(ZipArchive archive) async* {
    final entries = archive.entries;
    // Stores information for each file to construct the Central Directory
    final centralDirectoryRecords = <_CentralDirectoryRecord>[];
    // Tracks the current offset within the output ZIP file bytes
    int currentOffset = 0;

    // Process each ZipFileEntry from the input stream
    for (final entry in entries) {
      final fileName = entry.name;
      final fileNameBytes = utf8.encode(fileName);
      final fileNameLength = fileNameBytes.length;

      final generalPurposeBitFlag = 0x0008;

      // --- Construct Local File Header ---
      final localHeader = _BytesWriter(ByteData(_localFileHeaderBaseSize));

      localHeader.uint32(_localFileHeaderSignature);
      // Version needed to extract (2.0)
      localHeader.uint16(20);
      // General purpose bit flag
      localHeader.uint16(generalPurposeBitFlag);
      // Compression method
      localHeader.uint16(entry.method.method);

      // Convert DateTime to DOS format (FAT timestamp)
      final modified = entry.lastModified ?? DateTime.now();
      final dosTime = (modified.second ~/ 2) +
          (modified.minute << 5) +
          (modified.hour << 11);
      final dosDate = (modified.day) +
          (modified.month << 5) +
          ((modified.year - 1980) << 9);
      localHeader.uint16(dosTime);
      localHeader.uint16(dosDate);

      // Placeholder values (0) for CRC-32, compressed size, uncompressed size,
      // as they will be in the Data Descriptor
      localHeader.uint32(0);
      localHeader.uint32(0);
      localHeader.uint32(0);
      // File name length
      localHeader.uint16(fileNameLength);
      // Extra field length (not used in this simplified version)
      localHeader.uint16(0);

      final localHeaderBuilder = BytesBuilder()
        ..add(localHeader.asUint8List())
        ..add(fileNameBytes);

      final localHeaderSize = localHeaderBuilder.length;
      // Output the Local File Header bytes
      yield localHeaderBuilder.takeBytes();

      final compress = entry.method == ZipMethod.deflated;
      final encoder = _Compressor();
      final dataStream = compress ? entry.data.transform(encoder) : entry.data;

      int compressedSize = 0;
      await for (final chunk in dataStream) {
        compressedSize += chunk.length;
        yield chunk;
      }

      // Update the current offset in the ZIP file
      currentOffset += localHeaderSize + compressedSize;

      final uncompressedSize =
          compress ? await encoder.uncompressedSize : compressedSize;
      final crc = compress ? await encoder.crc : 0;

      // --- Construct Data Descriptor ---
      // This immediately follows the compressed data for files with bit 3 set
      final dataDescriptor =
          _BytesWriter(ByteData(_dataDescriptorWithSignatureSize));
      // Data Descriptor signature
      dataDescriptor.uint32(_dataDescriptorSignature);
      dataDescriptor.uint32(crc); // CRC-32
      // Compressed size
      dataDescriptor.uint32(compressedSize);
      // Uncompressed size
      dataDescriptor.uint32(uncompressedSize);
      // Output the Data Descriptor bytes
      yield dataDescriptor.asUint8List();

      currentOffset += _dataDescriptorWithSignatureSize;

      // Store information needed for the Central Directory Record
      centralDirectoryRecords.add(
        _CentralDirectoryRecord(
          fileName: fileName,
          fileNameLength: fileNameLength,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          crc32: crc,
          compressionMethod: entry.method.method,
          lastModifiedTime: dosTime,
          lastModifiedDate: dosDate,
          // Offset of the Local File Header for this entry
          localHeaderOffset: currentOffset -
              localHeaderSize -
              compressedSize -
              _dataDescriptorWithSignatureSize,
        ),
      );
    }

    // --- Construct Central Directory ---
    final centralDirectoryBuilder = BytesBuilder();
    int centralDirectorySize = 0;
    // Offset of the Central Directory in the ZIP file
    final centralDirectoryOffset = currentOffset;

    // Iterate through all stored records to build Central Directory entries
    for (final record in centralDirectoryRecords) {
      final fileNameBytes = utf8.encode(record.fileName);
      final nameLength = fileNameBytes.length;

      final centralHeader =
          _BytesWriter(ByteData(_centralDirectoryFileHeaderBaseSize));
      centralHeader.uint32(_centralDirectoryFileHeaderSignature);
      centralHeader.uint16(20); // Version made by (2.0)
      // Version needed to extract (2.0)
      centralHeader.uint16(20);
      // General purpose bit flag (bit 3 set)
      centralHeader.uint16(0x0008);
      centralHeader.uint16(record.compressionMethod);
      centralHeader.uint16(record.lastModifiedTime);
      centralHeader.uint16(record.lastModifiedDate);
      centralHeader.uint32(record.crc32);
      centralHeader.uint32(record.compressedSize);
      centralHeader.uint32(record.uncompressedSize);
      centralHeader.uint16(nameLength);
      centralHeader.uint16(0); // Extra field length
      centralHeader.uint16(0); // File comment length
      centralHeader.uint16(0); // Disk number start
      centralHeader.uint16(0); // Internal file attributes
      centralHeader.uint32(0); // External file attributes
      // Relative offset of local header
      centralHeader.uint32(record.localHeaderOffset);

      centralDirectoryBuilder.add(centralHeader.asUint8List());
      centralDirectoryBuilder.add(fileNameBytes);
      centralDirectorySize += _centralDirectoryFileHeaderBaseSize + nameLength;
    }

    // Output the Central Directory bytes
    yield centralDirectoryBuilder.takeBytes();

    currentOffset += centralDirectorySize;

    // --- Construct End of Central Directory Record (EOCD) ---
    final eocd = _BytesWriter(ByteData(_endOfCentralDirectoryBaseSize));
    eocd.uint32(_endOfCentralDirectorySignature);
    // Number of this disk
    eocd.uint16(0);
    // Disk where central directory starts
    eocd.uint16(0);
    // Number of central directory records on this disk
    eocd.uint16(centralDirectoryRecords.length);
    // Total number of central directory records
    eocd.uint16(centralDirectoryRecords.length);
    // Size of central directory
    eocd.uint32(centralDirectorySize);
    // Offset of start of central directory
    eocd.uint32(centralDirectoryOffset);
    // ZIP file comment length (not used)
    eocd.uint16(0);

    yield eocd.asUint8List(); // Output the EOCD bytes
  }
}

final class _BytesWriter extends _BytesWrapper {
  _BytesWriter(super.data) : super._();

  void uint16(int v) {
    _data.setUint16(_position, v, Endian.little);
    _position += 2;
  }

  void uint32(int v) {
    _data.setUint32(_position, v, Endian.little);
    _position += 4;
  }

  Uint8List asUint8List() => _data.buffer.asUint8List();
}
