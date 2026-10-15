// This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
// If a copy of the MPL was not distributed with this file, You can obtain one at
// https://mozilla.org/MPL/2.0/.

import Foundation

/// Valve KeyValues tree. PICS app info arrives as text, package info as binary.
/// Values are kept as strings (binary numbers are formatted in decimal), as in SteamKit2.
public struct KeyValue: Hashable, Sendable {
    public var name: String
    public var value: String?
    public var children: [KeyValue]

    public init(name: String, value: String? = nil, children: [KeyValue] = []) {
        self.name = name
        self.value = value
        self.children = children
    }

    /// First child with this name, compared case-insensitively as Steam does.
    public subscript(key: String) -> KeyValue? {
        children.first { $0.name.caseInsensitiveCompare(key) == .orderedSame }
    }

    /// Follows a path of child names, e.g. `kv[path: "common", "name"]`.
    public subscript(path keys: String...) -> KeyValue? {
        keys.reduce(Optional(self)) { $0?[$1] }
    }

    public var uint32: UInt32? { value.flatMap { UInt32($0) } }
    public var uint64: UInt64? { value.flatMap { UInt64($0) } }

    public enum ParseError: Error, Equatable {
        case unexpectedEnd
        case unexpectedToken(String)
        case unknownBinaryType(UInt8)
    }
}

// MARK: - Text

extension KeyValue {
    /// Parses a text KeyValues document and returns its root node.
    public static func parseText(_ text: String) throws -> KeyValue {
        var tokenizer = TextTokenizer(Array(text.unicodeScalars))
        guard case let .string(name)? = try tokenizer.next() else { throw ParseError.unexpectedEnd }
        guard try tokenizer.next() == .open else { throw ParseError.unexpectedToken(name) }
        return KeyValue(name: name, children: try parseTextChildren(&tokenizer))
    }

    /// Parses PICS app info, whose buffer is UTF-8 text with a trailing NUL.
    public static func parseText(_ data: Data) throws -> KeyValue {
        let trimmed = data.last == 0 ? data.dropLast() : data
        return try parseText(String(decoding: trimmed, as: UTF8.self))
    }

    private static func parseTextChildren(_ tokenizer: inout TextTokenizer) throws -> [KeyValue] {
        var children: [KeyValue] = []
        while true {
            switch try tokenizer.next() {
            case .close:
                return children
            case let .string(name):
                switch try tokenizer.next() {
                case .open:
                    children.append(KeyValue(name: name, children: try parseTextChildren(&tokenizer)))
                case let .string(value):
                    children.append(KeyValue(name: name, value: value))
                case .close, nil:
                    throw ParseError.unexpectedToken(name)
                }
            case .open:
                throw ParseError.unexpectedToken("{")
            case nil:
                throw ParseError.unexpectedEnd
            }
        }
    }

    private struct TextTokenizer {
        enum Token: Equatable { case open, close, string(String) }

        let scalars: [Unicode.Scalar]
        var index = 0

        init(_ scalars: [Unicode.Scalar]) { self.scalars = scalars }

        mutating func next() throws -> Token? {
            while index < scalars.count {
                let c = scalars[index]
                if c.properties.isWhitespace {
                    index += 1
                } else if c == "/", index + 1 < scalars.count, scalars[index + 1] == "/" {
                    while index < scalars.count, scalars[index] != "\n" { index += 1 }
                } else if c == "[" {
                    // Platform conditional such as [$WIN32]; SteamKit ignores these too.
                    while index < scalars.count, scalars[index] != "]" { index += 1 }
                    index += 1
                } else if c == "{" {
                    index += 1
                    return .open
                } else if c == "}" {
                    index += 1
                    return .close
                } else if c == "\"" {
                    index += 1
                    return .string(try readQuoted())
                } else {
                    return .string(readBare())
                }
            }
            return nil
        }

        private mutating func readQuoted() throws -> String {
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                index += 1
                if c == "\"" { return String(out) }
                if c == "\\", index < scalars.count {
                    let escaped = scalars[index]
                    index += 1
                    switch escaped {
                    case "n": out.append("\n")
                    case "t": out.append("\t")
                    case "\\", "\"": out.append(escaped)
                    default: out.append(c); out.append(escaped)
                    }
                } else {
                    out.append(c)
                }
            }
            throw ParseError.unexpectedEnd
        }

        private mutating func readBare() -> String {
            var out = String.UnicodeScalarView()
            while index < scalars.count {
                let c = scalars[index]
                if c.properties.isWhitespace || c == "{" || c == "}" || c == "\"" { break }
                out.append(c)
                index += 1
            }
            return String(out)
        }
    }
}

// MARK: - Binary

extension KeyValue {
    private enum BinaryType: UInt8 {
        case none = 0, string = 1, int32 = 2, float32 = 3, pointer = 4, wideString = 5
        case color = 6, uint64 = 7, end = 8, int64 = 10, alternateEnd = 11
    }

    /// Parses one binary KeyValues node (type byte, name, contents) from the reader.
    static func parseBinary(_ reader: inout ByteReader) throws -> KeyValue {
        let rawType = try reader.readUInt8()
        guard let type = BinaryType(rawValue: rawType), type == .none else {
            throw ParseError.unknownBinaryType(rawType)
        }
        return KeyValue(name: try reader.readCString(), children: try parseBinaryChildren(&reader))
    }

    /// Parses PICS package info: a u32 (always 1) followed by one binary KeyValues node.
    public static func parsePackageInfo(_ data: Data) throws -> KeyValue {
        var reader = ByteReader(data)
        _ = try reader.readUInt32LE()
        return try parseBinary(&reader)
    }

    private static func parseBinaryChildren(_ reader: inout ByteReader) throws -> [KeyValue] {
        var children: [KeyValue] = []
        while true {
            let rawType = try reader.readUInt8()
            guard let type = BinaryType(rawValue: rawType) else { throw ParseError.unknownBinaryType(rawType) }
            if type == .end || type == .alternateEnd { return children }

            let name = try reader.readCString()
            switch type {
            case .none:
                children.append(KeyValue(name: name, children: try parseBinaryChildren(&reader)))
            case .string:
                children.append(KeyValue(name: name, value: try reader.readCString()))
            case .int32, .color, .pointer:
                children.append(KeyValue(name: name, value: String(Int32(bitPattern: try reader.readUInt32LE()))))
            case .uint64:
                children.append(KeyValue(name: name, value: String(try reader.readUInt64LE())))
            case .int64:
                children.append(KeyValue(name: name, value: String(Int64(bitPattern: try reader.readUInt64LE()))))
            case .float32:
                children.append(KeyValue(name: name, value: String(Float(bitPattern: try reader.readUInt32LE()))))
            case .wideString, .end, .alternateEnd:
                throw ParseError.unknownBinaryType(rawType)
            }
        }
    }

    /// Binary encoding as SteamKit2 writes it: only child nodes and string values are
    /// supported, and the document is closed with an extra end marker.
    func binaryEncoded() -> Data {
        var out = Data()
        appendBinary(to: &out)
        out.append(BinaryType.end.rawValue)
        return out
    }

    private func appendBinary(to out: inout Data) {
        if let value {
            out.append(BinaryType.string.rawValue)
            out.appendCString(name)
            out.appendCString(value)
        } else {
            out.append(BinaryType.none.rawValue)
            out.appendCString(name)
            for child in children { child.appendBinary(to: &out) }
            out.append(BinaryType.end.rawValue)
        }
    }
}
