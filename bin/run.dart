import 'dart:async';
import 'dart:convert'; // For utf8 encoding of file names
import 'dart:io'; // For ZLibEncoder, ZLibDecoder
import 'dart:typed_data';

/// Represents an entry within a Zip file.
class ZipFileEntry {
  /// The name of the file within the Zip archive.
  final String name;

  /// The stream of raw bytes for the file's data.
  final Stream<List<int>> data;

  /// The last modified date and time of the file.
  ///
  /// This field is optional and defaults to the current time if not provided
  /// during zipping. During unzipping, it will be populated if available
  /// in the ZIP archive.
  final DateTime? lastModified;

  /// The compression method used for the file.
  ///
  /// Common values include:
  /// - `0`: STORED (no compression)
  /// - `8`: DEFLATED (ZLib compression)
  ///
  /// Defaults to `8` (DEFLATED) when zipping.
  final int compressionMethod;

  /// The CRC-32 checksum of the uncompressed data.
  ///
  /// This is typically calculated during the zipping process and used
  /// for verification during unzipping.
  final int? crc32;

  /// The uncompressed size of the data in bytes.
  ///
  /// This is typically calculated during the zipping process.
  final int? uncompressedSize;

  /// The compressed size of the data in bytes.
  ///
  /// This is typically calculated during the zipping process.
  final int? compressedSize;

  ZipFileEntry({
    required this.name,
    required this.data,
    this.lastModified,
    this.compressionMethod = 8, // Default to DEFLATED compression
    this.crc32,
    this.uncompressedSize,
    this.compressedSize,
  });
}

/// Calculates the CRC-32 checksum of a list of bytes.
///
/// This implementation uses the polynomial 0xEDB88320, which is the reversed
/// form of the standard CRC-32 polynomial 0x04C11DB7.
///
/// Returns the CRC-32 checksum as an unsigned 32-bit integer.
class Crc32 {
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
  static int calculate(List<int> bytes) {
    return update(0xFFFFFFFF, bytes);
  }
}

// Constants for ZIP file format signatures and offsets
const int _localFileHeaderSignature = 0x04034b50;
const int _centralDirectoryFileHeaderSignature = 0x02014b50;
const int _endOfCentralDirectorySignature = 0x06054b50;
const int _dataDescriptorSignature = 0x08074b50; // Optional, but good to know

// Fixed sizes of headers
const int _localFileHeaderBaseSize = 30; // Without filename and extra field
const int _centralDirectoryFileHeaderBaseSize = 46; // Without filename, extra field, and comment
const int _endOfCentralDirectoryBaseSize = 22; // Without comment
const int _dataDescriptorSize = 12; // CRC-32, compressed size, uncompressed size (no signature)
const int _dataDescriptorWithSignatureSize = 16; // With signature

/// A utility class to handle Zipping and Unzipping of file entries.
class ZipPackage {
  /// Transforms a stream of [ZipFileEntry] objects into a stream of raw bytes
  /// representing a .zip file.
  ///
  /// This method reads each entry's data, calculates its CRC-32 checksum and
  /// sizes, compresses the data (if specified), and then constructs the
  /// necessary ZIP headers (Local File Header, Data Descriptor, Central
  /// Directory, and End of Central Directory Record) to form a valid ZIP archive.
  ///
  /// [entries] A stream of [ZipFileEntry] objects to be zipped.
  ///
  /// Returns a [Stream<List<int>>] representing the zipped file content.
  Stream<List<int>> zip(Stream<ZipFileEntry> entries) async* {
    // Stores information for each file to construct the Central Directory
    final List<_CentralDirectoryRecord> centralDirectoryRecords = [];
    // Tracks the current offset within the output ZIP file bytes
    int currentOffset = 0;

    // Process each ZipFileEntry from the input stream
    await for (final entry in entries) {
      final String fileName = entry.name;
      final List<int> fileNameBytes = utf8.encode(fileName);
      final int fileNameLength = fileNameBytes.length;

      int uncompressedSize = 0;
      int crc = 0xFFFFFFFF; // Initialize CRC-32 calculation
      final BytesBuilder compressedBytesBuilder = BytesBuilder(); // To collect compressed data

      // Create a controller for the compressed data stream from the encoder
      final StreamController<List<int>> compressedStreamController = StreamController<List<int>>();

      // Set up the ZLibEncoder for chunked conversion
      final ZLibEncoder encoder = ZLibEncoder(raw: true);
      final ByteConversionSink conversionSink = encoder.startChunkedConversion(compressedStreamController.sink);

      // Pipe the uncompressed data through the CRC calculator and into the compressor
      await for (final dataChunk in entry.data) {
        uncompressedSize += dataChunk.length;
        crc = Crc32.update(crc, dataChunk);
        conversionSink.add(dataChunk); // Send chunk to compressor
      }
      crc ^= 0xFFFFFFFF; // Finalize CRC-32 value
      conversionSink.close(); // Signal end of input to compressor

      // Collect all compressed chunks into a single list
      await for (final compressedChunk in compressedStreamController.stream) {
        compressedBytesBuilder.add(compressedChunk);
      }
      final Uint8List compressedData = compressedBytesBuilder.takeBytes();
      final int compressedSize = compressedData.length;

      // General purpose bit flag: 0x0008 (bit 3 set) indicates that
      // the CRC-32, compressed size, and uncompressed size will be written
      // in a Data Descriptor after the compressed data, instead of in the
      // Local File Header.
      final int generalPurposeBitFlag = 0x0008;

      // --- Construct Local File Header ---
      final BytesBuilder localHeaderBuilder = BytesBuilder();
      final ByteData localHeader = ByteData(_localFileHeaderBaseSize);

      localHeader.setUint32(0, _localFileHeaderSignature, Endian.little);
      localHeader.setUint16(4, 20, Endian.little); // Version needed to extract (2.0)
      localHeader.setUint16(6, generalPurposeBitFlag, Endian.little); // General purpose bit flag
      localHeader.setUint16(8, entry.compressionMethod, Endian.little); // Compression method

      // Convert DateTime to DOS format (FAT timestamp)
      final DateTime modified = entry.lastModified ?? DateTime.now();
      final int dosTime = (modified.second ~/ 2) +
          (modified.minute << 5) +
          (modified.hour << 11);
      final int dosDate = (modified.day) +
          (modified.month << 5) +
          ((modified.year - 1980) << 9);
      localHeader.setUint16(10, dosTime, Endian.little);
      localHeader.setUint16(12, dosDate, Endian.little);

      // Placeholder values (0) for CRC-32, compressed size, uncompressed size,
      // as they will be in the Data Descriptor
      localHeader.setUint32(14, 0, Endian.little);
      localHeader.setUint32(18, 0, Endian.little);
      localHeader.setUint32(22, 0, Endian.little);
      localHeader.setUint16(26, fileNameLength, Endian.little); // File name length
      localHeader.setUint16(28, 0, Endian.little); // Extra field length (not used in this simplified version)

      localHeaderBuilder.add(localHeader.buffer.asUint8List());
      localHeaderBuilder.add(fileNameBytes);

      final int localHeaderSize = localHeaderBuilder.length;
      yield localHeaderBuilder.takeBytes(); // Output the Local File Header bytes
      yield compressedData; // Output the compressed file data bytes

      // Update the current offset in the ZIP file
      currentOffset += localHeaderSize + compressedData.length;

      // --- Construct Data Descriptor ---
      // This immediately follows the compressed data for files with bit 3 set
      final ByteData dataDescriptor = ByteData(_dataDescriptorWithSignatureSize);
      dataDescriptor.setUint32(0, _dataDescriptorSignature, Endian.little); // Data Descriptor signature
      dataDescriptor.setUint32(4, crc, Endian.little); // CRC-32
      dataDescriptor.setUint32(8, compressedSize, Endian.little); // Compressed size
      dataDescriptor.setUint32(12, uncompressedSize, Endian.little); // Uncompressed size
      yield dataDescriptor.buffer.asUint8List(); // Output the Data Descriptor bytes

      currentOffset += _dataDescriptorWithSignatureSize;

      // Store information needed for the Central Directory Record
      centralDirectoryRecords.add(
        _CentralDirectoryRecord(
          fileName: fileName,
          fileNameLength: fileNameLength,
          compressedSize: compressedSize,
          uncompressedSize: uncompressedSize,
          crc32: crc,
          compressionMethod: entry.compressionMethod,
          lastModifiedTime: dosTime,
          lastModifiedDate: dosDate,
          // Offset of the Local File Header for this entry
          localHeaderOffset: currentOffset - localHeaderSize - compressedData.length - _dataDescriptorWithSignatureSize,
        ),
      );
    }

    // --- Construct Central Directory ---
    final BytesBuilder centralDirectoryBuilder = BytesBuilder();
    int centralDirectorySize = 0;
    final int centralDirectoryOffset = currentOffset; // Offset of the Central Directory in the ZIP file

    // Iterate through all stored records to build Central Directory entries
    for (final record in centralDirectoryRecords) {
      final List<int> fileNameBytes = utf8.encode(record.fileName);
      final int fileNameLength = fileNameBytes.length;

      final ByteData centralHeader = ByteData(_centralDirectoryFileHeaderBaseSize);
      centralHeader.setUint32(0, _centralDirectoryFileHeaderSignature, Endian.little);
      centralHeader.setUint16(4, 20, Endian.little); // Version made by (2.0)
      centralHeader.setUint16(6, 20, Endian.little); // Version needed to extract (2.0)
      centralHeader.setUint16(8, 0x0008, Endian.little); // General purpose bit flag (bit 3 set)
      centralHeader.setUint16(10, record.compressionMethod, Endian.little);
      centralHeader.setUint16(12, record.lastModifiedTime, Endian.little);
      centralHeader.setUint16(14, record.lastModifiedDate, Endian.little);
      centralHeader.setUint32(16, record.crc32, Endian.little);
      centralHeader.setUint32(20, record.compressedSize, Endian.little);
      centralHeader.setUint32(24, record.uncompressedSize, Endian.little);
      centralHeader.setUint16(28, fileNameLength, Endian.little);
      centralHeader.setUint16(30, 0, Endian.little); // Extra field length
      centralHeader.setUint16(32, 0, Endian.little); // File comment length
      centralHeader.setUint16(34, 0, Endian.little); // Disk number start
      centralHeader.setUint16(36, 0, Endian.little); // Internal file attributes
      centralHeader.setUint32(38, 0, Endian.little); // External file attributes
      centralHeader.setUint32(42, record.localHeaderOffset, Endian.little); // Relative offset of local header

      centralDirectoryBuilder.add(centralHeader.buffer.asUint8List());
      centralDirectoryBuilder.add(fileNameBytes);
      centralDirectorySize += (_centralDirectoryFileHeaderBaseSize + fileNameLength);
    }

    yield centralDirectoryBuilder.takeBytes(); // Output the Central Directory bytes

    currentOffset += centralDirectorySize;

    // --- Construct End of Central Directory Record (EOCD) ---
    final ByteData eocd = ByteData(_endOfCentralDirectoryBaseSize);
    eocd.setUint32(0, _endOfCentralDirectorySignature, Endian.little);
    eocd.setUint16(4, 0, Endian.little); // Number of this disk
    eocd.setUint16(6, 0, Endian.little); // Disk where central directory starts
    eocd.setUint16(8, centralDirectoryRecords.length, Endian.little); // Number of central directory records on this disk
    eocd.setUint16(10, centralDirectoryRecords.length, Endian.little); // Total number of central directory records
    eocd.setUint32(12, centralDirectorySize, Endian.little); // Size of central directory
    eocd.setUint32(16, centralDirectoryOffset, Endian.little); // Offset of start of central directory
    eocd.setUint16(20, 0, Endian.little); // ZIP file comment length (not used)

    yield eocd.buffer.asUint8List(); // Output the EOCD bytes
  }

  /// Transforms a stream of raw bytes representing a .zip file into a stream
  /// of [ZipFileEntry] objects.
  ///
  /// This method reads the entire ZIP file into memory for parsing. It then
  /// locates the Central Directory to find all file entries, reads their
  /// corresponding Local File Headers and extracts the compressed data.
  /// The data is then decompressed (if necessary) and emitted as a [ZipFileEntry].
  ///
  /// [zipBytes] A stream of raw bytes representing the zipped file content.
  ///
  /// Returns a [Stream<ZipFileEntry>] containing the unzipped file entries.
  Stream<ZipFileEntry> unzip(Stream<List<int>> zipBytes) async* {
    final BytesBuilder allBytesBuilder = BytesBuilder();
    // Read the entire ZIP file stream into a single byte list for easier parsing.
    await for (final chunk in zipBytes) {
      allBytesBuilder.add(chunk);
    }
    final Uint8List fullZipBytes = allBytesBuilder.takeBytes();
    final ByteData byteData = fullZipBytes.buffer.asByteData();

    // Find the End of Central Directory Record (EOCD) to locate the Central Directory.
    // We search backward from the end of the file.
    int eocdOffset = -1;
    // The maximum possible comment length in EOCD is 65535 bytes.
    // So, we search from the end of the file minus EOCD base size minus max comment length.
    // For practical purposes and assuming no very large comments, a shorter backward search might suffice,
    // but this range ensures robust EOCD discovery.
    final int searchStart = fullZipBytes.length - _endOfCentralDirectoryBaseSize - 65535;
    for (int i = fullZipBytes.length - _endOfCentralDirectoryBaseSize; i >= searchStart && i >= 0; i--) {
      try {
        if (byteData.getUint32(i, Endian.little) == _endOfCentralDirectorySignature) {
          eocdOffset = i;
          break;
        }
      } catch (e) {
        // Catch RangeError if we try to read past the beginning of the buffer
        continue;
      }
    }

    if (eocdOffset == -1) {
      throw FormatException('End of Central Directory Record not found.');
    }

    // Extract central directory information from EOCD
    final int centralDirectorySize = byteData.getUint32(eocdOffset + 12, Endian.little);
    final int centralDirectoryOffset = byteData.getUint32(eocdOffset + 16, Endian.little);
    final int numberOfEntries = byteData.getUint16(eocdOffset + 10, Endian.little);

    // Iterate through each entry in the Central Directory
    int currentCentralDirectoryOffset = centralDirectoryOffset;
    for (int i = 0; i < numberOfEntries; i++) {
      if (byteData.getUint32(currentCentralDirectoryOffset, Endian.little) != _centralDirectoryFileHeaderSignature) {
        throw FormatException('Invalid Central Directory File Header signature at offset $currentCentralDirectoryOffset');
      }

      // Read common fields from Central Directory File Header
      final int compressionMethod = byteData.getUint16(currentCentralDirectoryOffset + 10, Endian.little);
      final int lastModifiedTime = byteData.getUint16(currentCentralDirectoryOffset + 12, Endian.little);
      final int lastModifiedDate = byteData.getUint16(currentCentralDirectoryOffset + 14, Endian.little);
      final int crc32 = byteData.getUint32(currentCentralDirectoryOffset + 16, Endian.little);
      final int compressedSize = byteData.getUint32(currentCentralDirectoryOffset + 20, Endian.little);
      final int uncompressedSize = byteData.getUint32(currentCentralDirectoryOffset + 24, Endian.little);
      final int fileNameLength = byteData.getUint16(currentCentralDirectoryOffset + 28, Endian.little);
      final int extraFieldLength = byteData.getUint16(currentCentralDirectoryOffset + 30, Endian.little);
      final int fileCommentLength = byteData.getUint16(currentCentralDirectoryOffset + 32, Endian.little);
      final int localHeaderOffset = byteData.getUint32(currentCentralDirectoryOffset + 42, Endian.little);

      // Extract file name
      final List<int> fileNameBytes = fullZipBytes.sublist(
        currentCentralDirectoryOffset + _centralDirectoryFileHeaderBaseSize,
        currentCentralDirectoryOffset + _centralDirectoryFileHeaderBaseSize + fileNameLength,
      );
      final String fileName = utf8.decode(fileNameBytes);

      // Validate Local File Header signature at its offset
      final int actualLocalHeaderOffset = localHeaderOffset;
      if (byteData.getUint32(actualLocalHeaderOffset, Endian.little) != _localFileHeaderSignature) {
        throw FormatException('Invalid Local File Header signature for file $fileName at offset $actualLocalHeaderOffset');
      }

      // Read lengths from Local File Header to calculate data start offset
      final int localFileNameLength = byteData.getUint16(actualLocalHeaderOffset + 26, Endian.little);
      final int localExtraFieldLength = byteData.getUint16(actualLocalHeaderOffset + 28, Endian.little);
      final int dataStartOffset = actualLocalHeaderOffset + _localFileHeaderBaseSize + localFileNameLength + localExtraFieldLength;

      // Determine if a Data Descriptor is present (bit 3 of general purpose bit flag)
      final int generalPurposeBitFlag = byteData.getUint16(actualLocalHeaderOffset + 6, Endian.little);
      final bool hasDataDescriptor = (generalPurposeBitFlag & 0x0008) != 0;

      // Use sizes and CRC from Central Directory unless Data Descriptor overrides
      int effectiveCompressedSize = compressedSize;
      int effectiveUncompressedSize = uncompressedSize;
      int effectiveCrc32 = crc32;

      // Calculate the end offset of the compressed data.
      // This will be adjusted if a Data Descriptor is present.
      int dataEndOffset = dataStartOffset + effectiveCompressedSize;

      // If Data Descriptor is present, read its values which supersede
      // the values in the Local File Header (and Central Directory)
      if (hasDataDescriptor) {
        final int dataDescriptorOffset = dataStartOffset + effectiveCompressedSize; // DD is after compressed data

        // Check for Data Descriptor signature. It's optional per spec,
        // so we try to read it but also handle its absence.
        int ddStartReadOffset = dataDescriptorOffset;
        if (byteData.getUint32(dataDescriptorOffset, Endian.little) == _dataDescriptorSignature) {
          ddStartReadOffset += 4; // Skip signature if it's present
        }

        effectiveCrc32 = byteData.getUint32(ddStartReadOffset, Endian.little);
        effectiveCompressedSize = byteData.getUint32(ddStartReadOffset + 4, Endian.little);
        effectiveUncompressedSize = byteData.getUint32(ddStartReadOffset + 8, Endian.little);

        // Re-calculate data end offset with the actual compressed size from DD
        dataEndOffset = dataStartOffset + effectiveCompressedSize;
      }

      // Extract the raw compressed data bytes
      final List<int> rawCompressedData = fullZipBytes.sublist(dataStartOffset, dataEndOffset);

      Stream<List<int>> fileDataStream;
      if (compressionMethod == 8) {
        // DEFLATED: Decompress using ZLibDecoder in raw mode
        final ZLibDecoder decoder = ZLibDecoder(raw: true);
        fileDataStream = Stream.fromIterable([decoder.convert(rawCompressedData)]);
      } else if (compressionMethod == 0) {
        // STORED: No decompression needed, use raw data directly
        fileDataStream = Stream.fromIterable([rawCompressedData]);
      } else {
        throw UnsupportedError('Unsupported compression method: $compressionMethod for file $fileName');
      }

      // Reconstruct DateTime object from DOS date and time fields
      final int year = ((lastModifiedDate >> 9) & 0x7F) + 1980;
      final int month = (lastModifiedDate >> 5) & 0x0F;
      final int day = lastModifiedDate & 0x1F;

      final int hour = (lastModifiedTime >> 11) & 0x1F;
      final int minute = (lastModifiedTime >> 5) & 0x3F;
      final int second = (lastModifiedTime & 0x1F) * 2; // Seconds are in 2-second intervals

      final DateTime? lastModified = (year >= 1980 && month >= 1 && month <= 12 && day >= 1 && day <= 31)
          ? DateTime(year, month, day, hour, minute, second)
          : null;


      // Yield the constructed ZipFileEntry
      yield ZipFileEntry(
        name: fileName,
        data: fileDataStream,
        lastModified: lastModified,
        compressionMethod: compressionMethod,
        crc32: effectiveCrc32,
        uncompressedSize: effectiveUncompressedSize,
        compressedSize: effectiveCompressedSize,
      );

      // Move to the next Central Directory entry
      currentCentralDirectoryOffset += _centralDirectoryFileHeaderBaseSize + fileNameLength + extraFieldLength + fileCommentLength;
    }
  }
}

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
