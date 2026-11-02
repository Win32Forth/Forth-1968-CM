import Foundation

/// One object line the way the 1968 assembler printed it.
struct ObjectRecord {
    var address: Int
    var reloc: String
    var object: String
    var mnemonic: String
    var sourceLine: Int
}

struct Assembly {
    var image: [Int: UInt16]
    var records: [ObjectRecord]
    var symbols: [String: Int]
    var entry: Int
    var link: Int
    var libf: [Int: String]
    /// Address of `B I ACCEP`, where workspace A holds the next source character.
    var acceptExit: Int
    var errors: [String]
}

func hex4(_ value: Int) -> String {
    String(format: "%04X", value & 0xFFFF)
}

/// Two-pass assembler for the card-column subset used by FORTH.asm.
/// Object text is what the listing prints. LIBF occupies one memory word;
/// the printed field is the subroutine name code, which the loader would
/// replace. LINK occupies four words; the listing shows only BALO's name code.
struct Assembler {
    private var source: [String] = []
    private var pass = 1
    private var attempt = 1
    private var lc = 0
    private var orgAdvanced = 1
    private var symbols: [String: Int] = [:]
    private var image: [Int: UInt16] = [:]
    private var records: [ObjectRecord] = []
    private var errors: [String] = []
    private var libf: [Int: String] = [:]
    private var entry = 0
    private var link = 0
    private var acceptExit = 0
    private var retry = false
    /// Unconditional branches whose displacement does not fit in eight bits.
    private var forceLong: Set<Int> = []

    private var label = ""
    private var mnemonic = ""
    private var mods = ""
    private var operand = ""
    private var sourceLine = 0

    static func assemble(_ text: String) -> Assembly {
        var asm = Assembler()
        asm.source = text.components(separatedBy: .newlines)
        while asm.attempt <= 6 {
            asm.errors = []
            asm.symbols = [:]
            asm.image = [:]
            asm.records = []
            asm.libf = [:]
            asm.entry = 0
            asm.link = 0
            asm.acceptExit = 0
            asm.retry = false
            asm.pass = 1
            asm.lc = 0
            asm.walk()
            if !asm.errors.isEmpty { break }
            asm.pass = 2
            asm.lc = 0
            asm.walk()
            if !asm.retry { break }
            asm.attempt += 1
        }
        return Assembly(
            image: asm.image,
            records: asm.records,
            symbols: asm.symbols,
            entry: asm.entry,
            link: asm.link,
            libf: asm.libf,
            acceptExit: asm.acceptExit,
            errors: asm.errors
        )
    }

    private mutating func walk() {
        for (index, line) in source.enumerated() {
            sourceLine = index + 1
            parse(line)
        }
    }

    /// Label is columns 21–25, opcode 27–30, format and tag 32–33.
    /// The operand is the token at column 35. A blank column 35 means there
    /// is no operand; the rest of the card is a remark.
    private mutating func parse(_ line: String) {
        if line.isEmpty || line.hasPrefix("//") || line.hasPrefix("*") { return }
        let chars = Array(line)
        if chars.count > 20 && chars[20] == "*" { return }
        func slice(_ from: Int, _ to: Int) -> String {
            guard from < chars.count else { return "" }
            return String(chars[from..<min(to, chars.count)])
        }
        label = slice(20, 25).trimmingCharacters(in: .whitespaces)
        mnemonic = slice(26, 30).trimmingCharacters(in: .whitespaces)
        mods = slice(31, 33).trimmingCharacters(in: .whitespaces)
        if chars.count > 34 && chars[34] != " " {
            var end = 34
            while end < chars.count && end < 72 && chars[end] != " " { end += 1 }
            operand = String(chars[34..<end])
        } else {
            operand = ""
        }
        if mnemonic.isEmpty {
            if !label.isEmpty { define() }
            return
        }
        encode()
    }

    private mutating func encode() {
        switch mnemonic {
        case "ABS":
            return
        case "ORG":
            orgAdvanced = 0
            lc = evaluate(operand) & 0xFFFF
        case "END":
            orgAdvanced = 0
            define()
            entry = evaluate(operand) & 0xFFFF
            emit(stored: [], advance: 0, reloc: "", object: hex4(entry))
        case "DC":
            orgAdvanced = 1
            define()
            let word = UInt16(truncatingIfNeeded: evaluate(operand))
            emit(stored: [word], reloc: "0", object: hex4(Int(word)))
        case "BSS":
            orgAdvanced = 0
            define()
            let count = evaluate(operand)
            if count < 0 {
                errors.append("L\(sourceLine): negative BSS")
                return
            }
            emit(stored: [], advance: count, reloc: "", object: hex4(count))
        case "LIBF":
            define()
            let code = nameCode(operand)
            libf[lc] = operand
            emit(stored: [0], reloc: "20", object: code)
        case "LINK":
            define()
            link = lc
            let code = nameCode(operand)
            let hi = UInt16(code.prefix(4), radix: 16) ?? 0
            let lo = UInt16(code.suffix(4), radix: 16) ?? 0
            emit(stored: [hi, lo, 0, 0], reloc: "00", object: code)
        case "NOP":
            define()
            emit(stored: [0x1000], reloc: "0", object: "1000")
        case "SLA", "SLT", "SRA", "SRT":
            emitShift()
        case "MDX", "MDM":
            emitModify()
        case "B", "BSI", "BZ", "BNZ", "BP", "BNP", "BN", "BOD":
            emitBranch()
        default:
            if let base = Assembler.standardOpcode[mnemonic] {
                emitStandard(base)
            } else {
                errors.append("L\(sourceLine): unknown opcode \(mnemonic)")
            }
        }
    }

    private static let standardOpcode = [
        "A": 0x8000, "AD": 0x8800, "S": 0x9000, "SD": 0x9800,
        "M": 0xA000, "D": 0xA800, "LD": 0xC000, "LDD": 0xC800,
        "STO": 0xD000, "STD": 0xD800, "AND": 0xE000, "OR": 0xE800,
        "EOR": 0xF000, "LDX": 0x6000, "STX": 0x6800, "XIO": 0x0800,
    ]

    private mutating func emitStandard(_ base: Int) {
        let (op, long) = opcodeBits(base, forceLong: false)
        orgAdvanced = long ? 2 : 1
        define()
        let value = evaluate(operand)
        if long {
            let words = [UInt16(op & 0xFFFF), UInt16(truncatingIfNeeded: value)]
            emit(stored: words, reloc: "00", object: hex4(op) + hex4(value))
        } else {
            let byte = displacement(value, relative: shortIsRelative)
            let word = (op | byte) & 0xFFFF
            emit(stored: [UInt16(word)], reloc: "0", object: hex4(word))
        }
    }

    /// Short LDX loads the displacement itself. Short STX stores an index
    /// at IAR+displacement. Any other short indexed reference adds the
    /// displacement to the index at run time, so the field is not relative.
    private var shortIsRelative: Bool {
        if mnemonic == "LDX" { return false }
        if mnemonic == "STX" { return true }
        return tag == 0
    }

    private mutating func emitShift() {
        let base: Int
        switch mnemonic {
        case "SLA": base = 0x1000
        case "SLT": base = 0x1080
        case "SRA": base = 0x1800
        default: base = 0x1880
        }
        orgAdvanced = 1
        define()
        let count = evaluate(operand)
        if count < 0 || count > 32 {
            errors.append("L\(sourceLine): shift count \(count)")
        }
        let word = base | (count & 0x3F)
        emit(stored: [UInt16(word)], reloc: "0", object: hex4(word))
    }

    private mutating func emitModify() {
        let forced = mnemonic == "MDM"
        let (op0, long) = opcodeBits(0x7000, forceLong: forced)
        orgAdvanced = long ? 2 : 1
        define()
        let parts = splitComma(operand)
        if long {
            let dest = evaluate(parts.0)
            var op = op0
            if tag == 0 {
                let inc = parts.1.map { evaluate($0) } ?? 0
                op |= inc & 0xFF
            }
            let words = [UInt16(op & 0xFFFF), UInt16(truncatingIfNeeded: dest)]
            emit(stored: words, reloc: "00", object: hex4(op) + hex4(dest))
        } else {
            let dest = evaluate(parts.0)
            let byte = displacement(dest, relative: tag == 0)
            let word = (op0 | byte) & 0xFFFF
            emit(stored: [UInt16(word)], reloc: "0", object: hex4(word))
        }
    }

    private mutating func emitBranch() {
        if mnemonic == "B" && !mods.contains("I") && !mods.contains("L")
            && !forceLong.contains(sourceLine) {
            let (op0, _) = opcodeBits(0x7000, forceLong: false)
            orgAdvanced = 1
            define()
            if mnemonic == "B" && operand == "ACCEP" && mods.contains("I") {
                acceptExit = lc
            }
            let dest = evaluate(operand)
            let byte = displacement(dest, relative: tag == 0)
            let word = (op0 | byte) & 0xFFFF
            emit(stored: [UInt16(word)], reloc: "0", object: hex4(word))
            return
        }
        let base: Int
        let forced: Bool
        switch mnemonic {
        case "B": base = 0x4800; forced = true
        case "BSI": base = 0x4000; forced = false
        case "BZ": base = 0x4818; forced = true
        case "BNZ": base = 0x4820; forced = true
        case "BP": base = 0x4830; forced = true
        case "BNP": base = 0x4808; forced = true
        case "BN": base = 0x4828; forced = true
        default: base = 0x4804; forced = true
        }
        let parts = splitComma(operand)
        let (op0, long) = opcodeBits(base | conditionMask(parts.1 ?? ""), forceLong: forced)
        orgAdvanced = long ? 2 : 1
        define()
        if mnemonic == "B" && parts.0 == "ACCEP" && mods.contains("I") {
            acceptExit = lc
        }
        let dest = evaluate(parts.0)
        if long {
            let words = [UInt16(op0 & 0xFFFF), UInt16(truncatingIfNeeded: dest)]
            emit(stored: words, reloc: "00", object: hex4(op0) + hex4(dest))
        } else {
            let byte = displacement(dest, relative: tag == 0)
            let word = (op0 | byte) & 0xFFFF
            emit(stored: [UInt16(word)], reloc: "0", object: hex4(word))
        }
    }

    private var tag: Int {
        if mods.contains("1") { return 1 }
        if mods.contains("2") { return 2 }
        if mods.contains("3") { return 3 }
        return 0
    }

    /// Format I is indirect and therefore long. BZ and the other sense
    /// branches are long even when the target is within a short displacement.
    private func opcodeBits(_ base: Int, forceLong: Bool) -> (Int, Bool) {
        var op = base
        let long = forceLong || mods.contains("L") || mods.contains("I")
        switch tag {
        case 1: op |= 0x0100
        case 2: op |= 0x0200
        case 3: op |= 0x0300
        default: break
        }
        if long {
            op |= 0x0400
            if mods.contains("I") { op |= 0x0080 }
        }
        return (op, long)
    }

    private func conditionMask(_ tests: String) -> Int {
        var mask = 0
        for ch in tests {
            switch ch {
            case "Z": mask |= 0x20
            case "-": mask |= 0x10
            case "+", "&": mask |= 0x08
            case "E": mask |= 0x04
            case "C": mask |= 0x02
            case "O": mask |= 0x01
            default:
                // conditionMask is called from a mutating function; errors are
                // reported by the caller only when the character is unexpected.
                // A digit here means the comma was an MDM increment, not a test.
                break
            }
        }
        return mask
    }

    private mutating func displacement(_ value: Int, relative: Bool) -> Int {
        let disp = relative ? value - (lc + 1) : value
        // Pass 1 still has forward references. Widening here would turn a
        // short branch into a long one before its target is known.
        if pass == 1 { return disp & 0xFF }
        if disp < -128 || disp > 127 {
            if mnemonic == "B" && attempt < 6 && !forceLong.contains(sourceLine) {
                forceLong.insert(sourceLine)
                retry = true
            } else {
                errors.append("L\(sourceLine): displacement \(disp) at \(hex4(lc))")
            }
            return 0
        }
        return disp & 0xFF
    }

    private mutating func define() {
        guard !label.isEmpty else { return }
        if pass == 1 {
            if symbols[label] != nil {
                errors.append("L\(sourceLine): duplicate label \(label)")
            }
            symbols[label] = lc
        } else if symbols[label] != lc {
            errors.append("L\(sourceLine): phase error \(label)")
        }
    }

    private mutating func emit(stored: [UInt16], advance: Int? = nil, reloc: String, object: String) {
        let count = advance ?? stored.count
        if pass == 2 {
            records.append(ObjectRecord(
                address: lc,
                reloc: reloc,
                object: object,
                mnemonic: mnemonic,
                sourceLine: sourceLine
            ))
            for (offset, word) in stored.enumerated() {
                image[lc + offset] = word
            }
        }
        lc += count
    }

    /// `*` is the location counter, adjusted the way the 1130 assembler
    /// adjusted it: one past a DC, or just past a long instruction.
    /// `/` introduces hexadecimal. `*` and `/` bind tighter than `+` and `-`.
    private mutating func evaluate(_ token: String) -> Int {
        if token.isEmpty { return 0 }
        var parser = ExprParser(
            chars: Array(token),
            symbols: symbols,
            star: lc + orgAdvanced,
            pass: pass
        )
        let value = parser.parse()
        if let message = parser.error {
            errors.append("L\(sourceLine): \(message) in \(token)")
        }
        return value
    }
}

private struct ExprParser {
    let chars: [Character]
    var index = 0
    let symbols: [String: Int]
    let star: Int
    let pass: Int
    var error: String?

    mutating func parse() -> Int {
        let value = parseSum()
        if index < chars.count && error == nil {
            error = "trailing \(chars[index])"
        }
        return value
    }

    private mutating func parseSum() -> Int {
        var value = parseProduct()
        while let op = peek(), op == "+" || op == "-" {
            index += 1
            let right = parseProduct()
            value = op == "+" ? value + right : value - right
        }
        return value
    }

    private mutating func parseProduct() -> Int {
        var value = parseUnary()
        while let op = peek(), op == "*" || op == "/" || op == "&" {
            index += 1
            let right = parseUnary()
            if op == "*" {
                value *= right
            } else if op == "/" {
                value = right == 0 ? 0 : value / right
            } else {
                value &= right
            }
        }
        return value
    }

    private mutating func parseUnary() -> Int {
        if peek() == "-" {
            index += 1
            return -parseUnary()
        }
        if peek() == "+" {
            index += 1
            return parseUnary()
        }
        return parseTerm()
    }

    private mutating func parseTerm() -> Int {
        guard let ch = peek() else {
            error = "missing term"
            return 0
        }
        if ch == "*" {
            index += 1
            return star
        }
        if ch == "/" {
            index += 1
            return readNumber(16)
        }
        if ch.isNumber {
            return readNumber(10)
        }
        if ch.isLetter || ch == "$" || ch == "#" || ch == "@" {
            return lookup(readSymbol())
        }
        error = "bad term"
        index += 1
        return 0
    }

    private mutating func readNumber(_ radix: Int) -> Int {
        let digits = radix == 16 ? "0123456789ABCDEF" : "0123456789"
        var value = 0
        var any = false
        while let ch = peek() {
            let folded = String(ch).uppercased()
            guard folded.count == 1, let digit = digits.firstIndex(of: folded[folded.startIndex]) else { break }
            any = true
            value = value * radix + digits.distance(from: digits.startIndex, to: digit)
            index += 1
        }
        if !any { error = "missing number" }
        return value
    }

    private mutating func readSymbol() -> String {
        var name = ""
        while let ch = peek(), ch.isLetter || ch.isNumber || ch == "$" {
            name.append(ch)
            index += 1
        }
        return name
    }

    private mutating func lookup(_ name: String) -> Int {
        if let value = symbols[name] { return value }
        if pass == 2 { error = "undefined \(name)" }
        return 0
    }

    private func peek() -> Character? {
        index < chars.count ? chars[index] : nil
    }
}

private func splitComma(_ token: String) -> (String, String?) {
    guard let comma = token.firstIndex(of: ",") else { return (token, nil) }
    return (String(token[..<comma]), String(token[token.index(after: comma)...]))
}

/// Five characters, each EBCDIC low 6 bits, packed into 30 bits.
private func nameCode(_ name: String) -> String {
    var value = 0
    let bytes = Array(name.utf8)
    for position in 0..<5 {
        let byte: UInt8 = position < bytes.count ? bytes[position] : 32
        value = (value << 6) | ebcdicSix(byte)
    }
    return String(format: "%08X", value)
}

private func ebcdicSix(_ byte: UInt8) -> Int {
    if byte == 32 { return 0 }
    if byte >= 48 && byte <= 57 { return 0x30 + Int(byte - 48) }
    if byte >= 65 && byte <= 73 { return 1 + Int(byte - 65) }
    if byte >= 74 && byte <= 82 { return 0x11 + Int(byte - 74) }
    if byte >= 83 && byte <= 90 { return 0x22 + Int(byte - 83) }
    return 0
}

struct ListingMismatch {
    var address: Int
    var detail: String
}

func compareListing(_ assembly: Assembly, listing text: String) -> [ListingMismatch] {
    var listed: [Int: (reloc: String, object: String)] = [:]
    for line in text.components(separatedBy: .newlines) {
        guard let parsed = parseListingObject(line) else { continue }
        if listed[parsed.address] == nil {
            listed[parsed.address] = (parsed.reloc, parsed.object)
        }
    }
    var mismatches: [ListingMismatch] = []
    var seen = Set<Int>()
    for record in assembly.records {
        seen.insert(record.address)
        guard let row = listed[record.address] else {
            mismatches.append(ListingMismatch(
                address: record.address,
                detail: "\(hex4(record.address)) \(record.mnemonic) has no listing line"
            ))
            continue
        }
        if row.reloc != record.reloc || row.object != record.object {
            mismatches.append(ListingMismatch(
                address: record.address,
                detail: "\(hex4(record.address)) \(record.mnemonic): assembled \(record.reloc) \(record.object), listing \(row.reloc) \(row.object)"
            ))
        }
    }
    for address in listed.keys.sorted() where !seen.contains(address) {
        mismatches.append(ListingMismatch(
            address: address,
            detail: "\(hex4(address)) is in the listing but was not assembled"
        ))
    }
    return mismatches.sorted { $0.address < $1.address }
}

private func parseListingObject(_ line: String) -> (address: Int, reloc: String, object: String)? {
    let chars = Array(line)
    guard chars.count >= 4 else { return nil }
    let head = String(chars[0..<4])
    guard head.allSatisfy(\.isHexDigit), chars.count == 4 || chars[4] == " " else { return nil }
    guard let address = Int(head, radix: 16), address >= 0x0900 else { return nil }
    let tokens = line.dropFirst(4).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = tokens.first, first.allSatisfy(\.isHexDigit) else { return nil }
    if first.count <= 2, tokens.count >= 2 {
        let second = tokens[1]
        if second.allSatisfy(\.isHexDigit) && (second.count == 4 || second.count == 8) {
            return (address, first.uppercased(), second.uppercased())
        }
    }
    if first.count == 4 || first.count == 8 {
        return (address, "", first.uppercased())
    }
    return nil
}
