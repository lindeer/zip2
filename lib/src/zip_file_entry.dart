library;

/// The compression method
enum ZipMethod {
  stored(0),
  deflated(8);

  const ZipMethod(this.method);
  final int method;

  static ZipMethod from(int method) {
    return method == ZipMethod.stored.method
        ? ZipMethod.stored
        : ZipMethod.deflated;
  }
}

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
  final ZipMethod method;

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
    this.method = ZipMethod.deflated, // Default to DEFLATED compression
    this.crc32,
    this.uncompressedSize,
    this.compressedSize,
  });

  @override
  String toString() => "ZipFileEntry('$name')";
}
