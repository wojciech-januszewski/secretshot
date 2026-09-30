import Foundation

/// A class of sensitive data the scanner knows how to find.
/// Each rule runs against one OCR'd line of text and returns the ranges to redact.
struct DetectionRule {
    let id: String
    let label: String
    let defaultEnabled: Bool
    /// Pattern applied to a single OCR line.
    let pattern: String
    /// Which capture group holds the secret itself. 0 = whole match.
    let group: Int
    /// Extra semantic check (Luhn, entropy, …) run on the captured text.
    let validate: ((String) -> Bool)?
    /// Rule only fires when one of these keywords appears on the same line.
    /// Kills false positives for patterns that are otherwise just "a word".
    let contextKeywords: [String]?

    init(id: String,
         label: String,
         defaultEnabled: Bool = true,
         pattern: String,
         group: Int = 0,
         validate: ((String) -> Bool)? = nil,
         contextKeywords: [String]? = nil) {
        self.id = id
        self.label = label
        self.defaultEnabled = defaultEnabled
        self.pattern = pattern
        self.group = group
        self.validate = validate
        self.contextKeywords = contextKeywords
    }
}

struct RuleMatch {
    let ruleID: String
    let ruleLabel: String
    /// Range inside the line the match was found in.
    let range: Range<String.Index>
    let text: String
}

enum Detectors {

    static let all: [DetectionRule] = [
        DetectionRule(
            id: "email",
            label: "E-mail",
            pattern: #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
        ),
        DetectionRule(
            id: "jwt",
            label: "JWT",
            pattern: #"eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"#
        ),
        DetectionRule(
            id: "openai_key",
            label: "OpenAI / Anthropic key",
            pattern: #"\b(?:sk|sk-proj|sk-ant)-[A-Za-z0-9_\-]{16,}"#
        ),
        DetectionRule(
            id: "github_token",
            label: "GitHub token",
            pattern: #"\bgh[pousr]_[A-Za-z0-9]{16,}"#
        ),
        DetectionRule(
            id: "aws_key",
            label: "AWS access key",
            pattern: #"\b(?:AKIA|ASIA|AGPA|AIDA|AROA|AIPA|ANPA|ANVA|A3T[A-Z0-9])[A-Z0-9]{16}\b"#
        ),
        DetectionRule(
            id: "slack_token",
            label: "Slack token",
            pattern: #"\bxox[baprse]-[A-Za-z0-9\-]{10,}"#
        ),
        DetectionRule(
            id: "google_api_key",
            label: "Google API key",
            pattern: #"\bAIza[0-9A-Za-z_\-]{35}\b"#
        ),
        DetectionRule(
            id: "bearer",
            label: "Bearer token",
            pattern: #"(?i)\b(?:bearer|authorization:)\s+([A-Za-z0-9._\-+/=]{12,})"#,
            group: 1
        ),
        DetectionRule(
            id: "private_key",
            label: "Private key",
            pattern: #"-{3,}BEGIN[A-Z ]*PRIVATE KEY-{3,}"#
        ),
        DetectionRule(
            id: "filevault_key",
            label: "FileVault recovery key",
            // 6 groups of 4 uppercase alphanumerics. Distinctive enough to fire
            // without a label, which matters — this is the single worst thing that
            // can leave a Mac admin's screen.
            pattern: #"\b[A-Z0-9]{4}(?:-[A-Z0-9]{4}){5}\b"#
        ),
        DetectionRule(
            id: "bitlocker_key",
            label: "BitLocker recovery key",
            pattern: #"\b\d{6}(?:-\d{6}){7}\b"#
        ),
        DetectionRule(
            id: "pesel",
            label: "PESEL",
            // Checksum *and* the embedded birth date must both validate. Counting
            // digits alone would fire on every phone number and order ID.
            pattern: #"\b\d{11}\b"#,
            validate: { peselValid($0) },
            // Checksum alone is not enough: ~3% of random 11-digit order and asset
            // numbers satisfy it *and* decode to a plausible date. Needs the label.
            contextKeywords: ["pesel", "nr ewidencyjny", "evidence number"]
        ),
        DetectionRule(
            id: "nip",
            label: "NIP",
            pattern: #"\b\d{3}-?\d{3}-?\d{2}-?\d{2}\b"#,
            validate: { nipValid($0) },
            contextKeywords: ["nip", "vat id", "vat no", "tax id", "podatk"]
        ),
        DetectionRule(
            id: "bank_account_pl",
            label: "Bank account (NRB)",
            // 26 digits validated by the IBAN mod-97 check. Ungated: a 26-digit run
            // is already rare, and mod-97 leaves ~1% of them — unlike the 11-digit
            // PESEL space, which admin panels are full of.
            pattern: #"\b\d{2}[ ]?(?:\d{4}[ ]?){5}\d{4}\b"#,
            validate: { nrbValid($0) }
        ),
        DetectionRule(
            id: "id_card_pl",
            label: "ID card number",
            // 3 letters + 6 digits collides with asset tags like MAC123456, and the
            // checksum only removes 9 in 10. Needs the label.
            pattern: #"\b[A-Z]{3}\d{6}\b"#,
            validate: { idCardValid($0) },
            contextKeywords: ["dowód", "dowod", "id card", "nr dokumentu", "seria i numer", "document no"]
        ),
        DetectionRule(
            id: "regon",
            label: "REGON",
            pattern: #"\b(?:\d{14}|\d{9})\b"#,
            validate: { regonValid($0) },
            contextKeywords: ["regon"]
        ),
        DetectionRule(
            id: "basic_auth_url",
            label: "Credentials in URL",
            pattern: #"(?i)\bhttps?://[^\s/:@]+:([^\s/@]+)@"#,
            group: 1
        ),
        DetectionRule(
            id: "slack_webhook",
            label: "Slack webhook",
            pattern: #"https://hooks\.slack\.com/services/[A-Za-z0-9/_\-]+"#
        ),
        DetectionRule(
            id: "stripe_key",
            label: "Stripe key",
            pattern: #"\b[rs]k_(?:live|test)_[A-Za-z0-9]{16,}"#
        ),
        DetectionRule(
            id: "google_oauth_secret",
            label: "Google OAuth secret",
            pattern: #"\bGOCSPX-[A-Za-z0-9_\-]{20,}"#
        ),
        DetectionRule(
            id: "okta_token",
            label: "Okta API token",
            pattern: #"\b00[A-Za-z0-9_\-]{40}\b"#,
            contextKeywords: ["okta", "ssws", "api token"]
        ),
        DetectionRule(
            id: "npm_token",
            label: "npm token",
            pattern: #"\bnpm_[A-Za-z0-9]{36}\b"#
        ),
        DetectionRule(
            id: "pypi_token",
            label: "PyPI token",
            pattern: #"\bpypi-[A-Za-z0-9_\-]{16,}"#
        ),
        DetectionRule(
            id: "sendgrid_key",
            label: "SendGrid key",
            pattern: #"\bSG\.[A-Za-z0-9_\-]{16,}\.[A-Za-z0-9_\-]{16,}"#
        ),
        DetectionRule(
            id: "aws_secret_key",
            label: "AWS secret key",
            // 40 base64ish characters is far too generic to fire unlabelled.
            pattern: #"\b[A-Za-z0-9/+=]{40}\b"#,
            contextKeywords: ["secret access key", "aws_secret", "secretaccesskey"]
        ),
        DetectionRule(
            id: "totp_secret",
            label: "TOTP / MFA secret",
            pattern: #"(?i)\botpauth://[^\s]+|\bsecret=([A-Z2-7]{16,})"#,
            group: 0
        ),
        DetectionRule(
            id: "password_field",
            label: "Password",
            pattern: #"(?i)\b(?:pass(?:word)?|pwd|has[lł]o|secret|passphrase)\s*[:=]\s*(\S+)"#,
            group: 1
        ),
        DetectionRule(
            id: "credit_card",
            label: "Card number",
            pattern: #"\b(?:\d[ \-]?){13,19}\b"#,
            validate: { luhnValid($0) }
        ),
        DetectionRule(
            id: "ipv4",
            label: "IP address",
            pattern: #"\b(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\b"#,
            validate: { !isBoringIP($0) }
        ),
        DetectionRule(
            id: "mac_address",
            label: "MAC address",
            // Charset is deliberately wider than hex: Vision reads 0 as O, 8 as B,
            // 1 as I/l. Six colon-separated pairs is a structure nothing else has,
            // so loosening the alphabet costs no precision.
            pattern: #"\b(?:[0-9A-Za-z]{2}[:\-]){5}[0-9A-Za-z]{2}\b"#,
            validate: { looksHexAfterOCRFixes($0) }
        ),
        DetectionRule(
            id: "device_udid",
            label: "Device UDID",
            // Same 8-4-4-4-12 shape as a UUID but gated on a hardware-ID label, so
            // policy/object UUIDs all over an admin panel don't get swept up.
            pattern: #"\b[0-9A-Za-z]{8}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{4}-[0-9A-Za-z]{12}\b"#,
            contextKeywords: ["udid", "uuid", "hardware uuid", "provisioning", "device id"]
        ),
        DetectionRule(
            id: "serial_number",
            label: "Serial number",
            // Gated on context — a bare 10–12 char alnum blob is far too common to
            // redact blind, but next to "Serial Number" in Jamf it always is one.
            pattern: #"\b[A-Z0-9]{10,12}\b"#,
            validate: { $0.rangeOfCharacter(from: .decimalDigits) != nil },
            contextKeywords: ["serial", "s/n", "sn:", "numer seryjny", "imei"]
        ),
        DetectionRule(
            id: "iban",
            label: "IBAN",
            pattern: #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){3,7}\b"#
        ),
        DetectionRule(
            id: "uuid",
            label: "UUID",
            defaultEnabled: false,
            pattern: #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#
        ),
        DetectionRule(
            id: "phone",
            label: "Phone number",
            defaultEnabled: false,
            pattern: #"(?:\+\d{1,3}[ \-]?)?(?:\d[ \-]?){9,13}\b"#
        ),
        DetectionRule(
            id: "high_entropy",
            label: "High-entropy string",
            defaultEnabled: false,
            pattern: #"\b[A-Za-z0-9+/=_\-]{28,}\b"#,
            validate: { shannonEntropy($0) > 3.6 }
        ),
    ]

    /// Runs every enabled rule over one line and returns non-overlapping matches
    /// (longest match wins where two rules fight over the same characters).
    ///
    /// `context` is the text of the whole table row, not just this line — a value
    /// in one column needs to see its label in another. Defaults to the line itself.
    static func scan(line: String, context: String? = nil, enabled: Set<String>) -> [RuleMatch] {
        let lower = (context ?? line).lowercased()
        var found: [RuleMatch] = []
        let full = NSRange(line.startIndex..., in: line)

        for rule in all where enabled.contains(rule.id) {
            if let keywords = rule.contextKeywords,
               !keywords.contains(where: { lower.contains($0) }) {
                continue
            }
            guard let regex = cachedRegex(rule.pattern) else { continue }

            for m in regex.matches(in: line, options: [], range: full) {
                let ns = m.range(at: rule.group)
                guard ns.location != NSNotFound,
                      let range = Range(ns, in: line) else { continue }
                let text = String(line[range])
                if let validate = rule.validate, !validate(text) { continue }
                found.append(RuleMatch(ruleID: rule.id, ruleLabel: rule.label, range: range, text: text))
            }
        }
        return dedupe(found, in: line)
    }

    // MARK: - Helpers

    private static var regexCache: [String: NSRegularExpression] = [:]
    private static let cacheLock = NSLock()

    private static func cachedRegex(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = regexCache[pattern] { return cached }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        regexCache[pattern] = regex
        return regex
    }

    /// Drops matches fully contained in a longer one so we don't stack boxes.
    private static func dedupe(_ matches: [RuleMatch], in line: String) -> [RuleMatch] {
        let sorted = matches.sorted {
            let a = line.distance(from: $0.range.lowerBound, to: $0.range.upperBound)
            let b = line.distance(from: $1.range.lowerBound, to: $1.range.upperBound)
            return a > b
        }
        var kept: [RuleMatch] = []
        for m in sorted {
            let overlaps = kept.contains { k in
                m.range.lowerBound < k.range.upperBound && k.range.lowerBound < m.range.upperBound
            }
            if !overlaps { kept.append(m) }
        }
        return kept
    }

    static func luhnValid(_ raw: String) -> Bool {
        let digits = raw.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 {
                let doubled = d * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += d
            }
        }
        return sum % 10 == 0
    }

    /// Vision confuses a handful of glyph pairs regardless of language correction.
    /// Undo the substitutions, then check the result really is hex — this keeps the
    /// widened MAC charset from matching arbitrary colon-separated words.
    static func looksHexAfterOCRFixes(_ s: String) -> Bool {
        let fixes: [Character: Character] = [
            "O": "0", "o": "0", "I": "1", "l": "1", "i": "1",
            "S": "5", "s": "5", "B": "8", "Z": "2", "z": "2", "G": "6", "q": "9",
        ]
        let hex = Set("0123456789abcdefABCDEF")
        for c in s where c != ":" && c != "-" {
            if hex.contains(c) { continue }
            guard let fixed = fixes[c], hex.contains(fixed) else { return false }
        }
        return true
    }

    /// PESEL: 11 digits carrying a birth date and a check digit. Both are verified —
    /// the checksum alone still accepts roughly one random 11-digit run in ten,
    /// and admin panels are full of 11-digit order and asset numbers.
    static func peselValid(_ raw: String) -> Bool {
        let d = raw.compactMap { $0.wholeNumberValue }
        guard d.count == 11 else { return false }

        let weights = [1, 3, 7, 9, 1, 3, 7, 9, 1, 3]
        let sum = zip(d.prefix(10), weights).reduce(0) { $0 + $1.0 * $1.1 }
        guard (10 - sum % 10) % 10 == d[10] else { return false }

        // Month encodes the century: 1–12 → 1900s, 21–32 → 2000s, 41–52 → 2100s,
        // 61–72 → 2200s, 81–92 → 1800s.
        let month = d[2] * 10 + d[3]
        let day = d[4] * 10 + d[5]
        let validMonth = [(1, 12), (21, 32), (41, 52), (61, 72), (81, 92)]
            .contains { month >= $0.0 && month <= $0.1 }
        return validMonth && day >= 1 && day <= 31
    }

    /// NIP: 10 digits, weighted checksum mod 11.
    static func nipValid(_ raw: String) -> Bool {
        let d = raw.compactMap { $0.wholeNumberValue }
        guard d.count == 10 else { return false }
        let weights = [6, 5, 7, 2, 3, 4, 5, 6, 7]
        let sum = zip(d.prefix(9), weights).reduce(0) { $0 + $1.0 * $1.1 }
        let check = sum % 11
        return check != 10 && check == d[9]
    }

    /// Polish bank account (NRB): 26 digits carrying their own IBAN check.
    /// Validated as the IBAN "PL" + NRB would be — move the first four characters
    /// to the end (PL → 2521) and require the whole thing ≡ 1 (mod 97).
    static func nrbValid(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard digits.count == 26 else { return false }
        let rearranged = String(digits.dropFirst(2)) + "2521" + String(digits.prefix(2))
        return mod97(rearranged) == 1
    }

    private static func mod97(_ digits: String) -> Int {
        digits.reduce(0) { ($0 * 10 + ($1.wholeNumberValue ?? 0)) % 97 }
    }

    /// Polish ID card: 3 letters, a check digit, then 5 digits.
    /// Letters count as A=10 … Z=35; the 4th character is excluded by weight 0.
    static func idCardValid(_ raw: String) -> Bool {
        let chars = Array(raw.uppercased())
        guard chars.count == 9,
              chars.prefix(3).allSatisfy({ $0.isLetter }),
              chars.suffix(6).allSatisfy({ $0.isNumber }) else { return false }

        let weights = [7, 3, 1, 0, 7, 3, 1, 7, 3]
        func value(_ c: Character) -> Int {
            if c.isNumber { return c.wholeNumberValue ?? 0 }
            guard let ascii = c.asciiValue else { return 0 }
            return Int(ascii - Character("A").asciiValue!) + 10
        }
        let sum = zip(chars, weights).reduce(0) { $0 + value($1.0) * $1.1 }
        return sum % 10 == value(chars[3])
    }

    /// REGON: 9 or 14 digits, weighted mod 11 with 10 folding to 0.
    static func regonValid(_ raw: String) -> Bool {
        let d = raw.compactMap { $0.wholeNumberValue }
        let weights: [Int]
        switch d.count {
        case 9:  weights = [8, 9, 2, 3, 4, 5, 6, 7]
        case 14: weights = [2, 4, 8, 5, 0, 9, 7, 3, 6, 1, 2, 4, 8]
        default: return false
        }
        let sum = zip(d.prefix(weights.count), weights).reduce(0) { $0 + $1.0 * $1.1 }
        return sum % 11 % 10 == d[weights.count]
    }

    static func shannonEntropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return counts.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }

    /// Private/loopback/version-looking addresses aren't worth redacting and
    /// firing on them is the fastest way to make the app feel stupid.
    static func isBoringIP(_ s: String) -> Bool {
        if s.hasPrefix("127.") || s.hasPrefix("0.") || s == "255.255.255.255" { return true }
        if s.hasPrefix("192.168.") || s.hasPrefix("10.") || s.hasPrefix("169.254.") { return true }
        let parts = s.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4, parts[0] == 172, (16...31).contains(parts[1]) { return true }
        return false
    }
}
