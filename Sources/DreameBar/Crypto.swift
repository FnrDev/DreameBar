import Foundation
import CommonCrypto
import CryptoKit
import zlib

enum Crypto {
    static func md5Hex(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func aesECBEncrypt(_ data: Data, key: Data) -> Data? {
        aes(kCCEncrypt, data, key: key, iv: nil, options: CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding))
    }

    /// AES-CBC without unpadding: the map payload is a zlib stream, and inflate stops at its end.
    static func aesCBCDecrypt(_ data: Data, key: Data, iv: Data) -> Data? {
        aes(kCCDecrypt, data, key: key, iv: iv, options: 0)
    }

    private static func aes(_ op: Int, _ data: Data, key: Data, iv: Data?, options: CCOptions) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { inPtr in
                key.withUnsafeBytes { keyPtr in
                    (iv ?? Data()).withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(op), CCAlgorithm(kCCAlgorithmAES), options,
                                keyPtr.baseAddress, key.count,
                                iv == nil ? nil : ivPtr.baseAddress,
                                inPtr.baseAddress, data.count,
                                outPtr.baseAddress, outCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    /// Python `zlib.decompress` (zlib header, trailing bytes ignored).
    static func zlibInflate(_ data: Data) -> Data? {
        var stream = z_stream()
        guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return nil }
        defer { inflateEnd(&stream) }
        var input = [UInt8](data)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        let result: Int32 = input.withUnsafeMutableBufferPointer { inBuf in
            stream.next_in = inBuf.baseAddress
            stream.avail_in = uInt(inBuf.count)
            var rc: Int32 = Z_OK
            repeat {
                rc = chunk.withUnsafeMutableBufferPointer { outBuf in
                    stream.next_out = outBuf.baseAddress
                    stream.avail_out = uInt(outBuf.count)
                    let r = inflate(&stream, Z_NO_FLUSH)
                    output.append(outBuf.baseAddress!, count: outBuf.count - Int(stream.avail_out))
                    return r
                }
            } while rc == Z_OK
            return rc
        }
        return result == Z_STREAM_END ? output : nil
    }

    static func base64Decode(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "_", with: "/").replacingOccurrences(of: "-", with: "+")
            .filter { !$0.isWhitespace }
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}
