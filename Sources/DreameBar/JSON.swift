import Foundation

/// Minimal JSON value with a serializer that matches Python's `json.dumps`,
/// because the Dreame request signature is computed over that exact text.
enum JSON: Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case array([JSON])
    case object([String: JSON])

    init(any value: Any?) {
        switch value {
        case nil, is NSNull: self = .null
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID(): self = .bool(n.boolValue)
        case let n as NSNumber:
            if CFNumberIsFloatType(n) { self = .double(n.doubleValue) } else { self = .int(n.intValue) }
        case let s as String: self = .string(s)
        case let a as [Any]: self = .array(a.map { JSON(any: $0) })
        case let d as [String: Any]: self = .object(d.mapValues { JSON(any: $0) })
        default: self = .null
        }
    }

    static func parse(_ data: Data) -> JSON? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSON(any: obj)
    }

    subscript(key: String) -> JSON? {
        if case .object(let d) = self { return d[key] }
        return nil
    }

    subscript(index: Int) -> JSON? {
        if case .array(let a) = self, a.indices.contains(index) { return a[index] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var array: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSON]? { if case .object(let d) = self { return d }; return nil }
    var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    /// Python `json.dumps(v, separators=(",", ":"), sort_keys=sortKeys, ensure_ascii=False)`.
    func dumps(sortKeys: Bool = false, compact: Bool = true) -> String {
        let comma = compact ? "," : ", "
        let colon = compact ? ":" : ": "
        switch self {
        case .string(let s): return JSON.quote(s)
        case .int(let i): return String(i)
        case .double(let d): return d == d.rounded() && abs(d) < 1e16 ? String(format: "%.1f", d) : String(d)
        case .bool(let b): return b ? "true" : "false"
        case .null: return "null"
        case .array(let a): return "[" + a.map { $0.dumps(sortKeys: sortKeys, compact: compact) }.joined(separator: comma) + "]"
        case .object(let d):
            let keys = sortKeys ? d.keys.sorted() : Array(d.keys)
            return "{" + keys.map { JSON.quote($0) + colon + d[$0]!.dumps(sortKeys: sortKeys, compact: compact) }.joined(separator: comma) + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(arrayLiteral elements: JSON...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}
