part of 'zlib.dart';

/// A utility extension method to unzip a zip file as [RandomAccessFile].
extension RamFileExt on RandomAccessFile {
  Stream<ZipFileEntry> unzip() => const ZipDecoder().unzip(this);

  String _readString(int length) {
    if (length > 0) {
      final data = readSync(length);
      return utf8.decode(data);
    }
    return '';
  }

  Stream<List<int>> _readStream(int position, int length) async* {
    const bufLength = 1 << 20;
    final end = position + length;
    var pos = position;
    while (pos + bufLength < end) {
      setPositionSync(pos);
      yield await read(bufLength);
      pos += bufLength;
    }
    final len = end - pos;
    if (len > 0) {
      setPositionSync(pos);
      yield await read(len);
    }
  }
}

/// A utility class to handle unzipping of file entries.
final class ZipDecoder {
  const ZipDecoder();

  /// Decompressing a zip file is totally designed for `RandomAccessFile`,
  /// so `Stream<List<int>>` would have to be save as [RandomAccessFile] first.
  ///
  /// [file] A random access file representing the zipped file content.
  ///
  /// Returns a [Stream<ZipFileEntry>] containing the unzipped file entries.
  Stream<ZipFileEntry> unzip(RandomAccessFile file) async* {
    final r = _findCentralDirectory(file);
    final (centralDirectorySize, centralDirectoryOffset, numberOfEntries) = r;
    // Iterate through each entry in the Central Directory
    int currentCentralDirectoryOffset = centralDirectoryOffset;
    for (int i = 0; i < numberOfEntries; i++) {
      file.setPositionSync(currentCentralDirectoryOffset);
      final headerBytes = file.readSync(_centralDirectoryFileHeaderBaseSize);
      final headerData = _BytesReader(headerBytes);
      final sig = headerData.uint32();
      if (sig != _centralDirectoryFileHeaderSignature) {
        throw FormatException('Invalid Central Directory File Header signature '
            'at offset $currentCentralDirectoryOffset');
      }
      headerData.skip(6);
      final compressionMethod = headerData.uint16();
      final lastModifiedTime = headerData.uint16();
      final lastModifiedDate = headerData.uint16();
      final crc32 = headerData.uint32();
      final compressedSize = headerData.uint32();
      final uncompressedSize = headerData.uint32();
      final fileNameLength = headerData.uint16();
      final extraFieldLength = headerData.uint16();
      final fileCommentLength = headerData.uint16();
      headerData.skip(8);
      final localHeaderOffset = headerData.uint32();

      file.setPositionSync(currentCentralDirectoryOffset + headerData.length);

      final fileName = file._readString(fileNameLength);
      final actualLocalHeaderOffset = localHeaderOffset;
      file.setPositionSync(actualLocalHeaderOffset);

      final localHeaderBytes = file.readSync(_localFileHeaderBaseSize);
      final localHeaderData = _BytesReader(localHeaderBytes);
      final signature = localHeaderData.uint32();
      if (signature != _localFileHeaderSignature) {
        throw FormatException('Invalid Local File Header signature for file'
            ' $fileName at offset $actualLocalHeaderOffset');
      }
      localHeaderData.skip(2); // skip 2 bytes
      final generalPurposeBitFlag = localHeaderData.uint16();
      localHeaderData.skip(18);
      final localFileNameLength = localHeaderData.uint16();
      final localExtraFieldLength = localHeaderData.uint16();

      final dataStartOffset = actualLocalHeaderOffset +
          _localFileHeaderBaseSize +
          localFileNameLength +
          localExtraFieldLength;

      final hasDataDescriptor = (generalPurposeBitFlag & 0x0008) != 0;

      var effectiveCompressedSize = compressedSize;
      var effectiveUncompressedSize = uncompressedSize;
      var effectiveCrc32 = crc32;

      // Calculate the end offset of the compressed data.
      // This will be adjusted if a Data Descriptor is present.
      var dataEndOffset = dataStartOffset + effectiveCompressedSize;
      // If Data Descriptor is present, read its values which supersede
      // the values in the Local File Header (and Central Directory)
      if (hasDataDescriptor) {
        // DD is after compressed data
        final dataDescriptorOffset = dataStartOffset + effectiveCompressedSize;

        // Check for Data Descriptor signature. It's optional per spec,
        // so we try to read it but also handle its absence.
        file.setPositionSync(dataDescriptorOffset);

        final descriptorData =
            _BytesReader(file.readSync(_dataDescriptorWithSignatureSize));
        final sig = descriptorData.uint32();
        if (sig != _dataDescriptorSignature) {
          throw FormatException('Invalid Descriptor Header signature for file '
              '$fileName at offset $dataDescriptorOffset');
        }

        effectiveCrc32 = descriptorData.uint32();
        effectiveCompressedSize = descriptorData.uint32();
        effectiveUncompressedSize = descriptorData.uint32();

        // Re-calculate data end offset with the actual compressed size from DD
        dataEndOffset = dataStartOffset + effectiveCompressedSize;
      }

      final fileDataLen = dataEndOffset - dataStartOffset;
      final compressed = compressionMethod == ZipMethod.deflated.method;
      final fileDataStream = file
          ._readStream(dataStartOffset, fileDataLen)
          .transform(_Decompressor(compressed));

      // Reconstruct DateTime object from DOS date and time fields
      final year = ((lastModifiedDate >> 9) & 0x7F) + 1980;
      final month = (lastModifiedDate >> 5) & 0x0F;
      final day = lastModifiedDate & 0x1F;

      final hour = (lastModifiedTime >> 11) & 0x1F;
      final minute = (lastModifiedTime >> 5) & 0x3F;
      // Seconds are in 2-second intervals
      final second = (lastModifiedTime & 0x1F) * 2;
      final lastModified = DateTime(year, month, day, hour, minute, second);

      // Yield the constructed ZipFileEntry
      yield ZipFileEntry(
        name: fileName,
        data: fileDataStream,
        lastModified: lastModified,
        method: ZipMethod.from(compressionMethod),
        crc32: effectiveCrc32,
        uncompressedSize: effectiveUncompressedSize,
        compressedSize: effectiveCompressedSize,
      );

      // Move to the next Central Directory entry
      currentCentralDirectoryOffset += _centralDirectoryFileHeaderBaseSize +
          fileNameLength +
          extraFieldLength +
          fileCommentLength;
    }
  }

  /// Find the End of Central Directory Record (EOCD) to locate the Central Directory.
  /// We search backward from the end of the file.
  /// The maximum possible comment length in EOCD is 65535 bytes.
  /// So, we search from the end of the file minus EOCD base size minus max comment length.
  /// For practical purposes and assuming no very large comments, a shorter backward search might suffice,
  /// but this range ensures robust EOCD discovery.
  (int, int, int) _findCentralDirectory(RandomAccessFile file) {
    final fileSize = file.lengthSync();
    final pos = m.max(0, fileSize - _endOfCentralDirectoryBaseSize - 65535);
    file.setPositionSync(pos);
    final bytes = file.readSync(fileSize - pos);
    final byteData = bytes.buffer.asByteData();

    for (var i = byteData.lengthInBytes - 4; i >= 0; i--) {
      final signature = byteData.getUint32(i, Endian.little);
      if (signature == _endOfCentralDirectorySignature) {
        final reader = _BytesReader._(byteData.buffer.asByteData(i));
        reader.skip(10);
        final count = reader.uint16();
        final size = reader.uint32();
        final offset = reader.uint32();
        return (size, offset, count);
      }
    }
    throw Exception('Invalid ZIP file: End of central directory not found');
  }
}

final class _Decompressor extends StreamTransformerBase<List<int>, List<int>> {
  final bool compressed;

  const _Decompressor(this.compressed);

  @override
  Stream<List<int>> bind(Stream<List<int>> bytes) {
    if (!compressed) {
      return bytes;
    }
    final decoder = ZLibDecoder(raw: compressed);
    final ctrl = StreamController<List<int>>();
    final sink = decoder.startChunkedConversion(ctrl.sink);
    _pipe(bytes, sink);
    return ctrl.stream;
  }

  Future<void> _pipe(Stream<List<int>> bytes, Sink<List<int>> sink) async {
    await for (final chunk in bytes) {
      sink.add(chunk); // Send chunk to compressor
    }
    sink.close();
  }
}

final class _BytesReader extends _BytesWrapper {
  _BytesReader._(super.data) : super._();
  _BytesReader(Uint8List data) : super._(data.buffer.asByteData());

  int uint16() {
    final v = _data.getUint16(_position, Endian.little);
    _position += 2;
    return v;
  }

  int uint32() {
    final v = _data.getUint32(_position, Endian.little);
    _position += 4;
    return v;
  }

  List<int> bytes(int length) {
    final v = _data.buffer.asUint8List(_position, length);
    _position += length;
    return v;
  }

  void skip(int size) {
    _position += size;
  }
}
