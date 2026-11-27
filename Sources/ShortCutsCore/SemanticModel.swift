import Foundation

/// A tiny static embedding model for natural-language search.
///
/// The file `semantic-model.bin` holds a lookup table: one 64-number vector per token,
/// stored as int8 with one float scale per token (about 5 MB). To embed a text, the model
/// splits it into tokens, looks up their vectors and averages them. There is no neural
/// network and no network access. `scripts/build-semantic-model.py` makes the file.
///
/// The file is memory-mapped, so only the rows that a search reads stay in memory.
/// The vocabulary is sorted by UTF-8 bytes, and a lookup is a binary search in the mapped
/// file, so the model builds no dictionary in memory.
public final class SemanticModel: @unchecked Sendable {

    public let count: Int
    public let dims: Int

    private let data: Data
    private let offsetsStart = 16
    private let stringsStart: Int
    private let scalesStart: Int
    private let rowsStart: Int

    /// The model in the app bundle, opened on first use. Nil when the file is missing or damaged.
    public static let shared: SemanticModel? = {
        guard let url = Bundle.main.url(forResource: "semantic-model", withExtension: "bin") else { return nil }
        return SemanticModel(url: url)
    }()

    public convenience init?(url: URL) {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        self.init(data: data)
    }

    /// Checks the whole layout before use, so a damaged file gives nil and never a bad read.
    public init?(data: Data) {
        guard data.count >= 16 else { return nil }
        let header: (magic: Bool, version: UInt32, count: Int, dims: Int) = data.withUnsafeBytes { raw in
            (raw.prefix(4).elementsEqual("SCSM".utf8),
             Self.u32(raw, 4),
             Int(Self.u32(raw, 8)),
             Int(Self.u32(raw, 12)))
        }
        guard header.magic, header.version == 1,
              header.count > 0, header.count < 10_000_000,
              header.dims > 0, header.dims <= 1024 else { return nil }

        let count = header.count
        let dims = header.dims
        let stringsStart = 16 + (count + 1) * 4
        guard data.count >= stringsStart else { return nil }

        let blobLength: Int? = data.withUnsafeBytes { raw in
            guard Self.u32(raw, 16) == 0 else { return nil }
            var previous: UInt32 = 0
            for i in 1...count {
                let offset = Self.u32(raw, 16 + i * 4)
                guard offset > previous else { return nil }   // every token has at least one byte
                previous = offset
            }
            return Int(previous)
        }
        guard let blobLength else { return nil }

        let stringsEnd = stringsStart + blobLength
        let scalesStart = (stringsEnd + 3) & ~3
        let rowsStart = scalesStart + count * 4
        guard data.count == rowsStart + count * dims else { return nil }

        self.data = data
        self.count = count
        self.dims = dims
        self.stringsStart = stringsStart
        self.scalesStart = scalesStart
        self.rowsStart = rowsStart
    }

    // MARK: - Public API

    /// The unit-length vector of `text`, or nil when no token of the text is known.
    public func embed(_ text: String) -> [Float]? {
        data.withUnsafeBytes { raw -> [Float]? in
            let rows = tokenRows(text, raw).compactMap { $0 }
            guard !rows.isEmpty else { return nil }
            var sum = [Float](repeating: 0, count: dims)
            for row in rows {
                let scale = Float(bitPattern: Self.u32(raw, scalesStart + row * 4))
                let base = rowsStart + row * dims
                for d in 0..<dims {
                    sum[d] += Float(raw.load(fromByteOffset: base + d, as: Int8.self)) * scale
                }
            }
            let n = Float(rows.count)
            var norm: Float = 0
            for d in 0..<dims {
                sum[d] /= n
                norm += sum[d] * sum[d]
            }
            let length = norm.squareRoot() + 1e-12
            return sum.map { $0 / length }
        }
    }

    /// The token strings of `text`, with "[UNK]" for an unknown word. For tests and debugging.
    public func tokens(for text: String) -> [String] {
        data.withUnsafeBytes { raw in
            tokenRows(text, raw).map { row in
                guard let row else { return "[UNK]" }
                let start = Int(Self.u32(raw, offsetsStart + row * 4))
                let end = Int(Self.u32(raw, offsetsStart + (row + 1) * 4))
                return String(decoding: raw[(stringsStart + start)..<(stringsStart + end)], as: UTF8.self)
            }
        }
    }

    /// Cosine similarity of two unit-length vectors.
    public static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        var dot: Float = 0
        for i in 0..<min(a.count, b.count) { dot += a[i] * b[i] }
        return dot
    }

    // MARK: - Tokenizer (BERT WordPiece, the same rules as the Hugging Face tokenizer)

    /// The row of each token, or nil for an unknown word.
    private func tokenRows(_ text: String, _ raw: UnsafeRawBufferPointer) -> [Int?] {
        var result: [Int?] = []
        var candidate: [UInt8] = []
        for word in Self.preTokenize(Self.normalize(text)) {
            let bytes = Array(String(String.UnicodeScalarView(word)).utf8)
            // Byte offset of each scalar boundary, so that a piece never splits a character.
            var boundaries: [Int] = [0]
            for scalar in word { boundaries.append(boundaries.last! + UTF8.width(scalar)) }

            guard word.count <= 100 else { result.append(nil); continue }
            var pieces: [Int] = []
            var start = 0                     // index into `boundaries`
            var bad = false
            while start < word.count {
                var end = word.count
                var found: Int?
                while start < end {
                    candidate.removeAll(keepingCapacity: true)
                    if start > 0 { candidate.append(0x23); candidate.append(0x23) }   // "##"
                    candidate.append(contentsOf: bytes[boundaries[start]..<boundaries[end]])
                    if let row = lookup(candidate, raw) { found = row; break }
                    end -= 1
                }
                guard let row = found else { bad = true; break }
                pieces.append(row)
                start = end
            }
            if bad { result.append(nil) } else { result.append(contentsOf: pieces.map { Optional($0) }) }
        }
        return result
    }

    /// Binary search for the exact byte string in the sorted vocabulary.
    private func lookup(_ key: [UInt8], _ raw: UnsafeRawBufferPointer) -> Int? {
        var low = 0
        var high = count - 1
        while low <= high {
            let mid = (low + high) / 2
            let start = stringsStart + Int(Self.u32(raw, offsetsStart + mid * 4))
            let end = stringsStart + Int(Self.u32(raw, offsetsStart + (mid + 1) * 4))
            let order = Self.compare(key, raw, start, end)
            if order == 0 { return mid }
            if order < 0 { high = mid - 1 } else { low = mid + 1 }
        }
        return nil
    }

    private static func compare(_ key: [UInt8], _ raw: UnsafeRawBufferPointer, _ start: Int, _ end: Int) -> Int {
        let length = end - start
        let common = min(key.count, length)
        for i in 0..<common {
            let a = key[i]
            let b = raw[start + i]
            if a != b { return a < b ? -1 : 1 }
        }
        return key.count == length ? 0 : (key.count < length ? -1 : 1)
    }

    /// BertNormalizer: clean text, pad Chinese characters, strip accents, lowercase.
    static func normalize(_ text: String) -> [Unicode.Scalar] {
        var cleaned = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar.value == 0 || scalar.value == 0xFFFD || isControl(scalar) { continue }
            if isWhitespace(scalar) {
                cleaned.append(" ")
            } else if isChinese(scalar) {
                cleaned.append(" ")
                cleaned.append(scalar)
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        var stripped = String.UnicodeScalarView()
        for scalar in String(cleaned).decomposedStringWithCanonicalMapping.unicodeScalars
        where scalar.properties.generalCategory != .nonspacingMark {
            stripped.append(scalar)
        }
        return Array(String(stripped).lowercased().unicodeScalars)
    }

    /// BertPreTokenizer: split on whitespace, and make each punctuation character a word.
    static func preTokenize(_ scalars: [Unicode.Scalar]) -> [[Unicode.Scalar]] {
        var words: [[Unicode.Scalar]] = []
        var current: [Unicode.Scalar] = []
        for scalar in scalars {
            if scalar.properties.isWhitespace {
                if !current.isEmpty { words.append(current); current.removeAll() }
            } else if isPunctuation(scalar) {
                if !current.isEmpty { words.append(current); current.removeAll() }
                words.append([scalar])
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    private static func isWhitespace(_ s: Unicode.Scalar) -> Bool {
        s == "\t" || s == "\n" || s == "\r" || s.properties.isWhitespace
    }

    private static func isControl(_ s: Unicode.Scalar) -> Bool {
        if s == "\t" || s == "\n" || s == "\r" { return false }
        switch s.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned: return true
        default: return false
        }
    }

    private static func isPunctuation(_ s: Unicode.Scalar) -> Bool {
        if s.isASCII, (33...47).contains(s.value) || (58...64).contains(s.value)
            || (91...96).contains(s.value) || (123...126).contains(s.value) {
            return true
        }
        switch s.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation:
            return true
        default:
            return false
        }
    }

    private static func isChinese(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F,
             0x2B740...0x2B81F, 0x2B920...0x2CEAF, 0xF900...0xFAFF, 0x2F800...0x2FA1F:
            return true
        default:
            return false
        }
    }

    private static func u32(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
}
