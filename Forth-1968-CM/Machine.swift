import Foundation

/// IBM 1130 CPU plus the disk and printer this Forth program actually uses.
/// Index registers are memory words 1, 2 and 3. LIBF DISK1 and LIBF PRNT1 are
/// trapped: a completed test returns past the `B BL1` / `B PR1` that would
/// otherwise spin forever.
final class Machine {
    let memoryMask = 0x7FFF
    var memory: [UInt16]
    var iar = 0
    var acc = 0
    var ext = 0
    var carry = false
    var overflow = false

    let entry: Int
    let link: Int
    let libf: [Int: String]
    let acceptExit: Int
    let workspaceA: Int
    private var sectors: [Int: [UInt16]]
    private let forthCharacter: [Character]
    private let ebcdicOf: [Character: Int]
    private let asciiOfEbcdic: [Int: Character]

    private(set) var output: [String] = []
    private var console = ""
    private var accepted = ""
    private var acceptColumn = 0
    private var keyboardBusy = false
    private var keyCode: Int?
    private var printerDone = false
    private var pendingKeys: [Int] = []
    private var halt: String?
    private var steps = 0
    private var xioLog: [String] = []
    private var trail = Array(repeating: (0, 0), count: 24)
    private var trailAt = 0
    private var ring = Array(repeating: -1, count: 48)
    private var ringAt = 0
    private var hotspot = 0

    init(assembly: Assembly, source: String) {
        memory = Array(repeating: 0, count: 0x8000)
        entry = assembly.entry
        link = assembly.link
        libf = assembly.libf
        acceptExit = assembly.acceptExit
        workspaceA = assembly.symbols["A"] ?? 0
        let alphabet = Machine.alphabet()
        forthCharacter = alphabet.characters
        ebcdicOf = alphabet.encode
        asciiOfEbcdic = alphabet.decode
        sectors = Machine.packSource(source, encode: alphabet.encode)
        for (address, word) in assembly.image {
            guard address >= 0 && address < memory.count else { continue }
            memory[address] = word
        }
        iar = entry
    }

    func firstRecord() -> String {
        let data = sectors[0x10EE] ?? []
        guard data.count >= 320 else { return "" }
        let forward = Array(data[280..<320].reversed())
        return decodeWords(forward, count: 36)
    }

    func run(limit: Int) -> String {
        while steps < limit && halt == nil {
            steps += 1
            if iar == link {
                halt = "returned to monitor"
                break
            }
            if let name = libf[iar] {
                service(name)
                continue
            }
            step()
            if steps % 20_000 == 0 && hotspotLoop() {
                halt = "stuck near \(hex4(iar))"
            }
        }
        if halt == nil { halt = "step limit" }
        flushConsole()
        return halt ?? "stopped"
    }

    private(set) var sectorsRead = 0

    var trace: String {
        var lines = xioLog
        lines.append("last instructions:")
        for offset in 0..<trail.count {
            let item = trail[(trailAt + offset) % trail.count]
            if item.0 == 0 && item.1 == 0 { continue }
            lines.append("  \(hex4(item.0)) \(hex4(item.1))")
        }
        lines.append("low memory:")
        for base in stride(from: 0, to: 0x20, by: 8) {
            let words = (0..<8).map { hex4(read(base + $0)) }.joined(separator: " ")
            lines.append("  \(hex4(base)) \(words)")
        }
        if !console.isEmpty { lines.append("console: \(console)") }
        if !accepted.isEmpty {
            lines.append("accepted: \(accepted.prefix(240))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: CPU

    private func step() {
        let pc = iar
        let ir = read(iar)
        iar = (iar + 1) & memoryMask
        remember(pc, ir)
        if ir == 0 {
            halt = "executed zero at \(hex4(pc))"
            return
        }
        let op = (ir >> 11) & 0x1F
        let tag = (ir >> 8) & 3
        let long = (ir & 0x0400) != 0 && fBitUsed[op]
        var word2 = 0
        if long {
            word2 = read(iar)
            iar = (iar + 1) & memoryMask
        }
        switch op {
        case 0x01: xio(effective(ir, tag: tag, long: long, word2: word2))
        case 0x02: shiftLeft(ir, tag: tag)
        case 0x03: shiftRight(ir, tag: tag)
        case 0x04:
            overflow = (ir & 1) != 0
            carry = (ir & 2) != 0
        case 0x05:
            var status = read(effective(ir, tag: tag, long: long, word2: word2)) & 0xFF00
            if carry { status |= 2 }
            if overflow { status |= 1 }
            write(effective(ir, tag: tag, long: long, word2: word2), status)
            carry = false
            overflow = false
        case 0x06:
            // Console output completes by interrupting into READY, which
            // patches QUEUE and returns to the branch after this WAIT.
            // A keyboard request instead waits here for a key, then
            // interrupts into CHARACTER. Disk waits have no interrupt
            // pending, so they resume the continuation QUEUE planted.
            if keyboardBusy {
                if keyCode == nil {
                    guard let key = readKey() else {
                        halt = "end of input"
                        break
                    }
                    keyCode = key
                }
                enterConsoleInterrupt()
            } else if printerDone {
                enterConsoleInterrupt()
            } else {
                let continuation = read((pc - 1) & memoryMask)
                if continuation >= 0x0900 && continuation < memory.count {
                    iar = continuation
                } else {
                    halt = "wait at \(hex4(pc))"
                }
            }
        case 0x08:
            if long && condition(ir) { break }
            let ea = effective(ir, tag: tag, long: long, word2: word2)
            write(ea, iar)
            iar = (ea + 1) & memoryMask
        case 0x09:
            if long {
                if !condition(ir) {
                    iar = effective(ir, tag: tag, long: true, word2: word2)
                }
            } else if condition(ir) {
                iar = (iar + 1) & memoryMask
            }
        case 0x0C:
            let value = long ? ((ir & 0x80) != 0 ? read(word2) : word2) : sext8(ir)
            if tag != 0 { write(tag, value) }
            else { iar = value & memoryMask }
        case 0x0D:
            let ea: Int
            if long { ea = (ir & 0x80) != 0 ? read(word2) : word2 }
            else { ea = (iar + sext8(ir)) & memoryMask }
            write(ea, tag == 0 ? iar : read(tag))
        case 0x0E:
            modify(ir, tag: tag, long: long, word2: word2)
        case 0x10: add(read(effective(ir, tag: tag, long: long, word2: word2)))
        case 0x11: addDouble(effective(ir, tag: tag, long: long, word2: word2))
        case 0x12: subtract(read(effective(ir, tag: tag, long: long, word2: word2)))
        case 0x13: subtractDouble(effective(ir, tag: tag, long: long, word2: word2))
        case 0x14: multiply(read(effective(ir, tag: tag, long: long, word2: word2)))
        case 0x15: divide(read(effective(ir, tag: tag, long: long, word2: word2)))
        case 0x18: acc = read(effective(ir, tag: tag, long: long, word2: word2))
        case 0x19:
            let ea = effective(ir, tag: tag, long: long, word2: word2)
            acc = read(ea)
            ext = read(ea | 1)
        case 0x1A: write(effective(ir, tag: tag, long: long, word2: word2), acc)
        case 0x1B:
            let ea = effective(ir, tag: tag, long: long, word2: word2)
            write(ea | 1, ext)
            write(ea, acc)
        case 0x1C: acc &= read(effective(ir, tag: tag, long: long, word2: word2))
        case 0x1D: acc |= read(effective(ir, tag: tag, long: long, word2: word2))
        case 0x1E: acc ^= read(effective(ir, tag: tag, long: long, word2: word2))
        default:
            halt = "invalid opcode \(hex4(ir)) at \(hex4(pc))"
        }
        acc &= 0xFFFF
        ext &= 0xFFFF
        if pc == acceptExit { noteAccepted() }
    }

    /// Long instructions use the address word, then the index, then one level
    /// of indirect. LDX, STX and MDX do not use this address.
    private func effective(_ ir: Int, tag: Int, long: Bool, word2: Int) -> Int {
        if long {
            var ea = word2 & 0xFFFF
            if tag != 0 { ea = (ea + read(tag)) & 0xFFFF }
            if ir & 0x80 != 0 { ea = read(ea) }
            return ea
        }
        let disp = sext8(ir)
        if tag != 0 { return (read(tag) + disp) & 0xFFFF }
        return (iar + disp) & 0xFFFF
    }

    private func modify(_ ir: Int, tag: Int, long: Bool, word2: Int) {
        let old: Int
        let new: Int
        if long {
            if tag != 0 {
                let addend = (ir & 0x80) != 0 ? read(word2) : word2
                old = read(tag)
                new = (old + addend) & 0xFFFF
                write(tag, new)
            } else {
                let addend = sext8(ir & 0xFF)
                old = read(word2)
                new = (old + addend) & 0xFFFF
                write(word2, new)
            }
        } else if tag != 0 {
            let disp = sext8(ir)
            old = read(tag)
            new = (old + disp) & 0xFFFF
            write(tag, new)
        } else {
            iar = (iar + sext8(ir)) & memoryMask
            return
        }
        if new == 0 || (old ^ new) & 0x8000 != 0 {
            iar = (iar + 1) & memoryMask
        }
    }

    /// True when any selected condition holds. Overflow clears if it is tested.
    private func condition(_ ir: Int) -> Bool {
        if ir & 0x01 != 0 {
            if !overflow { return true }
            overflow = false
        }
        if ir & 0x02 != 0 && !carry { return true }
        if ir & 0x04 != 0 && acc & 1 == 0 { return true }
        if ir & 0x08 != 0 && acc & 0x8000 == 0 && acc != 0 { return true }
        if ir & 0x10 != 0 && acc & 0x8000 != 0 { return true }
        if ir & 0x20 != 0 && acc == 0 { return true }
        return false
    }

    private func add(_ src: Int) {
        let old = acc & 0xFFFF
        let sum = (old + src) & 0xFFFF
        carry = sum < src
        if !overflow && ((~src ^ old) & (src ^ sum)) & 0x8000 != 0 { overflow = true }
        acc = sum
    }

    private func subtract(_ src: Int) {
        let old = acc & 0xFFFF
        let diff = (old - src) & 0xFFFF
        carry = old < src
        if !overflow && ((old ^ src) & (old ^ diff)) & 0x8000 != 0 { overflow = true }
        acc = diff
    }

    private func addDouble(_ ea: Int) {
        let left = UInt32((acc & 0xFFFF) << 16 | (ext & 0xFFFF))
        let right = UInt32((read(ea) & 0xFFFF) << 16 | (read(ea | 1) & 0xFFFF))
        let wide = UInt64(left) &+ UInt64(right)
        let sum = UInt32(truncatingIfNeeded: wide)
        carry = wide > 0xFFFF_FFFF
        if !overflow {
            let ov = ((~Int(left) ^ Int(right)) & (Int(left) ^ Int(sum))) & 0x8000_0000
            if ov != 0 { overflow = true }
        }
        acc = Int(sum >> 16)
        ext = Int(sum & 0xFFFF)
    }

    private func subtractDouble(_ ea: Int) {
        let left = UInt32((acc & 0xFFFF) << 16 | (ext & 0xFFFF))
        let right = UInt32((read(ea) & 0xFFFF) << 16 | (read(ea | 1) & 0xFFFF))
        let wide = UInt64(left) &- UInt64(right)
        let diff = UInt32(truncatingIfNeeded: wide)
        carry = left < right
        if !overflow {
            let ov = ((Int(left) ^ Int(right)) & (Int(left) ^ Int(diff))) & 0x8000_0000
            if ov != 0 { overflow = true }
        }
        acc = Int(diff >> 16)
        ext = Int(diff & 0xFFFF)
    }

    private func multiply(_ src: Int) {
        let left = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: acc)))
        let right = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: src)))
        let product = Int64(left) * Int64(right)
        acc = Int((product >> 16) & 0xFFFF)
        ext = Int(product & 0xFFFF)
    }

    private func divide(_ src: Int) {
        let bits = UInt32((acc & 0xFFFF) << 16 | (ext & 0xFFFF))
        let dividend = Int32(bitPattern: bits)
        let divisor = Int32(Int16(bitPattern: UInt16(truncatingIfNeeded: src)))
        if divisor == 0 || (dividend == Int32.min && divisor == -1) {
            overflow = true
            return
        }
        let quotient = dividend / divisor
        if quotient > 32767 || quotient < -32768 {
            overflow = true
            return
        }
        acc = Int(quotient) & 0xFFFF
        ext = Int(dividend % divisor) & 0xFFFF
    }

    private func shiftLeft(_ ir: Int, tag: Int) {
        var count = (tag == 0 ? ir : read(tag)) & 0x3F
        let kind = ir & 0x00C0
        while count > 0 {
            if kind == 0x0080 {
                carry = acc & 0x8000 != 0
                let low = (ext & 0x8000) >> 15
                acc = ((acc << 1) & 0xFFFF) | low
                ext = (ext << 1) & 0xFFFF
            } else {
                carry = acc & 0x8000 != 0
                acc = (acc << 1) & 0xFFFF
            }
            count -= 1
        }
    }

    private func shiftRight(_ ir: Int, tag: Int) {
        var count = (tag == 0 ? ir : read(tag)) & 0x3F
        switch ir & 0x00C0 {
        case 0x0000:
            acc = count >= 16 ? 0 : (acc & 0xFFFF) >> count
        case 0x0080:
            while count > 0 {
                let intoExt = (acc & 1) << 15
                let sign = acc & 0x8000
                acc = ((acc >> 1) & 0x7FFF) | sign
                ext = ((ext >> 1) & 0x7FFF) | intoExt
                count -= 1
            }
        case 0x00C0:
            while count > 0 {
                let intoAcc = (ext & 1) << 15
                let intoExt = (acc & 1) << 15
                acc = ((acc >> 1) & 0x7FFF) | intoAcc
                ext = ((ext >> 1) & 0x7FFF) | intoExt
                count -= 1
            }
        default:
            halt = "invalid shift \(hex4(ir))"
        }
    }

    /// Long format exists for every opcode except the shift, load-status and wait groups.
    private let fBitUsed: [Bool] = [
        false, true, false, false, false, true, false, false,
        true, true, false, false, true, true, true, false,
        true, true, true, true, true, true, false, false,
        true, true, true, true, true, true, true, false,
    ]

    // MARK: I/O

    /// DISK1 read has three parameter words and returns to the following test.
    /// The test has two parameter words; not-busy skips the branch after them.
    /// PRNT1's test has one parameter word and the same skip.
    private func service(_ name: String) {
        let function = read(iar + 1)
        if name == "DISK1" && function == 0x1000 {
            readSector(read(iar + 2))
            iar = (iar + 4) & memoryMask
        } else if name == "DISK1" && function == 0 {
            iar = (iar + 4) & memoryMask
        } else if name == "PRNT1" && function == 0x2000 {
            emitPrint(read(iar + 2))
            iar = (iar + 4) & memoryMask
        } else if name == "PRNT1" && function == 0 {
            iar = (iar + 3) & memoryMask
        } else {
            halt = "LIBF \(name) function \(hex4(function)) at \(hex4(iar))"
        }
    }

    private func readSector(_ control: Int) {
        let count = min(read(control), 320)
        let sector = read(control + 1)
        let data = sectors[sector] ?? Array(repeating: UInt16(0x4040), count: 320)
        for offset in 0..<count {
            write(control + 2 + offset, Int(data[offset]))
        }
        sectorsRead += 1
    }

    private func emitPrint(_ control: Int) {
        let count = read(control)
        var words: [UInt16] = []
        for offset in 0..<count {
            words.append(UInt16(truncatingIfNeeded: read(control + 1 + offset)))
        }
        let line = decodeWords(words, count: count).trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return }
        output.append(line)
        print(line)
    }

    private func xio(_ ea: Int) {
        let address = read(ea)
        let control = read(ea | 1)
        let device = (control >> 11) & 0x1F
        let function = (control >> 8) & 7
        let modifier = control & 0xFF
        acc = 0
        if xioLog.count < 40 {
            xioLog.append("XIO dev \(hex4(device)) fn \(function) mod \(hex4(modifier)) addr \(hex4(address)) at \(hex4(iar))")
        }
        switch device {
        case 0x01: consoleXIO(address, function, modifier)
        case 0x04, 0x11: diskXIO(address, function, modifier)
        default:
            break
        }
    }

    private func consoleXIO(_ address: Int, _ function: Int, _ modifier: Int) {
        switch function {
        case 1:
            emitConsole((read(address) >> 8) & 0xFF)
            printerDone = true
        case 2:
            write(address, keyCode ?? 0)
            keyCode = nil
            keyboardBusy = false
        case 4:
            keyboardBusy = true
            keyCode = nil
        case 7:
            acc = 0
            if modifier & 1 != 0 { printerDone = false }
        default:
            break
        }
    }

    /// Level 4 interrupt: store the return address at the vector and run
    /// the handler. ACCEPT points the vector at CHARACTER; CHA points it
    /// at READY. The handler returns with a BOSC through that same word.
    private func enterConsoleInterrupt() {
        let vector = read(0x0C)
        guard vector >= 0x0900 && vector < memory.count else {
            halt = "bad console vector \(hex4(vector))"
            return
        }
        if xioLog.count < 40 {
            xioLog.append("IRQ \(hex4(vector)) back \(hex4(iar))")
        }
        write(vector, iar)
        iar = (vector + 1) & memoryMask
    }

    /// 1130 console printer codes. The high byte of an XIO write is a
    /// Selectric tilt/rotate code, from the SIMH `conout_to_ascii` table.
    /// A zero entry prints nothing useful and becomes "?". 0xFF is ignore.
    private static let consoleASCII: [UInt8] = [
        0x2E, 0xFF, 0xA2, 0x0A, 0x40, 0xFF, 0x25, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x46, 0x08, 0x66, 0x00, 0x47, 0x00, 0x67, 0x00, 0x42, 0x00, 0x62, 0x00, 0x43, 0x00, 0x63, 0x00,
        0x49, 0x20, 0x69, 0x00, 0x48, 0x00, 0x68, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x44, 0x00, 0x64, 0x00, 0x45, 0x00, 0x65, 0x00, 0x00, 0x00, 0x00, 0x00, 0x41, 0x00, 0x61, 0x00,
        0x24, 0x09, 0x21, 0x00, 0x26, 0x00, 0x3E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x4F, 0x00, 0x6F, 0x00, 0x50, 0x00, 0x6F, 0x00, 0x4B, 0x00, 0x6B, 0x00, 0x4C, 0x00, 0x6C, 0x00,
        0x52, 0x00, 0x72, 0x00, 0x51, 0x00, 0x71, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x4D, 0x00, 0x6D, 0x00, 0x4E, 0x00, 0x6E, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x00, 0x6A, 0x00,
        0x2C, 0x0D, 0x3A, 0x00, 0x2D, 0x00, 0x3F, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x57, 0x00, 0x77, 0x00, 0x58, 0x00, 0x78, 0x00, 0x53, 0x00, 0x73, 0x00, 0x54, 0x00, 0x74, 0x00,
        0x5A, 0x00, 0x7A, 0x00, 0x59, 0x00, 0x79, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x55, 0x00, 0x75, 0x00, 0x56, 0x00, 0x76, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2F, 0x00, 0x5F, 0x00,
        0x23, 0x00, 0x3D, 0x00, 0x30, 0x00, 0x7C, 0x00, 0x00, 0x00, 0x00, 0x00, 0x4A, 0x00, 0x6A, 0x00,
        0x36, 0x00, 0x3B, 0x00, 0x37, 0x00, 0x2A, 0x00, 0x32, 0x00, 0x2B, 0x00, 0x33, 0x00, 0x3C, 0x00,
        0x39, 0x00, 0x22, 0x00, 0x38, 0x00, 0x27, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x34, 0x00, 0xAC, 0x00, 0x35, 0x00, 0x29, 0x00, 0x00, 0x00, 0x00, 0x00, 0x31, 0x00, 0x28, 0x00,
    ]

    private func emitConsole(_ code: Int) {
        var ch = code & 0xFF
        if ch & 1 != 0 {
            ch &= ~0x0C
            if ch & ~1 == 0 { return }
        }
        let mapped = Machine.consoleASCII[ch]
        if mapped == 0xFF { return }
        if mapped == 0 {
            console.append("?")
            return
        }
        if mapped == 0x0D || mapped == 0x0A {
            flushConsole()
            return
        }
        if mapped == 0x08 || mapped == 0x09 { return }
        console.append(Character(UnicodeScalar(mapped)))
        if console.count >= 120 { flushConsole() }
    }

    private func diskXIO(_ address: Int, _ function: Int, _ modifier: Int) {
        // Sense stays clear so HOME can see an idle drive. Initiate read and
        // write complete immediately into the sector array.
        switch function {
        case 5, 6:
            let count = min(max(read(address), 0), 320)
            let sector = read(address + 1)
            if function == 6 {
                let data = sectors[sector] ?? Array(repeating: UInt16(0x4040), count: 320)
                for offset in 0..<count { write(address + 2 + offset, Int(data[offset])) }
            } else {
                var data = sectors[sector] ?? Array(repeating: UInt16(0x4040), count: 320)
                if data.count < 320 { data = Array(repeating: UInt16(0x4040), count: 320) }
                for offset in 0..<count {
                    data[offset] = UInt16(truncatingIfNeeded: read(address + 2 + offset))
                }
                sectors[sector] = data
            }
        default:
            acc = 0
        }
        _ = modifier
    }

    private func flushConsole() {
        let line = console.trimmingCharacters(in: .whitespaces)
        console = ""
        guard !line.isEmpty else { return }
        output.append(line)
        print(line)
        fflush(stdout)
    }

    /// One key from stdin. A whole line is accepted and then delivered a
    /// character at a time; return becomes the blank that ends a word.
    private func readKey() -> Int? {
        while pendingKeys.isEmpty {
            flushConsole()
            fflush(stdout)
            guard let line = readLine(strippingNewline: false) else { return nil }
            for byte in line.utf8 {
                if let code = consoleCode(Int(byte)) {
                    pendingKeys.append(code)
                }
            }
            if pendingKeys.last != 0 { pendingKeys.append(0) }
        }
        return pendingKeys.removeFirst()
    }

    /// ASCII to the 1130 keyboard codes in CSKB. Space, return and the
    /// blank code are 0, which CONVE maps to a Forth blank.
    private func consoleCode(_ ascii: Int) -> Int? {
        if ascii == 0x0A || ascii == 0x0D || ascii == 0x20 { return 0 }
        guard ascii >= 0 && ascii < Machine.consoleInput.count else { return nil }
        let raw = Int(Machine.consoleInput[ascii])
        if raw == 0 { return nil }
        return raw & 0xFFFE
    }

    /// `ascii_to_conin` from the 1130 console. A zero entry is not a key.
    private static let consoleInput: [UInt16] = [
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0004, 0x0000, 0x0000, 0x0000, 0x0000, 0x0008, 0x0000, 0x0000,
        0x0000, 0x0000, 0x8820, 0x0000, 0x0000, 0x0002, 0x0000, 0x0000,
        0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
        0x0001, 0x4820, 0x0060, 0x0420, 0x4420, 0x2220, 0x8000, 0x0120,
        0x8120, 0x4120, 0x4220, 0x80A0, 0x2420, 0x4000, 0x8420, 0x3000,
        0x2000, 0x1000, 0x0800, 0x0400, 0x0200, 0x0100, 0x0080, 0x0040,
        0x0020, 0x0010, 0x0820, 0x40A0, 0x8220, 0x00A0, 0x20A0, 0x2060,
        0x0220, 0x9000, 0x8800, 0x8400, 0x8200, 0x8100, 0x8080, 0x8040,
        0x8020, 0x8010, 0x5000, 0x4800, 0x4400, 0x4200, 0x4100, 0x4080,
        0x4040, 0x4020, 0x4010, 0x2800, 0x2400, 0x2200, 0x2100, 0x2080,
        0x2040, 0x2020, 0x2010, 0x0000, 0x0000, 0x0000, 0x0000, 0x2120,
        0x0000, 0x9000, 0x8800, 0x8400, 0x8200, 0x8100, 0x8080, 0x8040,
        0x8020, 0x8010, 0x5000, 0x4800, 0x4400, 0x4200, 0x4100, 0x4080,
        0x4040, 0x4020, 0x4010, 0x2800, 0x2400, 0x2200, 0x2100, 0x2080,
        0x2040, 0x2020, 0x2010, 0x0000, 0xB060, 0x0000, 0x0000, 0x0004,
    ]

    private func noteAccepted() {
        let index = read(workspaceA)
        let character: Character
        if index >= 0 && index < forthCharacter.count {
            character = forthCharacter[index]
        } else {
            character = "?"
        }
        accepted.append(character)
        acceptColumn += 1
        if acceptColumn == 72 {
            acceptColumn = 0
            accepted.append("\n")
        }
    }

    // MARK: Disk image

    /// Eight 80-character records per 320-word sector. The kernel reads the
    /// last record first and word-reverses it in FIXUP, so line 1 of a sector
    /// is stored reversed in the last 40 words.
    private static func packSource(_ text: String, encode: [Character: Int]) -> [Int: [UInt16]] {
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        var sectors: [Int: [UInt16]] = [:]
        for (index, line) in lines.enumerated() {
            var chars = Array(line.prefix(72))
            if chars.count > 72 { chars = Array(chars.prefix(72)) }
            while chars.count < 80 { chars.append(" ") }
            var words = [UInt16](repeating: 0x4040, count: 40)
            for word in 0..<40 {
                let high = encode[chars[word * 2]] ?? 0x40
                let low = encode[chars[word * 2 + 1]] ?? 0x40
                words[word] = UInt16((high << 8) | low)
            }
            let sector = 0x10EE + index / 8
            var data = sectors[sector] ?? Array(repeating: UInt16(0x4040), count: 320)
            let base = (7 - index % 8) * 40
            let stored = Array(words.reversed())
            for word in 0..<40 { data[base + word] = stored[word] }
            sectors[sector] = data
        }
        return sectors
    }

    private func decodeWords(_ words: [UInt16], count: Int) -> String {
        var text = ""
        for word in words.prefix(count) {
            let high = Int(word >> 8)
            let low = Int(word & 0xFF)
            text.append(asciiOfEbcdic[high] ?? " ")
            text.append(asciiOfEbcdic[low] ?? " ")
        }
        return text
    }

    /// The BCD table order. Index is the Forth character. The word is the
    /// input byte CONVE matches, which is what the disk must hold.
    private static func alphabet() -> (characters: [Character], encode: [Character: Int], decode: [Int: Character]) {
        var characters: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        characters.append(contentsOf: [
            " ", "\u{00A2}", "#", "<", "(", "+", "|", "&", "!", "$", "*", ")", ";", "\u{00AC}",
            "-", "/", ",", "%", "_", ">", "?", ":", ".", "@", "'", "=", "\"", " ",
        ])
        var codes: [Int] = []
        for digit in 0..<10 { codes.append(0xF0 + digit) }
        for letter in 0..<9 { codes.append(0xC1 + letter) }
        for letter in 0..<9 { codes.append(0xD1 + letter) }
        for letter in 0..<8 { codes.append(0xE2 + letter) }
        codes.append(contentsOf: [
            0x40, 0x4A, 0x7B, 0x4C, 0x4D, 0x4E, 0x4F, 0x50, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F,
            0x60, 0x61, 0x6B, 0x6C, 0x6D, 0x6E, 0x6F, 0x7A, 0x4B, 0x7C, 0x7D, 0x7E, 0x7F, 0x40,
        ])
        precondition(characters.count == 64 && codes.count == 64, "Forth alphabet is 64 characters")
        var encode: [Character: Int] = [:]
        var decode: [Int: Character] = [:]
        for index in 0..<64 where encode[characters[index]] == nil {
            encode[characters[index]] = codes[index]
            decode[codes[index]] = characters[index]
        }
        return (characters, encode, decode)
    }

    // MARK: Helpers

    private func noteAcceptedCheck() {}

    private func read(_ address: Int) -> Int {
        Int(memory[address & memoryMask])
    }

    private func write(_ address: Int, _ value: Int) {
        memory[address & memoryMask] = UInt16(truncatingIfNeeded: value)
    }

    private func sext8(_ value: Int) -> Int {
        let byte = value & 0xFF
        return byte & 0x80 != 0 ? byte - 256 : byte
    }

    private func remember(_ pc: Int, _ ir: Int) {
        trail[trailAt] = (pc, ir)
        trailAt = (trailAt + 1) % trail.count
        ring[ringAt] = pc
        ringAt = (ringAt + 1) % ring.count
    }

    private func hotspotLoop() -> Bool {
        let unique = Set(ring.filter { $0 >= 0 }).count
        if unique > 0 && unique <= 6 {
            hotspot += 1
        } else {
            hotspot = 0
        }
        return hotspot >= 40
    }
}
