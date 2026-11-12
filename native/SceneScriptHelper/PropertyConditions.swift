import Foundation
import JavaScriptCore
import Darwin

/// One-shot expression evaluation, without SceneScript objects or host callbacks.
/// A fresh context for each row prevents one condition from changing another.
func runNativePropertyConditions() -> Int32 {
    // The parent also enforces a shorter deadline. This bounds orphaned work
    // if the parent exits before it can cancel its own helper process.
    alarm(3)
    do {
        guard let line = try NativeScriptLineReader().readLine(),
              let request = try JSONSerialization.jsonObject(with: line) as? [String: Any],
              request["protocol"] as? Int == 1,
              let conditions = request["conditions"] as? [String: String], conditions.count <= 256,
              let properties = request["properties"] as? [String: Any], properties.count <= 4096 else {
            throw ScriptFailure.invalid("Invalid property condition request")
        }
        let values = String(decoding: try JSONSerialization.data(withJSONObject: properties), as: UTF8.self)
        let literal = String(decoding: try JSONSerialization.data(withJSONObject: values, options: [.fragmentsAllowed]), as: UTF8.self)
        var visible: [String: Bool] = [:], errors: [String: String] = [:]
        for key in conditions.keys.sorted() {
            let expression = conditions[key]!
            guard key.utf8.count <= 4096, expression.utf8.count <= 16384 else {
                visible[key] = true; errors[key] = "Display condition exceeds its size limit"; continue
            }
            guard let context = JSContext() else {
                visible[key] = true; errors[key] = "Could not create a condition context"; continue
            }
            // `with` exposes property keys exactly as documented (key.value).
            // The source remains an expression; normal JavaScript operators,
            // coercions and pure JS functions are handled by JavaScriptCore.
            let source = "(function(properties){with(properties){return !!(\n" + expression + "\n);}})(JSON.parse(" + literal + "))"
            let result = context.evaluateScript(source)
            if let exception = context.exception {
                visible[key] = true
                errors[key] = String((exception.toString() ?? "Invalid display condition").prefix(256))
            } else if let result, result.isBoolean {
                visible[key] = result.toBool()
            } else {
                visible[key] = true; errors[key] = "Display condition did not return a boolean"
            }
        }
        response(["ok": true, "protocol": 1, "visible": visible, "errors": errors, "pid": getpid()])
        return 0
    } catch {
        response(["ok": false, "protocol": 1, "error": String(error.localizedDescription.prefix(256))])
        return 1
    }
}
