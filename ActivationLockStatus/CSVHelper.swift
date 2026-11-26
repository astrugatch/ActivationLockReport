import Foundation

enum CSVHelper {
    /// Extracts serial numbers from single-column or multi-column CSV text.
    static func extractSerialNumbers(from content: String) -> [String] {
        let cleaned = content.replacingOccurrences(of: "\u{FEFF}", with: "")
        let rawLines = cleaned.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let firstLine = rawLines.first else { return [] }

        let headerColumns = parseCSVRow(firstLine).map {
            $0.lowercased()
                .replacingOccurrences(of: " ", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "-", with: "")
        }

        let knownHeaderNames: Set<String> = [
            "serial", "serialnumber", "serialno", "deviceserial", "deviceserialnumber", "id"
        ]

        var serialColumnIndex = 0
        var startRowIndex = 0

        if let detectedIndex = headerColumns.firstIndex(where: { knownHeaderNames.contains($0) }) {
            serialColumnIndex = detectedIndex
            startRowIndex = 1
        }

        var serials: [String] = []
        var seen = Set<String>()

        for row in rawLines.dropFirst(startRowIndex) {
            let columns = parseCSVRow(row)
            guard serialColumnIndex < columns.count else { continue }
            let candidate = columns[serialColumnIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()

            if !candidate.isEmpty && !seen.contains(candidate) {
                seen.insert(candidate)
                serials.append(candidate)
            }
        }

        return serials
    }

    /// Generates an output CSV report from checked device records.
    static func generateCSV(from records: [DeviceLockRecord]) -> String {
        var lines = ["Serial Number,Status,Activation Lock Enabled,Lock Type,Details"]

        for record in records {
            let row = [
                escapeCSVField(record.serialNumber),
                escapeCSVField(record.status.rawValue),
                escapeCSVField(record.isLockedText),
                escapeCSVField(record.lockType),
                escapeCSVField(record.details)
            ].joined(separator: ",")
            lines.append(row)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func parseCSVRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var insideQuotes = false
        var iterator = row.makeIterator()

        while let char = iterator.next() {
            if char == "\"" {
                insideQuotes.toggle()
            } else if char == "," && !insideQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(char)
            }
        }
        fields.append(current)
        return fields
    }

    private static func escapeCSVField(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }
}
