import Foundation

/// Bounded adaptation of HLSL scalar splats and vector truncation. Authored
/// expressions are rewritten only when their numeric dimensions are known.
/// Arrays, macros, structures, ambiguous declarations and unknown expressions
/// remain unchanged, so the GLSL compiler can report unsupported constructs.
/// Dimension rules: microsoft.github.io/hlsl-specs/specs/5-Expr.html.
enum NativeShaderVectorExpressions {
    static func adapt(_ source: String) throws -> String {
        let comments = try NSRegularExpression(pattern: #"//[^\n\r]*|/\*[\s\S]*?\*/|(?m)^[ \t]*#[^\n\r]*"#)
        let masked = NSMutableString(string: source)
        for match in comments.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            masked.replaceCharacters(in: match.range, with: String(repeating: " ", count: match.range.length))
        }
        let code = masked as String, ns = code as NSString
        let declaration = try NSRegularExpression(pattern: #"\b(float|int|uint|bool|[uib]?vec[234]|mat[234](?:x[234])?|sampler\w+)\s+([A-Za-z_][A-Za-z0-9_]*)\b"#)
        var declared: [String: Set<String>] = [:]
        let numericDimensions = ["float": 1, "vec2": 2, "vec3": 3, "vec4": 4]
        var declarationDimensions: [Int: Int] = [:]
        for match in declaration.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            let type = ns.substring(with: match.range(at: 1))
            declared[ns.substring(with: match.range(at: 2)), default: []].insert(type)
            declarationDimensions[match.range(at: 2).location] = numericDimensions[type]
        }
        var dimensions: [String: Int] = ["gl_FragColor": 4, "gl_Position": 4]
        var samplerDimensions: [String: Int] = [:]
        for (name, types) in declared where types.count == 1 {
            if let type = types.first, let dimension = numericDimensions[type] { dimensions[name] = dimension }
            if let type = types.first, type.hasPrefix("sampler") {
                samplerDimensions[name] = type.hasSuffix("Shadow") ? 1 : 4
            }
        }
        // This includes initialized declarations and direct/swizzled assignments.
        // Only the RHS is replaced; qualifiers, comments and declarations survive.
        let assignments = try NSRegularExpression(pattern: #"\b([A-Za-z_][A-Za-z0-9_]*)(?:\s*\.\s*([xyzwrgbastpq]{1,4}))?\s*=(?!=)\s*([^;{}#]{1,4096});"#)
        let result = NSMutableString(string: source)
        for match in assignments.matches(in: code, range: NSRange(code.startIndex..., in: code)).reversed() {
            let name = ns.substring(with: match.range(at: 1))
            // An initializer has an unambiguous target type at this exact
            // declaration even if another function reuses its variable name.
            // Later assignments and RHS lookup still require an unambiguous
            // symbol; this adapter does not pretend to resolve lexical scopes.
            guard let declaredDimension = declarationDimensions[match.range(at: 1).location] ?? dimensions[name] else { continue }
            let swizzle = match.range(at: 2).location == NSNotFound ? nil : ns.substring(with: match.range(at: 2))
            let target = swizzle?.count ?? declaredDimension
            let expression = ns.substring(with: match.range(at: 3))
            guard var parser = try Parser(expression, dimensions: dimensions, samplerDimensions: samplerDimensions), var value = parser.parse(), let dimension = value.dimension else { continue }
            if dimension != target {
                guard dimension > target || dimension == 1 else { continue }
                value = value.converted(to: target)
            }
            if value.changed { result.replaceCharacters(in: match.range(at: 3), with: value.text) }
        }
        return result as String
    }

    private struct Value {
        let text: String
        let dimension: Int?
        var changed = false
        func converted(to target: Int) -> Value {
            if dimension == target { return self }
            return Value(text: target == 1 ? "(\(text)).x" : "vec\(target)(\(text))", dimension: target, changed: true)
        }
    }

    private struct Parser {
        let tokens: [String]
        let dimensions: [String: Int]
        let samplerDimensions: [String: Int]
        var index = 0
        init?(_ expression: String, dimensions: [String: Int], samplerDimensions: [String: Int]) throws {
            let token = try NSRegularExpression(pattern: #"\s*([A-Za-z_][A-Za-z0-9_]*|(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?[fF]?|[().,+*/\-])"#)
            let ns = expression as NSString
            var offset = 0, values: [String] = []
            while offset < ns.length {
                if ns.substring(from: offset).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
                guard values.count < 512, let match = token.firstMatch(in: expression, options: .anchored, range: NSRange(location: offset, length: ns.length - offset)) else { return nil }
                values.append(ns.substring(with: match.range(at: 1))); offset = NSMaxRange(match.range)
            }
            tokens = values; self.dimensions = dimensions; self.samplerDimensions = samplerDimensions
        }
        mutating func parse() -> Value? {
            guard let value = expression(precedence: 0, depth: 0), index == tokens.count else { return nil }
            return value
        }
        mutating func expression(precedence: Int, depth: Int) -> Value? {
            guard depth < 48, var left = primary(depth: depth + 1) else { return nil }
            while index < tokens.count {
                let operation = tokens[index]
                guard let next = ["+": 1, "-": 1, "*": 2, "/": 2][operation], next >= precedence else { break }
                index += 1
                guard var right = expression(precedence: next + 1, depth: depth + 1), let a = left.dimension, let b = right.dimension else { return nil }
                let dimension = a == 1 ? b : b == 1 ? a : min(a, b)
                // GLSL already broadcasts scalar arithmetic. Only mismatched
                // vectors require an explicit dimension conversion here.
                if a > 1 && b > 1 && a != b { left = left.converted(to: dimension); right = right.converted(to: dimension) }
                left = Value(text: "(\(left.text) \(operation) \(right.text))", dimension: dimension, changed: left.changed || right.changed)
            }
            return left
        }
        mutating func primary(depth: Int) -> Value? {
            guard depth < 48, index < tokens.count else { return nil }
            let token = tokens[index]; index += 1
            var value: Value
            if token == "(" {
                guard let nested = expression(precedence: 0, depth: depth + 1), consume(")") else { return nil }
                value = Value(text: "(\(nested.text))", dimension: nested.dimension, changed: nested.changed)
            } else if token == "+" || token == "-" {
                guard let nested = primary(depth: depth + 1) else { return nil }
                value = Value(text: "(\(token)\(nested.text))", dimension: nested.dimension, changed: nested.changed)
            } else if index < tokens.count && tokens[index] == "(" {
                index += 1
                var arguments: [Value] = []
                if !consume(")") {
                    repeat {
                        guard arguments.count < 16, let argument = expression(precedence: 0, depth: depth + 1) else { return nil }
                        arguments.append(argument)
                    } while consume(",")
                    guard consume(")") else { return nil }
                }
                let dimension: Int?
                if let size = ["float": 1, "vec2": 2, "vec3": 3, "vec4": 4, "CAST2": 2, "CAST3": 3, "CAST4": 4][token] { dimension = size }
                else if token == "texSample2D" { dimension = 4 }
                else if ["texture", "texture2D"].contains(token) {
                    // Shadow comparisons return a scalar. Ambiguous sampler
                    // declarations remain unchanged for the GLSL compiler.
                    dimension = arguments.first.flatMap { samplerDimensions[$0.text] }
                }
                else if ["length", "dot", "distance", "greyscale"].contains(token) { dimension = 1 }
                else if ["rgb2hsv", "hsv2rgb"].contains(token) { dimension = 3 }
                else if ["abs", "sign", "floor", "ceil", "fract", "frac", "sin", "cos", "tan", "asin", "acos", "atan", "exp", "exp2", "log", "log2", "sqrt", "inversesqrt", "normalize", "saturate"].contains(token), arguments.count == 1 { dimension = arguments[0].dimension }
                else if ["min", "max", "pow", "mix", "lerp", "clamp", "smoothstep", "step"].contains(token), !arguments.isEmpty, arguments.allSatisfy({ $0.dimension != nil }) {
                    let vectors = arguments.compactMap(\.dimension).filter { $0 > 1 }
                    dimension = vectors.min() ?? 1
                    if let dimension, dimension > 1 {
                        // A scalar interpolation amount can remain scalar in GLSL.
                        for i in arguments.indices where !(i == 2 && ["mix", "lerp"].contains(token) && arguments[i].dimension == 1) {
                            if arguments[i].dimension != dimension { arguments[i] = arguments[i].converted(to: dimension) }
                        }
                    }
                } else { dimension = nil }
                value = Value(text: "\(token)(\(arguments.map(\.text).joined(separator: ", ")))", dimension: dimension, changed: arguments.contains(where: \.changed))
            } else if let dimension = dimensions[token] { value = Value(text: token, dimension: dimension) }
            else {
                let raw = token.hasSuffix("f") || token.hasSuffix("F") ? String(token.dropLast()) : token
                value = Value(text: token, dimension: Double(raw).map { $0.isFinite ? 1 : nil } ?? nil)
            }
            while consume(".") {
                guard index < tokens.count else { return nil }
                let swizzle = tokens[index]; index += 1
                guard (1...4).contains(swizzle.count), ["xyzw", "rgba", "stpq"].contains(where: { alphabet in swizzle.allSatisfy { alphabet.contains($0) } }) else { return nil }
                value = Value(text: "(\(value.text)).\(swizzle)", dimension: swizzle.count, changed: value.changed)
            }
            return value
        }
        mutating func consume(_ token: String) -> Bool {
            guard index < tokens.count, tokens[index] == token else { return false }
            index += 1; return true
        }
    }
}
