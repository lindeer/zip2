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
    int crc = 0xFFFFFFFF; // Initialize CRC-32 calculation
    await for (final chunk in bytes) {
      uncompressedSize += chunk.length;
      crc = _Crc32.update(crc, chunk);
      sink.add(chunk); // Send chunk to compressor
    }
    crc ^= 0xFFFFFFFF; // Finalize CRC-32 value
    sink.close(); // Signal end of input to compressor
    _uncompressSize = uncompressedSize;
    _crc = crc;
    _sizeCompleter?.complete(uncompressedSize);
    _crcCompleter?.complete(crc);
  }
}

/// A utility class to handle Zipping of file entries.
///
/// This transformer reads each entry's data, calculates its CRC-32 checksum and
/// sizes, compresses the data (if specified), and then constructs the
/// necessary ZIP headers (Local File Header, Data Descriptor, Central
/// Directory, and End of Central Directory Record) to form a valid ZIP archive.
final class ZipEncoder extends StreamTransformerBase<ZipFileEntry, List<int>> {
  const ZipEncoder();

  /// Transforms a stream of [ZipFileEntry] objects into a stream of raw bytes
  /// representing a .zip file.
  /// [entries] A stream of [ZipFileEntry] objects to be zipped.
  ///
  /// Returns a [Stream<List<int>>] representing the zipped file content.
  @override
  Stream<List<int>> bind(Stream<ZipFileEntry> entries) async* {
    // Stores information for each file to construct the Central Directory
    final centralDirectoryRecords = <_CentralDirectoryRecord>[];
    // Tracks the current offset within the output ZIP file bytes
    int currentOffset = 0;

    // Process each ZipFileEntry from the input stream
    await for (final entry in entries) {
      final fileName = entry.name;
      final fileNameBytes = utf8.encode(fileName);
      final fileNameLength = fileNameBytes.length;

      final generalPurposeBitFlag = 0x0008;

      // --- Construct Local File Header ---
      final localHeader = ByteData(_localFileHeaderBaseSize);

      localHeader.setUint32(0, _localFileHeaderSignature, Endian.little);
      // Version needed to extract (2.0)
      localHeader.setUint16(4, 20, Endian.little);
      // General purpose bit flag
      localHeader.setUint16(6, generalPurposeBitFlag, Endian.little);
      // Compression method
      localHeader.setUint16(8, entry.method.method, Endian.little);

      // Convert DateTime to DOS format (FAT timestamp)
      final modified = entry.lastModified ?? DateTime.now();
      final dosTime = (modified.second ~/ 2) +
          (modified.minute << 5) +
          (modified.hour << 11);
      final dosDate = (modified.day) +
          (modified.month << 5) +
          ((modified.year - 1980) << 9);
      localHeader.setUint16(10, dosTime, Endian.little);
      localHeader.setUint16(12, dosDate, Endian.little);

      // Placeholder values (0) for CRC-32, compressed size, uncompressed size,
      // as they will be in the Data Descriptor
      localHeader.setUint32(14, 0, Endian.little);
      localHeader.setUint32(18, 0, Endian.little);
      localHeader.setUint32(22, 0, Endian.little);
      // File name length
      localHeader.setUint16(26, fileNameLength, Endian.little);
      // Extra field length (not used in this simplified version)
      localHeader.setUint16(28, 0, Endian.little);

      final localHeaderBuilder = BytesBuilder()
        ..add(localHeader.buffer.asUint8List())
        ..add(fileNameBytes);

      final localHeaderSize = localHeaderBuilder.length;
      // Output the Local File Header bytes
      yield localHeaderBuilder.takeBytes();

      final encoder = _Compressor();
      final dataStream = entry.data.transform(encoder);

      int compressedSize = 0;
      await for (final chunk in dataStream) {
        compressedSize += chunk.length;
        yield chunk;
      }

      // Update the current offset in the ZIP file
      currentOffset += localHeaderSize + compressedSize;

      final uncompressedSize = await encoder.uncompressedSize;
      final crc = await encoder.crc;

      // --- Construct Data Descriptor ---
      // This immediately follows the compressed data for files with bit 3 set
      final dataDescriptor = ByteData(_dataDescriptorWithSignatureSize);
      // Data Descriptor signature
      dataDescriptor.setUint32(0, _dataDescriptorSignature, Endian.little);
      dataDescriptor.setUint32(4, crc, Endian.little); // CRC-32
      // Compressed size
      dataDescriptor.setUint32(8, compressedSize, Endian.little);
      // Uncompressed size
      dataDescriptor.setUint32(12, uncompressedSize, Endian.little);
      // Output the Data Descriptor bytes
      yield dataDescriptor.buffer.asUint8List();

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

      final centralHeader = ByteData(_centralDirectoryFileHeaderBaseSize);
      centralHeader.setUint32(0, _centralDirectoryFileHeaderSignature, Endian.little);
      centralHeader.setUint16(4, 20, Endian.little); // Version made by (2.0)
      // Version needed to extract (2.0)
      centralHeader.setUint16(6, 20, Endian.little);
      // General purpose bit flag (bit 3 set)
      centralHeader.setUint16(8, 0x0008, Endian.little);
      centralHeader.setUint16(10, record.compressionMethod, Endian.little);
      centralHeader.setUint16(12, record.lastModifiedTime, Endian.little);
      centralHeader.setUint16(14, record.lastModifiedDate, Endian.little);
      centralHeader.setUint32(16, record.crc32, Endian.little);
      centralHeader.setUint32(20, record.compressedSize, Endian.little);
      centralHeader.setUint32(24, record.uncompressedSize, Endian.little);
      centralHeader.setUint16(28, nameLength, Endian.little);
      centralHeader.setUint16(30, 0, Endian.little); // Extra field length
      centralHeader.setUint16(32, 0, Endian.little); // File comment length
      centralHeader.setUint16(34, 0, Endian.little); // Disk number start
      centralHeader.setUint16(36, 0, Endian.little); // Internal file attributes
      centralHeader.setUint32(38, 0, Endian.little); // External file attributes
      // Relative offset of local header
      centralHeader.setUint32(42, record.localHeaderOffset, Endian.little);

      centralDirectoryBuilder.add(centralHeader.buffer.asUint8List());
      centralDirectoryBuilder.add(fileNameBytes);
      centralDirectorySize += _centralDirectoryFileHeaderBaseSize + nameLength;
    }

    // Output the Central Directory bytes
    yield centralDirectoryBuilder.takeBytes();

    currentOffset += centralDirectorySize;

    // --- Construct End of Central Directory Record (EOCD) ---
    final eocd = ByteData(_endOfCentralDirectoryBaseSize);
    eocd.setUint32(0, _endOfCentralDirectorySignature, Endian.little);
    // Number of this disk
    eocd.setUint16(4, 0, Endian.little);
    // Disk where central directory starts
    eocd.setUint16(6, 0, Endian.little);
    // Number of central directory records on this disk
    eocd.setUint16(8, centralDirectoryRecords.length, Endian.little);
    // Total number of central directory records
    eocd.setUint16(10, centralDirectoryRecords.length, Endian.little);
    // Size of central directory
    eocd.setUint32(12, centralDirectorySize, Endian.little);
    // Offset of start of central directory
    eocd.setUint32(16, centralDirectoryOffset, Endian.little);
    // ZIP file comment length (not used)
    eocd.setUint16(20, 0, Endian.little);

    yield eocd.buffer.asUint8List(); // Output the EOCD bytes
  }
}
