import Foundation

enum ScriptFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
}

struct Token { let word: String; let start: Int; let end: Int; let depth: Int; var literal: String? = nil }

private struct ScriptTemplateFrame {
    var inText = true
    var expressionBaseDepth = 0
}

/// A deliberately bounded module adapter, not a JavaScript-to-JavaScript regex.
/// Static built-in imports are supplied as lexical function parameters; only the
/// validated import declaration and export keyword spans are blanked. All other
/// JavaScript bytes reach the system parser unchanged.
func lowerModule(_ source: String, inspect: (([String], [String]) throws -> Void)? = nil) throws -> (String, [String], [[String: String]]) {
    var bytes = Array(source.utf8)
    var tokens: [Token] = []
    var index = 0, depth = 0
    var expressionStart = true
    var templates: [ScriptTemplateFrame] = []
    var controlParens: [Bool] = []
    func identifier(_ byte: UInt8) -> Bool {
        byte >= 128 || byte == 95 || byte == 36 || (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
    }
    while index < bytes.count {
        let byte = bytes[index]
        if !templates.isEmpty && templates[templates.count - 1].inText {
            if byte == 92 {
                guard index + 1 < bytes.count else { throw ScriptFailure.invalid("Unterminated script template") }
                index += 2
            } else if byte == 96 {
                tokens.append(Token(word: "template-end", start: index, end: index + 1, depth: depth))
                index += 1; templates.removeLast(); expressionStart = false
            } else if byte == 36 && index + 1 < bytes.count && bytes[index + 1] == 123 {
                templates[templates.count - 1].inText = false
                templates[templates.count - 1].expressionBaseDepth = depth
                depth += 1
                tokens.append(Token(word: "template-expression", start: index, end: index + 2, depth: depth))
                index += 2; expressionStart = true
            } else { index += 1 }
            continue
        }
        if byte == 125, let frame = templates.last, !frame.inText, depth == frame.expressionBaseDepth + 1 {
            depth -= 1
            templates[templates.count - 1].inText = true
            tokens.append(Token(word: "template-expression-end", start: index, end: index + 1, depth: depth))
            index += 1; expressionStart = false; continue
        }
        if [9,10,13,32].contains(byte) { index += 1; continue }
        if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 47 {
            index += 2
            while index < bytes.count && bytes[index] != 10 { index += 1 }
            continue
        }
        if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
            index += 2
            while index + 1 < bytes.count && !(bytes[index] == 42 && bytes[index + 1] == 47) { index += 1 }
            guard index + 1 < bytes.count else { throw ScriptFailure.invalid("Unterminated script comment") }
            index += 2; continue
        }
        if byte == 39 || byte == 34 {
            let start = index
            let quote = byte; index += 1
            var closed = false
            while index < bytes.count {
                if bytes[index] == 92 { index += 2; continue }
                if bytes[index] == quote { index += 1; closed = true; break }
                index += 1
            }
            guard closed else { throw ScriptFailure.invalid("Unterminated script string") }
            let raw = String(decoding: bytes[(start + 1)..<(index - 1)], as: UTF8.self)
            tokens.append(Token(word: "string", start: start, end: index, depth: depth, literal: raw))
            expressionStart = false; continue
        }
        if byte == 96 {
            guard templates.count < 128 else { throw ScriptFailure.invalid("Script template nesting exceeds 128 levels") }
            tokens.append(Token(word: "template-start", start: index, end: index + 1, depth: depth))
            templates.append(ScriptTemplateFrame()); index += 1; continue
        }
        if byte == 47 && !expressionStart, let frame = templates.last, !frame.inText, tokens.last?.word == "}" {
            // A closing brace can end an object expression or a statement
            // block. Without a complete JS parser, guessing here could treat
            // characters inside a regex as the end of ${...}, hiding later
            // identifiers from the Metal compatibility check.
            throw ScriptFailure.invalid("Ambiguous slash after a closing brace in a template expression")
        }
        if byte == 47 && expressionStart, let frame = templates.last, !frame.inText,
           let previous = tokens.last?.word, ["await", "yield", "of"].contains(previous) {
            // These words can also be identifiers in a non-module function.
            // Avoid guessing whether this slash starts a regex or division.
            throw ScriptFailure.invalid("Ambiguous slash after an identifier in a template expression")
        }
        if byte == 47 && expressionStart {
            index += 1
            var inClass = false, closed = false
            while index < bytes.count {
                let current = bytes[index]
                if current == 92 { index += 2; continue }
                if current == 91 { inClass = true }
                if current == 93 { inClass = false }
                if current == 47 && !inClass { index += 1; closed = true; break }
                if current == 10 || current == 13 { break }
                index += 1
            }
            guard closed else { throw ScriptFailure.invalid("Unterminated script regular expression") }
            while index < bytes.count && identifier(bytes[index]) { index += 1 }
            expressionStart = false; continue
        }
        let start = index
        if identifier(byte) {
            index += 1
            while index < bytes.count && identifier(bytes[index]) { index += 1 }
            let word = String(decoding: bytes[start..<index], as: UTF8.self)
            let propertyName = tokens.last?.word == "."
            tokens.append(Token(word: word, start: start, end: index, depth: depth))
            expressionStart = !propertyName && ["return", "throw", "case", "delete", "void", "typeof", "yield", "new", "in", "of", "instanceof", "await", "else", "do"].contains(word)
        } else {
            if (byte == 43 || byte == 45), index + 1 < bytes.count, bytes[index + 1] == byte {
                // Prefix ++/-- still expects an operand; postfix ++/-- ends one.
                index += 2
                tokens.append(Token(word: String(decoding: bytes[start..<index], as: UTF8.self), start: start, end: index, depth: depth))
                continue
            }
            var closesControl = false
            if byte == 40 {
                let previous = tokens.last?.word ?? ""
                let before = tokens.count > 1 ? tokens[tokens.count - 2].word : ""
                let control = ["if", "while", "for", "with", "switch", "catch"].contains(previous) && before != "."
                controlParens.append(control || (previous == "await" && before == "for"))
            } else if byte == 41 { closesControl = controlParens.popLast() ?? false }
            if byte == 123 { depth += 1 }
            if byte == 125 { depth -= 1 }
            guard depth >= 0 else { throw ScriptFailure.invalid("Unbalanced script braces") }
            index += 1
            tokens.append(Token(word: String(decoding: [byte], as: UTF8.self), start: start, end: index, depth: depth))
            expressionStart = closesControl || ![41,93,125,46].contains(byte)
        }
    }
    guard templates.isEmpty else { throw ScriptFailure.invalid("Unterminated script template") }
    guard depth == 0 else { throw ScriptFailure.invalid("Unbalanced script braces") }
    var exports: [String] = []
    var imports: [[String: String]] = []
    var importedNames = Set<String>()
    func isName(_ text: String) -> Bool {
        let chars = Array(text.utf8)
        return chars.first.map { identifier($0) && !(48...57).contains($0) } == true && chars.allSatisfy(identifier)
    }
    func blank(_ start: Int, _ end: Int) {
        for position in start..<end where bytes[position] != 10 && bytes[position] != 13 { bytes[position] = 32 }
    }
    var tokenIndex = 0
    while tokenIndex < tokens.count {
        let token = tokens[tokenIndex]
        // Property names are not module declarations.
        let previous = tokenIndex > 0 ? tokens[tokenIndex - 1].word : ""
        let next = tokenIndex + 1 < tokens.count ? tokens[tokenIndex + 1].word : ""
        if token.literal != nil || previous == "." || next == ":" { tokenIndex += 1; continue }
        if token.word == "import" {
            guard token.depth == 0 else { throw ScriptFailure.invalid("Only top-level static built-in imports are implemented") }
            var cursor = tokenIndex + 1
            var names: [(member: String, local: String)] = []
            func word(_ offset: Int = 0) -> String { cursor + offset < tokens.count ? tokens[cursor + offset].word : "" }
            if word() == "*" && word(1) == "as" && isName(word(2)) {
                names.append(("*", word(2))); cursor += 3
            } else if word() == "{" {
                cursor += 1
                while word() != "}" {
                    guard cursor < tokens.count, isName(word()) else { throw ScriptFailure.invalid("Invalid named built-in import") }
                    let member = word(); cursor += 1
                    var local = member
                    if word() == "as" {
                        cursor += 1
                        guard isName(word()) else { throw ScriptFailure.invalid("Invalid built-in import alias") }
                        local = word(); cursor += 1
                    }
                    names.append((member, local))
                    if word() == "," { cursor += 1 }
                    else if word() != "}" { throw ScriptFailure.invalid("Unsupported built-in import declaration") }
                }
                cursor += 1
            } else { throw ScriptFailure.invalid("Use a namespace or named import from WEMath, WEColor or WEVector; file, default and dynamic imports are not implemented") }
            guard word() == "from", cursor + 1 < tokens.count,
                  let module = tokens[cursor + 1].literal,
                  ["WEMath", "WEColor", "WEVector"].contains(module) else {
                throw ScriptFailure.invalid("Only the built-in WEMath, WEColor and WEVector modules are implemented")
            }
            cursor += 2
            var end = tokens[cursor - 1].end
            if word() == ";" { end = tokens[cursor].end; cursor += 1 }
            else if cursor < tokens.count {
                let gap = bytes[end..<tokens[cursor].start]
                guard gap.contains(10) || gap.contains(13) else { throw ScriptFailure.invalid("Invalid import statement boundary") }
            }
            for (member, local) in names {
                guard importedNames.insert(local).inserted else { throw ScriptFailure.invalid("Duplicate import binding: " + local) }
                imports.append(["module": module, "member": member, "local": local])
            }
            blank(token.start, end); tokenIndex = cursor; continue
        }
        if token.word == "export" {
            guard token.depth == 0, tokenIndex + 2 < tokens.count else { throw ScriptFailure.invalid("Unsupported module export") }
            let declaration = tokens[tokenIndex + 1].word, name = tokens[tokenIndex + 2].word
            guard isName(name), ["function", "var", "let", "const", "class"].contains(declaration) else {
                throw ScriptFailure.invalid("Only named function, variable and class export declarations are implemented")
            }
            if declaration == "function" {
                guard tokenIndex + 3 < tokens.count, tokens[tokenIndex + 3].word == "(" else { throw ScriptFailure.invalid("Unsupported exported function declaration") }
                exports.append(name)
            }
            blank(token.start, token.end)
        }
        tokenIndex += 1
    }
    try inspect?(exports, tokens.map(\.word))
    return (String(decoding: bytes, as: UTF8.self), exports, imports)
}
