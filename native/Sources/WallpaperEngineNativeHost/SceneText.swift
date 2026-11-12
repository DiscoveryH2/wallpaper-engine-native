import Foundation
import CoreGraphics
import CoreText

/// Text is rasterized by Apple's CoreText. Fonts stay private to this layer;
/// nothing is installed or registered on the user's system.
final class SceneTextLayout {
    static let properties = ["text", "font", "pointsize", "padding", "horizontalalign", "verticalalign", "anchor",
                             "limitwidth", "maxwidth", "limitrows", "maxrows", "limituseellipsis", "blockalign",
                             "opaquebackground", "backgroundcolor", "backgroundbrightness"]
    struct Bitmap {
        let width: Int, height: Int
        let rgba: [UInt8]
        let offset: SIMD2<Float>
    }
    private let assets: SceneAssets
    private let builtinFonts: NativeBuiltinFonts.Snapshot?
    private let baseline: CGSize
    private var sceneUnitsPerPoint: CGFloat = 4
    private var fontPath: String?
    private var graphicsFont: CGFont?
    private var installedFont: CTFont?
    private var lastKey: Data?
    private(set) var diagnostics: [String] = []
    private(set) var runtimeDiagnostic: String?

    private struct Line {
        let text: CTLine
        let width: CGFloat
        let gaps: [CGFloat]
        let expansion: CGFloat

        func draw(_ context: CGContext, at origin: CGPoint) {
            guard !gaps.isEmpty else { context.textPosition = origin; CTLineDraw(text, context); return }
            // Preserve CoreText shaping, fallback fonts, and bidi glyph order.
            // Only move glyphs after eligible whitespace, rather than asking
            // CoreText's general justification to stretch non-space characters.
            for run in CTLineGetGlyphRuns(text) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                for index in 0..<count {
                    var low = 0, high = gaps.count
                    while low < high {
                        let middle = (low + high) / 2
                        if gaps[middle] <= positions[index].x + 0.001 { low = middle + 1 } else { high = middle }
                    }
                    context.textPosition = CGPoint(x: origin.x + CGFloat(low) * expansion, y: origin.y)
                    CTRunDraw(run, context, CFRange(location: index, length: 1))
                }
            }
        }
    }

    init(object: [String: Any], assets: SceneAssets, builtinFonts: NativeBuiltinFonts.Snapshot? = nil) throws {
        self.assets = assets; self.builtinFonts = builtinFonts
        let object = object.mapValues { ($0 as? [String: Any])?["value"] ?? $0 }
        let parts = (object["size"] as? String ?? "").split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
        guard parts.count < 2 || parts.prefix(2).allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 16384 }) else { throw SceneError.invalid("文字图层原始尺寸无效。") }
        baseline = parts.count >= 2 ? CGSize(width: parts[0], height: parts[1]) : .zero
        let size = number(object["pointsize"], 16)
        let font = try resolveFont(object["font"] as? String ?? "", size: size)
        let padding = number(object["padding"], 0)
        let rows = max(1, (object["text"] as? String ?? "").components(separatedBy: "\n").count)
        let authoredHeight = baseline.height - padding * 2
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        // The package stores geometry in scene pixels, but not the editor's font
        // DPI. Infer a stable conversion from the authored padded line height.
        // It is a compatibility approximation, not measured Windows font parity.
        if !(object["text"] as? String ?? "").isEmpty, authoredHeight > 0, lineHeight > 0 {
            sceneUnitsPerPoint = min(8, max(0.25, authoredHeight / (lineHeight * CGFloat(rows))))
        }
        diagnostics.append("CoreText 字体比例 \(String(format: "%.3f", Double(sceneUnitsPerPoint)))：按原始图层高度推算；初始空文本用 4 倍估计，字距与原版 DPI 尚未对齐。")
    }

    private func note(_ text: String) { if !diagnostics.contains(text), diagnostics.count < 32 { diagnostics.append(text) } }
    private func number(_ value: Any?, _ fallback: CGFloat) -> CGFloat {
        let value = (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init) ?? Double(fallback)
        return value.isFinite ? CGFloat(value) : fallback
    }

    /// A Workshop scene may name an installed font through this sentinel. The
    /// host does not install or activate fonts. CoreText can silently return a
    /// fallback for an unknown name, so accept a result only when one of its
    /// actual names equals the requested name, ignoring case.
    private func resolveInstalledFont(_ path: String) -> CTFont? {
        let prefix = "systemfont_"
        guard path.count >= prefix.count, path.prefix(prefix.count).lowercased() == prefix else { return nil }
        let name = String(path.dropFirst(prefix.count))
        guard !name.isEmpty, name.utf8.count <= 256,
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        let candidate = CTFontCreateWithNameAndOptions(name as CFString, 1, nil, [.preventAutoActivation, .preventAutoDownload])
        let actualNames = [CTFontCopyPostScriptName(candidate), CTFontCopyFamilyName(candidate),
                           CTFontCopyFullName(candidate), CTFontCopyDisplayName(candidate)].map { $0 as String }
        let locale = Locale(identifier: "en_US_POSIX")
        guard actualNames.contains(where: { $0.compare(name, options: [.caseInsensitive], locale: locale) == .orderedSame }) else { return nil }
        return candidate
    }

    private func resolveFont(_ path: String, size: CGFloat) throws -> CTFont {
        guard size > 0, size <= 2048 else { throw SceneError.invalid("文字字号不在 (0, 2048] 范围内。") }
        if fontPath != path {
            graphicsFont = nil; installedFont = nil; fontPath = nil
            if !path.isEmpty, assets.contains(path) {
                let data = try assets.data(path, maximumBytes: 16 * 1024 * 1024)
                guard let provider = CGDataProvider(data: data as CFData),
                      let font = CGFont(provider) else { throw SceneError.invalid("包内字体无效或超过 16 MiB：\(path)") }
                graphicsFont = font
            } else if let builtinFonts, builtinFonts.contains(path) {
                let data = try builtinFonts.data(path)
                guard let provider = CGDataProvider(data: data as CFData),
                      let font = CGFont(provider) else { throw SceneError.invalid("内置字体无效：\(path)") }
                graphicsFont = font
                note("内置字体 \(path) 使用本机导入的官方素材；字体比例和外观仍可能与原平台不同。")
            } else if let matched = resolveInstalledFont(path) {
                installedFont = matched
                note("系统字体 \(path) 使用本机已安装的 \(CTFontCopyPostScriptName(matched) as String)；外观仍可能与原平台不同。")
            } else {
                note("缺少字体 \(path.isEmpty ? "(未指定)" : path)，使用 macOS 系统字体；字体外观有差异。")
            }
            fontPath = path
        }
        if let graphicsFont { return CTFontCreateWithGraphicsFont(graphicsFont, size, nil, nil) }
        if let installedFont { return CTFontCreateCopyWithAttributes(installedFont, size, nil, nil) }
        return CTFontCreateUIFontForLanguage(.system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
    }

    /// Rebuild only when layout or text changes. Colors/opacity use shader uniforms.
    private func layoutKey(_ object: [String: Any]) throws -> Data {
        let layoutKeys = Self.properties.filter { !["anchor", "opaquebackground", "backgroundcolor", "backgroundbrightness"].contains($0) }
        let signature = Dictionary(uniqueKeysWithValues: layoutKeys.compactMap { key -> (String, Any)? in object[key].map { (key, $0) } })
        return try JSONSerialization.data(withJSONObject: signature, options: [.sortedKeys])
    }

    /// A new Metal runtime can adopt a bitmap already produced by this exact
    /// source layout without drawing the same text a second time at startup.
    func useRenderedLayout(_ object: [String: Any]) throws { lastKey = try layoutKey(object) }

    func rasterize(_ object: [String: Any]) throws -> Bitmap? {
        let key = try layoutKey(object)
        if key == lastKey { return nil }
        // A malformed dynamic value is reported once; retain the last valid image
        // until the author changes it again instead of throwing every frame.
        lastKey = key
        let text = object["text"] as? String ?? ""
        guard text.utf8.count <= 16 * 1024 else { throw SceneError.invalid("单图层文字超过 16 KiB。") }
        let pointSize = number(object["pointsize"], 16)
        let font = try resolveFont(object["font"] as? String ?? "", size: pointSize * sceneUnitsPerPoint)
        let padding = number(object["padding"], 0)
        guard padding >= 0, padding <= 1024 else { throw SceneError.invalid("文字边距不在 [0, 1024] 范围内。") }
        let limitWidth = object["limitwidth"] as? Bool == true
        let maxWidth = number(object["maxwidth"], 500)
        guard !limitWidth || (maxWidth >= 1 && maxWidth <= 4096) else { throw SceneError.invalid("文字宽度上限无效。") }
        let rowLimit = object["limitrows"] as? Bool == true ? Int(max(1, min(64, number(object["maxrows"], 1)))) : 64
        let ellipsis = object["limituseellipsis"] as? Bool == true
        let horizontal = object["horizontalalign"] as? String ?? "center"
        let vertical = object["verticalalign"] as? String ?? "center"
        let blockAlign = object["blockalign"] as? Bool == true
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let nsText = text as NSString
        var lines: [Line] = []
        var location = 0
        // Explicit newlines are retained; CoreText finds safe Unicode wrap points.
        while location < nsText.length && lines.count < rowLimit {
            let remaining = NSRange(location: location, length: nsText.length - location)
            let newline = nsText.rangeOfCharacter(from: .newlines, options: [], range: remaining)
            let end = newline.location == NSNotFound ? nsText.length : newline.location
            var count = end - location
            if limitWidth && count > 0 { count = min(count, max(1, CTTypesetterSuggestLineBreak(typesetter, location, Double(maxWidth)))) }
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: location, length: count))
            var next = location + count
            if next == end && newline.location != NSNotFound {
                next += 1
                if nsText.character(at: end) == 13, next < nsText.length, nsText.character(at: next) == 10 { next += 1 }
            }
            let softWrap = location + count < end
            let truncated = lines.count == rowLimit - 1 && next < nsText.length
            if lines.count == rowLimit - 1 && next < nsText.length && ellipsis {
                let remainder = text.substringFromUTF16(location).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                let all = CTLineCreateWithAttributedString(NSAttributedString(string: remainder, attributes: attributes))
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attributes))
                let width = limitWidth ? Double(maxWidth) : max(1, CTLineGetTypographicBounds(line, nil, nil, nil))
                line = CTLineCreateTruncatedLine(all, width, .end, token) ?? line
            }
            // The reference expands only automatically wrapped lines and clears
            // that flag for the final retained/ellipsized line. CoreText metrics
            // remain a native approximation of its FreeType/HarfBuzz metrics.
            var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            var gaps: [CGFloat] = [], expansion: CGFloat = 0
            if blockAlign && limitWidth && softWrap && !truncated {
                var trimmedEnd = location + count
                while trimmedEnd > location, [9, 13, 32].contains(Int(nsText.character(at: trimmedEnd - 1))) { trimmedEnd -= 1 }
                let naturalWidth = max(0, width - CGFloat(CTLineGetTrailingWhitespaceWidth(line)))
                if naturalWidth < maxWidth {
                    for index in location..<trimmedEnd where [9, 13, 32].contains(Int(nsText.character(at: index))) {
                        let start = CTLineGetOffsetForStringIndex(line, index, nil)
                        let end = CTLineGetOffsetForStringIndex(line, index + 1, nil)
                        gaps.append(max(start, end))
                    }
                    if !gaps.isEmpty {
                        gaps.sort(); expansion = (maxWidth - naturalWidth) / CGFloat(gaps.count); width = maxWidth
                    }
                }
            }
            lines.append(Line(text: line, width: width, gaps: gaps, expansion: expansion))
            location = next
        }
        if location < nsText.length && rowLimit == 64 { note("文字超过当前 64 行上限，剩余内容未绘制。") }
        if text.hasSuffix("\n") && lines.count < rowLimit {
            lines.append(Line(text: CTLineCreateWithAttributedString(NSAttributedString(string: "", attributes: attributes)), width: 0, gaps: [], expansion: 0))
        }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let lineHeight = max(1, ascent + descent + CTFontGetLeading(font))
        let widths = lines.map(\.width)
        let contentWidth = limitWidth ? min(maxWidth, widths.max() ?? 0) : widths.max() ?? 0
        let contentHeight = lineHeight * CGFloat(max(1, lines.count))
        let widthValue = ceil(contentWidth + padding * 2), heightValue = ceil(contentHeight + padding * 2)
        guard widthValue.isFinite, heightValue.isFinite, widthValue <= 4096, heightValue <= 4096 else { throw SceneError.invalid("文字纹理超过最长边 4096 像素。") }
        let width = max(1, Int(widthValue)), height = max(1, Int(heightValue))
        guard width * height <= 2 * 1024 * 1024 else { throw SceneError.invalid("文字纹理超过 2M 像素。") }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
                throw SceneError.invalid("无法创建文字位图。")
            }
            context.setShouldAntialias(true); context.setShouldSmoothFonts(false)
            // CoreGraphics places scanline 0 at the bitmap's top. Baselines use
            // its bottom-left coordinates; the renderer's UVs also start at top.
            for (index, line) in lines.enumerated() {
                let unused = max(0, contentWidth - widths[index])
                let x = padding + (horizontal == "right" ? unused : horizontal == "left" ? 0 : unused / 2)
                line.draw(context, at: CGPoint(x: x, y: CGFloat(height) - padding - ascent - CGFloat(index) * lineHeight))
            }
        }
        // Straight-alpha image pipeline: monochrome coverage is the alpha value.
        for pixel in stride(from: 0, to: rgba.count, by: 4) {
            if rgba[pixel + 3] > 0 { rgba[pixel] = 255; rgba[pixel + 1] = 255; rgba[pixel + 2] = 255 }
        }
        let differenceX = Float(CGFloat(width) - baseline.width), differenceY = Float(CGFloat(height) - baseline.height)
        let offset = SIMD2<Float>(horizontal == "right" ? -differenceX / 2 : horizontal == "left" ? differenceX / 2 : 0,
                                  vertical == "bottom" ? differenceY / 2 : vertical == "top" ? -differenceY / 2 : 0)
        runtimeDiagnostic = "文字排版：\(lines.count) 行，两端对齐 \(lines.filter { !$0.gaps.isEmpty }.count) 行；前 12 行宽度 \(widths.prefix(12).map { String(format: "%.2f", Double($0)) }.joined(separator: ", "))；仅扩展自动换行的空白间距，字体度量尚未逐像素对齐原版。"
        return Bitmap(width: width, height: height, rgba: rgba, offset: offset)
    }
}

private extension String {
    func substringFromUTF16(_ index: Int) -> String { (self as NSString).substring(from: index) }
}
