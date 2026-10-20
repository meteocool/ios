//
//  CoreStrings.swift
//  meteocool
//
//  core's UI strings, as the native map shows them.
//

import Foundation

/// What core's web map says, in the same words and languages: the `Core`
/// table, generated from core's `src/locale` by `scripts/core-strings.py`.
///
/// No app dependencies here: `scripts/check.sh` compiles this file alone.
enum CoreStrings {
    /// core's message `key` (dotted, as in core's `$_("compare.models")`),
    /// formatted with `args`.
    static func t(_ key: String, _ args: [String: Any] = [:]) -> String {
        let message = Bundle.main.localizedString(forKey: key, value: nil, table: "Core")
        return ICUMessage.format(message, args, language: language)
    }

    /// The language the app's strings are shown in.
    static var language: String {
        Bundle.main.preferredLocalizations.first.map { String($0.prefix(2)) } ?? "en"
    }
}

/// The part of ICU's message format core's strings use: `{name}`,
/// `{n, plural, =0 {…} one {# thing} few {…} other {…}}` and
/// `{x, select, a {…} other {…}}`, nested.
enum ICUMessage {
    static func format(_ message: String, _ args: [String: Any], language: String) -> String {
        var parser = Parser(chars: Array(message), args: args, language: language)
        return parser.message(until: nil, number: nil)
    }

    /// CLDR's cardinal plural category of `n` (integers; core passes counts).
    static func category(_ n: Double, language: String) -> String {
        guard n.rounded() == n, abs(n) < 1e15 else { return language == "lt" ? "many" : "other" }
        let i = Int(abs(n))
        switch language {
        case "hr":
            if i % 10 == 1 && i % 100 != 11 { return "one" }
            if (2 ... 4).contains(i % 10) && !(12 ... 14).contains(i % 100) { return "few" }
            return "other"
        case "lt":
            if i % 10 == 1 && !(11 ... 19).contains(i % 100) { return "one" }
            if (2 ... 9).contains(i % 10) && !(11 ... 19).contains(i % 100) { return "few" }
            return "other"
        default:
            return i == 1 ? "one" : "other"
        }
    }

    private struct Parser {
        let chars: [Character]
        let args: [String: Any]
        let language: String
        var at = 0

        init(chars: [Character], args: [String: Any], language: String) {
            (self.chars, self.args, self.language) = (chars, args, language)
        }

        /// Text up to `end` (a closing brace of a sub-message) or the end.
        /// `number` is what `#` stands for inside a plural's case.
        mutating func message(until end: Character?, number: Double?) -> String {
            var out = ""
            while at < chars.count {
                let c = chars[at]
                if let end, c == end { return out }
                if c == "{" {
                    at += 1
                    out += argument()
                } else if c == "#", let number {
                    out += Self.text(number)
                    at += 1
                } else {
                    out.append(c)
                    at += 1
                }
            }
            return out
        }

        /// After `{`: `name}`, or `name, plural|select, cases}`.
        mutating func argument() -> String {
            let name = word(stoppingAt: [",", "}"])
            guard at < chars.count else { return "" }
            if chars[at] == "}" {
                at += 1
                return args[name].map(Self.text) ?? "{\(name)}"
            }
            at += 1 // ","
            let kind = word(stoppingAt: [",", "}"])
            if at < chars.count, chars[at] == "," { at += 1 }
            var cases: [String: (start: Int, end: Int)] = [:]
            var order: [String] = []
            while at < chars.count {
                skipSpaces()
                if at < chars.count, chars[at] == "}" { at += 1; break }
                let selector = word(stoppingAt: ["{"])
                guard at < chars.count, chars[at] == "{" else { break }
                at += 1
                let start = at
                var depth = 1
                while at < chars.count, depth > 0 {
                    if chars[at] == "{" { depth += 1 } else if chars[at] == "}" { depth -= 1 }
                    at += 1
                }
                cases[selector] = (start, at - 1)
                order.append(selector)
            }
            let value = args[name]
            let chosen: String?
            var number: Double?
            switch kind {
            case "plural":
                let n = Self.number(value) ?? 0
                number = n
                chosen = cases["=\(Self.text(n))"] != nil ? "=\(Self.text(n))" : ICUMessage.category(n, language: language)
            case "select":
                chosen = value.map(Self.text)
            default:
                // number, date, …: the value as it is.
                return value.map(Self.text) ?? ""
            }
            guard let range = chosen.flatMap({ cases[$0] }) ?? cases["other"] ?? order.first.flatMap({ cases[$0] }) else { return "" }
            var sub = Parser(chars: Array(chars[range.start ..< range.end]), args: args, language: language)
            return sub.message(until: nil, number: number)
        }

        mutating func word(stoppingAt stops: Set<Character>) -> String {
            var word = ""
            while at < chars.count, !stops.contains(chars[at]) {
                word.append(chars[at])
                at += 1
            }
            return word.trimmingCharacters(in: .whitespaces)
        }

        mutating func skipSpaces() {
            while at < chars.count, chars[at].isWhitespace { at += 1 }
        }

        static func number(_ value: Any?) -> Double? {
            switch value {
            case let v as Int: return Double(v)
            case let v as Double: return v
            case let v as Float: return Double(v)
            case let v as NSNumber: return v.doubleValue
            case let v as String: return Double(v)
            default: return nil
            }
        }

        static func text(_ value: Any) -> String {
            if let n = number(value), !(value is String) {
                return n.rounded() == n && abs(n) < 1e15 ? String(Int(n)) : String(n)
            }
            return String(describing: value)
        }
    }
}
