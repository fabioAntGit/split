import AppKit

/// English is the source language: every text in the code is English and each table translates
/// all of it, with the same placeholders.
func registerLocalizationTests() {
    let languages: [Language] = [.pt, .fr, .es]

    test("Languages", "Every text in the code is translated, with the same placeholders") {
        let keys = SourceKeys.all()
        check(keys.count > 700, "only \(keys.count) texts found: did the search stop working?")
        for language in languages {
            let table = Localizer.loadTable(language)
            try require(!table.isEmpty, "the \(language.rawValue) table didn’t load")
            let missing = keys.subtracting(table.keys).sorted()
            check(missing.isEmpty, "\(language.rawValue): \(missing.count) untranslated: \(missing.prefix(8))")
            let unused = Set(table.keys).subtracting(keys).sorted()
            check(unused.isEmpty, "\(language.rawValue): \(unused.count) translations nothing uses: \(unused.prefix(8))")
            for (key, value) in table {
                check(!value.trimmingCharacters(in: .whitespaces).isEmpty, "\(language.rawValue): empty translation for “\(key)”")
                check(SourceKeys.placeholders(key) == SourceKeys.placeholders(value),
                      "\(language.rawValue): “\(key)” has \(SourceKeys.placeholders(key)) placeholders, “\(value)” has \(SourceKeys.placeholders(value))")
                check(key.hasSuffix("\n") == value.hasSuffix("\n"), "\(language.rawValue): “\(key)” and its translation end differently")
            }
        }
    }

    test("Languages", "Switching language changes the texts, numbers and dates at once") {
        defer { Localizer.shared.language = .en }
        let expected: [Language: (cancel: String, files: String)] = [
            .en: ("Cancel", "3 files converted"), .pt: ("Cancelar", "3 ficheiros convertidos"),
            .fr: ("Annuler", "3 fichiers convertis"), .es: ("Cancelar", "3 archivos convertidos"),
        ]
        for (language, texts) in expected {
            Localizer.shared.language = language
            check(L("Cancel") == texts.cancel, "\(language.rawValue): “Cancel” → \(L("Cancel"))")
            check(JobRunner.phrase(3, (L("1 file converted"), L("%@ files converted"))) == texts.files, "\(language.rawValue): plural → \(JobRunner.phrase(3, (L("1 file converted"), L("%@ files converted"))))")
            check(Localizer.shared.locale.identifier.hasPrefix(language.rawValue), "\(language.rawValue): locale \(Localizer.shared.locale.identifier)")
            let message = Explain.noTargets([Fixtures.url("A folder")], tools: false).message
            check(language == .en || message != "Folders can’t be converted.", "\(language.rawValue): error messages follow the language: \(message)")
        }
        check(fill("%2$@ before %1$@", ["one", "two"]) == "two before one", "translations can reorder their placeholders")
        check(Language.system.resolved != .system, "“Mac language” always resolves to a real language")
    }

    test("Languages", "The code is written in English") {
        let portuguese = try NSRegularExpression(pattern: "\\b(ficheiros?|não|está|também|pasta|imagem|vídeo|definições|prateleira|roda|conversão|guardar)\\b",
                                                 options: [.caseInsensitive])
        for file in Hostile.sources() {
            let lines = Files.text(file).components(separatedBy: "\n")
            for (number, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard portuguese.firstMatch(in: line, range: range) != nil else { continue }
                // Matching what macOS itself prints in Portuguese, and each language's own name, is allowed.
                if line.contains("não tem autorização para enviar") || line.contains("\"Português\"") { continue }
                check(false, "\(file.lastPathComponent):\(number + 1) is not in English: \(line.trimmingCharacters(in: .whitespaces).prefix(100))")
            }
        }
    }
}

/// The texts the code looks up, read from the sources the way the Swift compiler sees them.
enum SourceKeys {
    static func all() -> Set<String> {
        var keys = Set<String>()
        let multiline = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])L\\(\"\"\"\\n(.*?)\\n([ \\t]*)\"\"\"", options: [.dotMatchesLineSeparators])
        let single = try! NSRegularExpression(pattern: "(?<![A-Za-z0-9_])L\\(\"((?:[^\"\\\\]|\\\\.)*)\"")
        for file in Hostile.sources() {
            let text = Files.text(file)
            let range = NSRange(text.startIndex..., in: text)
            for match in multiline.matches(in: text, range: range) {
                let body = String(text[Range(match.range(at: 1), in: text)!])
                let indent = String(text[Range(match.range(at: 2), in: text)!])
                keys.insert(body.components(separatedBy: "\n").map { $0.hasPrefix(indent) ? String($0.dropFirst(indent.count)) : $0 }.joined(separator: "\n"))
            }
            for match in single.matches(in: text, range: range) {
                let literal = String(text[Range(match.range(at: 1), in: text)!])
                if literal.isEmpty || literal == "\"\"" { continue }
                keys.insert(unescape(literal))
            }
        }
        return keys
    }

    static func unescape(_ literal: String) -> String {
        var result = ""
        var iterator = literal.makeIterator()
        while let character = iterator.next() {
            guard character == "\\", let next = iterator.next() else { result.append(character); continue }
            switch next {
            case "n": result.append("\n")
            case "t": result.append("\t")
            default: result.append(next)
            }
        }
        return result
    }

    static func placeholders(_ text: String) -> Int {
        text.components(separatedBy: "%").dropFirst().filter { $0.hasPrefix("@") || ($0.first?.isNumber == true && $0.contains("$@")) }.count
    }
}
