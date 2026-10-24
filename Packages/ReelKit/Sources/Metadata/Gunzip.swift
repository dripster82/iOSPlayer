import Foundation

/// Minimal gzip reader for AniDB's titles dump. Apple platforms only: it strips the gzip header and
/// hands the raw DEFLATE stream to Foundation's zlib decompressor.
enum Gunzip {
    enum GunzipError: Error { case notGzip, unsupportedPlatform, corrupt }

    static func decompress(_ data: Data) throws -> Data {
        guard data.count > 18, data[data.startIndex] == 0x1f, data[data.startIndex + 1] == 0x8b else { throw GunzipError.notGzip }
        let bytes = [UInt8](data)
        let flags = bytes[3]
        var offset = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard bytes.count > offset + 2 else { throw GunzipError.corrupt }
            let extraLength = Int(bytes[offset]) | (Int(bytes[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 { offset = skipCString(bytes, from: offset) }   // FNAME
        if flags & 0x10 != 0 { offset = skipCString(bytes, from: offset) }   // FCOMMENT
        if flags & 0x02 != 0 { offset += 2 }                                 // FHCRC
        guard bytes.count > offset + 8 else { throw GunzipError.corrupt }
        let deflate = Data(bytes[offset..<(bytes.count - 8)])
        #if canImport(Darwin)
        do { return try (deflate as NSData).decompressed(using: .zlib) as Data }
        catch { throw GunzipError.corrupt }
        #else
        throw GunzipError.unsupportedPlatform
        #endif
    }

    private static func skipCString(_ bytes: [UInt8], from start: Int) -> Int {
        var i = start
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        return i + 1
    }
}
