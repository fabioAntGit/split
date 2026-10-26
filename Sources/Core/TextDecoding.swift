import Foundation

/// Text from older apps is often not UTF-8: Windows and classic Mac OS each had their own
/// single-byte encoding, and some Windows tools write UTF-16 without a byte-order mark.
/// Everything is read into a Swift string, so every result is written back out as UTF-8.
enum TextDecoding {
    struct Decoded {
        let text: String
        let encoding: String.Encoding
    }

    static func decode(_ data: Data) -> Decoded {
        if let marked = byteOrderMark(data) { return marked }
        // Real text never holds NUL bytes, while UTF-16 of plain Latin text is half zeros
        // (and would otherwise pass as UTF-8).
        if data.contains(0), let wide = unmarkedUTF16(data) { return wide }
        if let text = String(data: data, encoding: .utf8) { return Decoded(text: text, encoding: .utf8) }
        return singleByte(data)
    }

    /// The text as UTF-8 bytes, for readers that only take UTF-8 (JSON, ffmpeg's subtitles).
    static func utf8(_ data: Data) -> (data: Data, wasUTF8: Bool) {
        let decoded = decode(data)
        return decoded.encoding == .utf8 ? (data, true) : (Data(decoded.text.utf8), false)
    }

    private static func byteOrderMark(_ data: Data) -> Decoded? {
        let bytes = [UInt8](data.prefix(4))
        let marks: [([UInt8], String.Encoding)] = [
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian), ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xFF, 0xFE], .utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian),
        ]
        for (mark, encoding) in marks where bytes.starts(with: mark) {
            guard let text = String(data: data.dropFirst(mark.count), encoding: encoding) else { return nil }
            return Decoded(text: text, encoding: encoding)
        }
        return nil
    }

    private static func unmarkedUTF16(_ data: Data) -> Decoded? {
        guard data.count >= 2, data.count % 2 == 0 else { return nil }
        let bytes = [UInt8](data)
        var zeroEven = 0
        var zeroOdd = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            if index % 2 == 0 { zeroEven += 1 } else { zeroOdd += 1 }
        }
        let half = bytes.count / 2
        let encoding: String.Encoding
        if zeroOdd * 10 >= half * 3 && zeroEven * 10 < half { encoding = .utf16LittleEndian }
        else if zeroEven * 10 >= half * 3 && zeroOdd * 10 < half { encoding = .utf16BigEndian }
        else { return nil }
        return String(data: data, encoding: encoding).map { Decoded(text: $0, encoding: encoding) }
    }

    /// Windows-1252 or Mac Roman. Both decode almost any bytes, so the one that turns more of
    /// the non-ASCII bytes into lowercase letters (é, ç, ã…) wins; ties go to Windows, by far
    /// the more common of the two today.
    private static func singleByte(_ data: Data) -> Decoded {
        let windows = String(data: data, encoding: .windowsCP1252)
        let mac = String(data: data, encoding: .macOSRoman) ?? String(decoding: data, as: UTF8.self)
        guard let windows else { return Decoded(text: mac, encoding: .macOSRoman) }
        return score(mac) > score(windows) ? Decoded(text: mac, encoding: .macOSRoman) : Decoded(text: windows, encoding: .windowsCP1252)
    }

    private static func score(_ text: String) -> Int {
        text.unicodeScalars.filter { !$0.isASCII && CharacterSet.lowercaseLetters.contains($0) }.count
    }
}
