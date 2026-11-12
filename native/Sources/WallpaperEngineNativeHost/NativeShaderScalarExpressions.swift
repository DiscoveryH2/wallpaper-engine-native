import Foundation

/// A bounded subset of scalar HLSL-style arithmetic, used only for declarations
/// containing %. Unknown names, calls, arrays and ambiguous types remain untouched
/// and retain the shader compiler's diagnostic. This is not a full type checker.
enum NativeShaderScalarExpressions {
    static func adaptRemainderDeclarations(_ source: String, combos: [String: Int]) throws -> String {
        let comments = try NSRegularExpression(pattern: #"//[^\n\r]*|/\*[\s\S]*?\*/"#)
        let masked = NSMutableString(string: source)
        for match in comments.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            // Preserve UTF-16 offsets into the original shader.
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        let code = masked as String, ns = code as NSString
        let declarations = try NSRegularExpression(pattern: #"\b(float|int|uint|bool|[uib]?vec[234]|mat[234](?:x[234])?|sampler\w+)\s+([A-Za-z_][A-Za-z0-9_]*)\b"#)
        var declarationsByName: [String: Set<String>] = [:]
        for match in declarations.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            declarationsByName[ns.substring(with: match.range(at: 2)), default: []].insert(ns.substring(with: match.range(at: 1)))
        }
        var types: [String: String] = [:]
        for (name, declared) in declarationsByName where declared.count == 1 {
            if let type = declared.first, ["float", "int", "uint"].contains(type) { types[name] = type }
        }
        for name in combos.keys where declarationsByName[name] == nil { types[name] = "int" }

        let pattern = try NSRegularExpression(pattern: #"\b(int|uint|float)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*([^;{}\n\r#]{1,2048});"#)
        let result = NSMutableString(string: source)
        for match in pattern.matches(in: code, range: NSRange(code.startIndex..., in: code)).reversed() {
            let expression = ns.substring(with: match.range(at: 3))
            guard expression.contains("%"), var parser = try Parser(expression, types: types), let value = parser.parse() else { continue }
            let type = ns.substring(with: match.range(at: 1)), name = ns.substring(with: match.range(at: 2))
            result.replaceCharacters(in: match.range, with: "\(type) \(name) = \(value.cast(to: type));")
        }
        return result as String
    }

    private struct Value {
        var text: String
        let type: String
        func cast(to target: String) -> String { target == type ? text : "\(target)(\(text))" }
    }

    private struct Parser {
        let tokens: [String]
        let types: [String: String]
        var index = 0
        init?(_ expression: String, types: [String: String]) throws {
            let token = try NSRegularExpression(pattern: #"\s*([A-Za-z_][A-Za-z0-9_]*|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?[uUfF]?|[()+*/%\-])"#)
            let ns = expression as NSString
            var offset = 0, values: [String] = []
            while offset < ns.length {
                if ns.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                guard values.count < 256, let match = token.firstMatch(in: expression, options: .anchored, range: NSRange(location: offset, length: ns.length - offset)) else { return nil }
                values.append(ns.substring(with: match.range(at: 1))); offset = NSMaxRange(match.range)
            }
            tokens = values; self.types = types
        }
        mutating func parse() -> Value? {
            guard let result = expression(minimumPrecedence: 0, depth: 0), index == tokens.count else { return nil }
            return result
        }
        mutating func expression(minimumPrecedence: Int, depth: Int) -> Value? {
            guard depth < 48, var left = primary(depth: depth + 1) else { return nil }
            while index < tokens.count {
                let operation = tokens[index]
                let precedence: Int
                switch operation { case "+", "-": precedence = 1; case "*", "/", "%": precedence = 2; default: return left }
                if precedence < minimumPrecedence { return left }
                index += 1
                guard let right = expression(minimumPrecedence: precedence + 1, depth: depth + 1) else { return nil }
                // These are only the 32-bit scalar types: float has precedence,
                // then uint, then int. Both operands get explicit constructors.
                let type = left.type == "float" || right.type == "float" ? "float" : left.type == "uint" || right.type == "uint" ? "uint" : "int"
                let a = left.cast(to: type), b = right.cast(to: type)
                let text = operation == "%" && type == "float" ? "weNativeRemainder(\(a), \(b))" : "(\(a) \(operation) \(b))"
                left = Value(text: text, type: type)
            }
            return left
        }
        mutating func primary(depth: Int) -> Value? {
            guard depth < 48, index < tokens.count else { return nil }
            let token = tokens[index]; index += 1
            if token == "(" {
                guard let value = expression(minimumPrecedence: 0, depth: depth + 1), index < tokens.count, tokens[index] == ")" else { return nil }
                index += 1; return value
            }
            if token == "+" || token == "-" {
                guard var value = primary(depth: depth + 1) else { return nil }
                value.text = "(\(token)\(value.text))"; return value
            }
            if let type = types[token] { return Value(text: token, type: type) }
            if token.hasSuffix("u") || token.hasSuffix("U") {
                guard UInt32(token.dropLast()) != nil else { return nil }
                return Value(text: String(token.dropLast()) + "u", type: "uint")
            }
            let raw = token.hasSuffix("f") || token.hasSuffix("F") ? String(token.dropLast()) : token
            guard let number = Double(raw), number.isFinite else { return nil }
            let floating = raw.contains(".") || raw.lowercased().contains("e") || raw != token
            if !floating && Int32(raw) == nil { return nil }
            return Value(text: floating && !raw.contains(".") && !raw.lowercased().contains("e") ? raw + ".0" : raw, type: floating ? "float" : "int")
        }
    }
}
