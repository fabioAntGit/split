import Foundation

// Small Markdown → HTML renderer (headings, emphasis, links, images, code,
// lists, quotes, rules and pipe tables) — enough for notes and READMEs.
enum Markdown {
    static func document(_ markdown: String, title: String) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>body{font:12pt "Helvetica Neue",Helvetica,Arial,sans-serif;line-height:1.45;max-width:46em;margin:2em auto;color:#111}
        pre{background:#f4f4f4;padding:.8em;overflow-x:auto}code{font-family:Menlo,monospace;font-size:.92em}
        blockquote{border-left:3px solid #ccc;margin-left:0;padding-left:1em;color:#444}
        table{border-collapse:collapse}td,th{border:1px solid #bbb;padding:.3em .6em}th{background:#eee}</style>
        </head><body>
        \(toHTML(markdown))
        </body></html>
        """
    }

    static func toHTML(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var html: [String] = []
        var paragraph: [String] = []
        var listStack: [(tag: String, indent: Int)] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html.append("<p>\(inline(paragraph.joined(separator: " ")))</p>")
            paragraph.removeAll()
        }
        func closeLists(toIndent indent: Int = -1) {
            while let last = listStack.last, last.indent > indent {
                html.append("</li></\(last.tag)>")
                listStack.removeLast()
            }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph(); closeLists()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    code.append(escape(lines[index]))
                    index += 1
                }
                html.append("<pre><code>\(code.joined(separator: "\n"))</code></pre>")
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                if let next = lines.dropFirst(index + 1).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                   listMarker(next.trimmingCharacters(in: .whitespaces)) == nil {
                    closeLists()
                }
                index += 1
                continue
            }
            if let level = atxLevel(trimmed) {
                flushParagraph(); closeLists()
                let text = trimmed.dropFirst(level).trimmingCharacters(in: CharacterSet(charactersIn: " #"))
                html.append("<h\(level)>\(inline(text))</h\(level)>")
                index += 1
                continue
            }
            if isRule(trimmed) {
                flushParagraph(); closeLists()
                html.append("<hr>")
                index += 1
                continue
            }
            if trimmed.hasPrefix(">") {
                flushParagraph(); closeLists()
                var quote: [String] = []
                while index < lines.count {
                    let t = lines[index].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quote.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                html.append("<blockquote>\(toHTML(quote.joined(separator: "\n")))</blockquote>")
                continue
            }
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph(); closeLists()
                var rows = [cells(trimmed)]
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                var table = "<table><thead><tr>" + rows[0].map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead><tbody>"
                for row in rows.dropFirst() {
                    table += "<tr>" + row.map { "<td>\(inline($0))</td>" }.joined() + "</tr>"
                }
                html.append(table + "</tbody></table>")
                continue
            }
            if let (tag, content) = listMarker(trimmed) {
                flushParagraph()
                if let last = listStack.last, indent > last.indent {
                    html.append("<\(tag)><li>\(inline(content))")
                    listStack.append((tag, indent))
                } else {
                    closeLists(toIndent: indent)
                    if let last = listStack.last, last.indent == indent, last.tag == tag {
                        html.append("</li><li>\(inline(content))")
                    } else {
                        if let last = listStack.last, last.indent == indent {
                            html.append("</li></\(last.tag)>")
                            listStack.removeLast()
                        }
                        html.append("<\(tag)><li>\(inline(content))")
                        listStack.append((tag, indent))
                    }
                }
                index += 1
                continue
            }
            if !listStack.isEmpty && indent > 0 {
                html.append(" " + inline(trimmed))
            } else {
                closeLists()
                paragraph.append(trimmed)
            }
            index += 1
        }
        flushParagraph()
        closeLists()
        return html.joined(separator: "\n")
    }

    // MARK: Block helpers

    static func atxLevel(_ line: String) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = line.dropFirst(hashes)
        return rest.isEmpty || rest.hasPrefix(" ") ? hashes : nil
    }

    static func isRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
        return compact.allSatisfy { $0 == first }
    }

    static func listMarker(_ line: String) -> (String, String)? {
        for bullet in ["- ", "* ", "+ "] where line.hasPrefix(bullet) {
            return ("ul", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, digits.count < 10 {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(". ") || rest.hasPrefix(") ") { return ("ol", String(rest.dropFirst(2))) }
        }
        return nil
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("|") && t.contains("-") && t.allSatisfy { "|-: ".contains($0) }
    }

    static func cells(_ row: String) -> [String] {
        var t = row
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    // MARK: Inline

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func inline(_ text: String) -> String {
        // Protect code spans first so their contents aren't formatted.
        var codes: [String] = []
        var working = replace(#"`([^`]+)`"#, in: text) { groups in
            codes.append("<code>\(escape(groups[1]))</code>")
            return "\u{1}\(codes.count - 1)\u{1}"
        }
        working = escape(working)
        working = replace(#"!\[([^\]]*)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)"#, in: working) { "<img alt=\"\($0[1])\" src=\"\($0[2])\">" }
        working = replace(#"\[([^\]]+)\]\(([^)\s]+)(?:\s+&quot;[^)]*&quot;)?\)"#, in: working) { "<a href=\"\($0[2])\">\($0[1])</a>" }
        working = replace(#"&lt;(https?://[^&\s]+)&gt;"#, in: working) { "<a href=\"\($0[1])\">\($0[1])</a>" }
        working = replace(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#, in: working) { "<strong>\($0[2])</strong>" }
        working = replace(#"(?<![\w*])(\*|_)(?=\S)(.+?)(?<=\S)\1(?![\w*])"#, in: working) { "<em>\($0[2])</em>" }
        working = replace(#"~~(.+?)~~"#, in: working) { "<del>\($0[1])</del>" }
        working = replace("\u{1}(\\d+)\u{1}", in: working) { codes[Int($0[1]) ?? 0] }
        return working
    }

    static func replace(_ pattern: String, in text: String, with transform: ([String]) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let groups = (0..<match.numberOfRanges).map { i -> String in
                let r = match.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            result += transform(groups)
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }
}
