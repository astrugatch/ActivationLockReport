import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @State private var clientId: String = ""
    @State private var keyId: String = ""
    @State private var pemContent: String = ""
    @State private var pemFileName: String = "No .pem file selected"

    @State private var didLoadInitialCredentials: Bool = false
    @State private var lastSavedCredentials: StoredASMCredentials = .empty
    @State private var saveDebounceTask: Task<Void, Never>?
    @State private var keychainStatusMessage: String = "Credentials are not yet saved in Keychain"

    @State private var csvFileName: String = "No CSV loaded"
    @State private var records: [DeviceLockRecord] = []
    @State private var selectedRecordID: DeviceLockRecord.ID?
    @State private var showRawInspector: Bool = false

    @State private var isRunning: Bool = false
    @State private var completedCount: Int = 0
    @State private var currentPhase: ASMPacingPhase?
    @State private var etaSeconds: TimeInterval = 0
    @State private var errorMessage: String?
    @State private var currentTask: Task<Void, Never>?

    private let apiClient = ASMAPIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 1. Credentials Section (Backed by macOS Keychain)
            GroupBox("Apple School Manager API Credentials") {
                VStack(alignment: .leading, spacing: 10) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Client ID:")
                                .frame(width: 90, alignment: .trailing)
                            TextField("SCHOOLAPI.xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", text: $clientId)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: clientId) { _, _ in
                                    apiClient.resetToken()
                                    scheduleKeychainSave()
                                }
                        }
                        GridRow {
                            Text("Key ID (kid):")
                                .frame(width: 90, alignment: .trailing)
                            TextField("d136aa66-0c3b-4bd4-9892-c20e8db024ab", text: $keyId)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: keyId) { _, _ in
                                    apiClient.resetToken()
                                    scheduleKeychainSave()
                                }
                        }
                        GridRow {
                            Text("Private Key:")
                                .frame(width: 90, alignment: .trailing)
                            HStack {
                                Button(pemContent.isEmpty ? "Select Private Key (.pem)..." : "Replace Private Key (.pem)...") {
                                    selectPEMFile()
                                }
                                .disabled(isRunning)

                                Image(systemName: pemContent.isEmpty ? "xmark.circle" : "checkmark.circle.fill")
                                    .foregroundStyle(pemContent.isEmpty ? Color.secondary : Color.green)

                                Text(pemFileName)
                                    .foregroundStyle(Color.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }

                    Divider()

                    HStack(spacing: 8) {
                        Image(systemName: hasAnyCredentialInput ? "key.fill" : "key")
                            .foregroundStyle(hasValidCredentials ? Color.green : Color.secondary)
                            .font(.caption)

                        Text(keychainStatusMessage)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)

                        Spacer()

                        if hasAnyCredentialInput {
                            Button("Clear Keychain", role: .destructive) {
                                clearCredentialsFromKeychain()
                            }
                            .controlSize(.small)
                            .disabled(isRunning)
                        }
                    }
                }
                .padding(8)
            }

            // 2. Actions Toolbar
            HStack(spacing: 10) {
                Button {
                    importSerialsCSV()
                } label: {
                    Label("Import Serials CSV...", systemImage: "tray.and.arrow.down")
                }
                .disabled(isRunning)

                Text(csvFileName)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)

                Spacer()

                Toggle("Raw JSON", isOn: $showRawInspector)
                    .toggleStyle(.checkbox)

                if isRunning {
                    Button(role: .destructive) {
                        currentTask?.cancel()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                } else if canResumeRemaining {
                    Button {
                        startBatchCheck(onlyRemaining: true)
                    } label: {
                        Label("Resume (\(remainingIndices.count))", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasValidCredentials)

                    Button {
                        startBatchCheck(onlyRemaining: false)
                    } label: {
                        Label("Restart All", systemImage: "arrow.clockwise")
                    }
                    .disabled(!hasValidCredentials)
                } else {
                    Button {
                        startBatchCheck(onlyRemaining: false)
                    } label: {
                        Label("Check Activation Lock", systemImage: "lock.shield")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canStartCheck)
                }

                Button {
                    exportResultsCSV()
                } label: {
                    Label("Export CSV...", systemImage: "square.and.arrow.up")
                }
                .disabled(records.isEmpty || isRunning)
            }

            // 3. Live Pacing, Cooldown & ETA Banner
            if !records.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Image(systemName: phaseIconName)
                                .foregroundStyle(phaseAccentColor)

                            Text(phaseStatusText)
                                .font(.callout)
                                .fontWeight(.medium)
                                .monospacedDigit()
                                .lineLimit(1)

                            Spacer()

                            if isRunning || remainingIndices.count > 0 {
                                Text("Est. remaining: \(formatDuration(etaSeconds))")
                                    .font(.callout)
                                    .monospacedDigit()
                                    .foregroundStyle(Color.secondary)
                            }
                        }

                        HStack(spacing: 12) {
                            ProgressView(value: Double(completedCount), total: Double(max(records.count, 1)))

                            Text("\(completedCount) / \(records.count)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Color.secondary)
                                .frame(minWidth: 70, alignment: .trailing)
                        }

                        HStack(spacing: 16) {
                            statusSummaryLabel("Locked", count: count(for: .locked), color: Color.red)
                            statusSummaryLabel("Unlocked", count: count(for: .unlocked), color: Color.green)
                            statusSummaryLabel("Not Found", count: count(for: .notFound), color: Color.orange)
                            statusSummaryLabel("Errors", count: count(for: .error), color: Color.orange)
                            Spacer()
                            Text("Even cadence: 1 device every 3.2s (~18.8 req/min)")
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                    .padding(6)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(Color.red)
                    .font(.callout)
            }

            // 4. Selectable Results Table
            Table(records, selection: $selectedRecordID) {
                TableColumn("Serial Number", value: \.serialNumber)
                    .width(min: 115, ideal: 140)

                TableColumn("HTTP") { record in
                    Text(record.httpStatusCode.map(String.init) ?? "-")
                        .monospacedDigit()
                        .foregroundStyle(Color.secondary)
                }
                .width(min: 45, ideal: 55)

                TableColumn("Status") { record in
                    Text(record.status.rawValue)
                        .fontWeight(.medium)
                        .foregroundStyle(color(for: record.status))
                }
                .width(min: 90, ideal: 105)

                TableColumn("Locked", value: \.isLockedText)
                    .width(min: 65, ideal: 75)

                TableColumn("Lock Type", value: \.lockType)
                    .width(min: 80, ideal: 95)

                TableColumn("Details", value: \.details)
            }

            // 5. Raw ASM API Response Inspector (Hidden by default)
            if showRawInspector {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: "curlybraces")
                                .foregroundStyle(Color.blue)

                            if let inspected = inspectedRecord {
                                Text("Raw API Response — \(inspected.serialNumber)")
                                    .font(.callout)
                                    .fontWeight(.semibold)

                                if let code = inspected.httpStatusCode {
                                    Text("HTTP \(code)")
                                        .font(.caption)
                                        .monospacedDigit()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.secondary.opacity(0.15))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }

                                if selectedRecordID == nil {
                                    Text("(Following latest — click any row to pin)")
                                        .font(.caption)
                                        .foregroundStyle(Color.secondary)
                                } else {
                                    Button("Follow Latest") {
                                        selectedRecordID = nil
                                    }
                                    .controlSize(.small)
                                }

                                Spacer()

                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(inspected.rawResponse, forType: .string)
                                } label: {
                                    Label("Copy JSON", systemImage: "doc.on.doc")
                                }
                                .controlSize(.small)
                                .disabled(inspected.rawResponse.isEmpty)
                            } else {
                                Text("Raw API Response Inspector")
                                    .font(.callout)
                                    .fontWeight(.semibold)
                                Spacer()
                            }
                        }

                        ScrollView {
                            Text(rawInspectorBodyText)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(inspectedRecord?.rawResponse.isEmpty == false ? Color.primary : Color.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 145)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(4)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 900, minHeight: 560)
        .onAppear {
            loadCredentialsOnLaunch()
        }
    }

    // MARK: - Keychain Persistence

    private var currentCredentialsSnapshot: StoredASMCredentials {
        StoredASMCredentials(
            clientId: clientId,
            keyId: keyId,
            pemContent: pemContent,
            pemFileName: pemContent.isEmpty ? "" : pemFileName
        )
    }

    private var hasAnyCredentialInput: Bool {
        !currentCredentialsSnapshot.isEmpty
    }

    private func loadCredentialsOnLaunch() {
        guard !didLoadInitialCredentials else { return }
        didLoadInitialCredentials = true

        let defaults = UserDefaults.standard
        let legacyClientId = defaults.string(forKey: "asm_client_id") ?? ""
        let legacyKeyId = defaults.string(forKey: "asm_key_id") ?? ""

        do {
            if let stored = try KeychainHelper.loadCredentials() {
                lastSavedCredentials = stored
                clientId = stored.clientId
                keyId = stored.keyId
                pemContent = stored.pemContent
                pemFileName = stored.pemContent.isEmpty
                    ? "No .pem file selected"
                    : (stored.pemFileName.isEmpty ? "Saved in Keychain" : stored.pemFileName)
                updateKeychainStatusText(for: stored)

                defaults.removeObject(forKey: "asm_client_id")
                defaults.removeObject(forKey: "asm_key_id")
            } else if !legacyClientId.isEmpty || !legacyKeyId.isEmpty {
                // One-time migration from earlier @AppStorage UserDefaults keys
                let migrated = StoredASMCredentials(
                    clientId: legacyClientId,
                    keyId: legacyKeyId,
                    pemContent: "",
                    pemFileName: ""
                )
                try KeychainHelper.saveCredentials(migrated)
                lastSavedCredentials = migrated
                clientId = legacyClientId
                keyId = legacyKeyId
                updateKeychainStatusText(for: migrated)

                defaults.removeObject(forKey: "asm_client_id")
                defaults.removeObject(forKey: "asm_key_id")
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func scheduleKeychainSave() {
        guard didLoadInitialCredentials else { return }
        saveDebounceTask?.cancel()
        saveDebounceTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            if Task.isCancelled { return }
            persistCredentialsNow()
        }
    }

    private func persistCredentialsNow() {
        saveDebounceTask?.cancel()
        let snapshot = currentCredentialsSnapshot
        guard snapshot != lastSavedCredentials else { return }

        do {
            try KeychainHelper.saveCredentials(snapshot)
            lastSavedCredentials = snapshot
            updateKeychainStatusText(for: snapshot)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearCredentialsFromKeychain() {
        saveDebounceTask?.cancel()
        do {
            try KeychainHelper.deleteCredentials()
            lastSavedCredentials = .empty
            clientId = ""
            keyId = ""
            pemContent = ""
            pemFileName = "No .pem file selected"
            keychainStatusMessage = "Cleared saved credentials from macOS Keychain"
            apiClient.resetToken()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateKeychainStatusText(for credentials: StoredASMCredentials) {
        if credentials.isEmpty {
            keychainStatusMessage = "Credentials are not yet saved in Keychain"
        } else if !credentials.clientId.isEmpty && !credentials.keyId.isEmpty && !credentials.pemContent.isEmpty {
            keychainStatusMessage = "Client ID, Key ID, and .pem private key saved in macOS Keychain"
        } else {
            keychainStatusMessage = "Partial credentials saved in macOS Keychain (select .pem key to complete)"
        }
    }

    // MARK: - Computed Helpers

    private var inspectedRecord: DeviceLockRecord? {
        if let selectedRecordID,
           let match = records.first(where: { $0.id == selectedRecordID }) {
            return match
        }
        return records.last(where: { !$0.rawResponse.isEmpty })
    }

    private var rawInspectorBodyText: String {
        guard let inspected = inspectedRecord else {
            return "Run a check (or click a completed row in the table above) to inspect the raw JSON returned by https://api-school.apple.com/v1/orgDevices/{id}/activationLockStatus."
        }
        if inspected.rawResponse.isEmpty {
            return "No API response recorded yet for \(inspected.serialNumber) (\(inspected.status.rawValue))."
        }
        return inspected.rawResponse
    }

    private var hasValidCredentials: Bool {
        !clientId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !keyId.trimmingCharacters(in: .whitespaces).isEmpty &&
        !pemContent.isEmpty
    }

    private var canStartCheck: Bool {
        hasValidCredentials && !records.isEmpty
    }

    private var remainingIndices: [Int] {
        records.indices.filter {
            records[$0].status == .pending ||
            records[$0].status == .error ||
            records[$0].status == .checking
        }
    }

    private var hasCompletedAny: Bool {
        records.contains {
            $0.status == .locked || $0.status == .unlocked || $0.status == .notFound
        }
    }

    private var canResumeRemaining: Bool {
        hasCompletedAny && !remainingIndices.isEmpty
    }

    private var phaseIconName: String {
        guard isRunning else {
            return remainingIndices.isEmpty ? "checkmark.circle.fill" : "clock"
        }
        switch currentPhase {
        case .steadyPacing:
            return "metronome"
        case .serverCooldown:
            return "hourglass"
        case .networkRetry:
            return "exclamationmark.triangle.fill"
        case .requesting, .none:
            return "arrow.triangle.2.circlepath"
        }
    }

    private var phaseAccentColor: Color {
        guard isRunning else {
            return remainingIndices.isEmpty ? Color.green : Color.secondary
        }
        switch currentPhase {
        case .steadyPacing, .requesting, .none:
            return Color.blue
        case .serverCooldown, .networkRetry:
            return Color.orange
        }
    }

    private var phaseStatusText: String {
        guard isRunning else {
            if remainingIndices.isEmpty {
                return "Completed all \(records.count) devices"
            } else if hasCompletedAny {
                return "Paused — \(remainingIndices.count) devices remaining (including any errors)"
            } else {
                return "Ready to check \(records.count) devices"
            }
        }

        switch currentPhase {
        case .steadyPacing(let seconds):
            return String(format: "Even pacing (18.8/min) — next lookup in %.1fs", seconds)
        case .serverCooldown(let seconds):
            return String(format: "Apple API rate-limit cooldown — resuming in %.1fs", seconds)
        case .networkRetry(let attempt, let maxAttempts, let seconds):
            return String(format: "Connection dropped — retry %d/%d in %.1fs", attempt, maxAttempts, seconds)
        case .requesting(let serial):
            return "Querying Apple School Manager for \(serial)..."
        case .none:
            return "Authenticating with Apple School Manager..."
        }
    }

    private func count(for status: DeviceLockRecord.RecordStatus) -> Int {
        records.reduce(into: 0) { total, item in
            if item.status == status { total += 1 }
        }
    }

    @ViewBuilder
    private func statusSummaryLabel(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(count > 0 ? color : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text("\(title): \(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(count > 0 ? Color.primary : Color.secondary)
        }
    }

    private func color(for status: DeviceLockRecord.RecordStatus) -> Color {
        switch status {
        case .locked: return Color.red
        case .unlocked: return Color.green
        case .notFound, .error: return Color.orange
        case .checking: return Color.blue
        case .pending: return Color.secondary
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let totalSeconds = Int(ceil(max(seconds, 0)))
        if totalSeconds <= 0 { return "0s" }
        if totalSeconds < 60 { return "\(totalSeconds)s" }

        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60

        if hours > 0 {
            return String(format: "%dh %02dm %02ds", hours, minutes, secs)
        } else {
            return String(format: "%dm %02ds", minutes, secs)
        }
    }

    // MARK: - File Operations

    private func selectPEMFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Apple School Manager Private Key (.pem)"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        let pemType = UTType(filenameExtension: "pem")
        panel.allowedContentTypes = [pemType, .plainText, .data].compactMap { $0 }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            pemContent = try String(contentsOf: url, encoding: .utf8)
            pemFileName = url.lastPathComponent
            apiClient.resetToken()
            errorMessage = nil
            persistCredentialsNow()
        } catch {
            errorMessage = "Could not read .pem file: \(error.localizedDescription)"
        }
    }

    private func importSerialsCSV() {
        let panel = NSOpenPanel()
        panel.title = "Select CSV Containing Device Serial Numbers"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            let serials = CSVHelper.extractSerialNumbers(from: content)
            records = serials.map { DeviceLockRecord(serialNumber: $0) }
            selectedRecordID = nil
            csvFileName = "\(url.lastPathComponent) (\(serials.count) devices)"
            completedCount = 0
            currentPhase = nil
            etaSeconds = apiClient.estimatedSecondsRemaining(
                uncompletedCount: records.count,
                currentPhase: nil
            )
            errorMessage = serials.isEmpty ? "No serial numbers found in selected CSV." : nil
        } catch {
            errorMessage = "Could not read CSV file: \(error.localizedDescription)"
        }
    }

    private func exportResultsCSV() {
        let panel = NSSavePanel()
        panel.title = "Export Activation Lock Status CSV"
        panel.nameFieldStringValue = "ActivationLockReport.csv"
        panel.allowedContentTypes = [.commaSeparatedText]

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        do {
            let csvOutput = CSVHelper.generateCSV(from: records)
            try csvOutput.write(to: url, atomically: true, encoding: .utf8)
            errorMessage = nil
        } catch {
            errorMessage = "Failed to save CSV: \(error.localizedDescription)"
        }
    }

    // MARK: - Batch Execution

    private func startBatchCheck(onlyRemaining: Bool) {
        persistCredentialsNow()
        errorMessage = nil
        isRunning = true
        currentPhase = nil

        let targetIndices: [Int]
        if onlyRemaining {
            targetIndices = remainingIndices
            for idx in targetIndices {
                records[idx].status = .pending
                records[idx].details = "Queued..."
            }
        } else {
            targetIndices = Array(records.indices)
            for idx in targetIndices {
                records[idx].status = .pending
                records[idx].isLockedText = "-"
                records[idx].lockType = "-"
                records[idx].details = "Queued..."
                records[idx].httpStatusCode = nil
                records[idx].rawResponse = ""
            }
        }

        completedCount = records.count - targetIndices.count
        etaSeconds = apiClient.estimatedSecondsRemaining(
            uncompletedCount: targetIndices.count,
            currentPhase: nil
        )

        currentTask = Task {
            defer {
                isRunning = false
                currentPhase = nil
                etaSeconds = apiClient.estimatedSecondsRemaining(
                    uncompletedCount: remainingIndices.count,
                    currentPhase: nil
                )
            }

            for (offset, index) in targetIndices.enumerated() {
                if Task.isCancelled { break }

                let uncompleted = targetIndices.count - offset
                let serial = records[index].serialNumber
                records[index].status = .checking
                records[index].details = "Waiting for next 3.2s slot..."

                do {
                    let result = try await apiClient.fetchActivationLockStatus(
                        serialNumber: serial,
                        clientId: clientId,
                        keyId: keyId,
                        pemKey: pemContent,
                        onPhaseChange: { phase in
                            currentPhase = phase
                            etaSeconds = apiClient.estimatedSecondsRemaining(
                                uncompletedCount: uncompleted,
                                currentPhase: phase
                            )
                        }
                    )
                    records[index].status = result.status
                    records[index].isLockedText = result.isLocked
                    records[index].lockType = result.lockType
                    records[index].details = result.details
                    records[index].httpStatusCode = result.httpStatusCode
                    records[index].rawResponse = result.rawResponse
                    completedCount += 1
                    etaSeconds = apiClient.estimatedSecondsRemaining(
                        uncompletedCount: uncompleted - 1,
                        currentPhase: nil
                    )
                } catch is CancellationError {
                    records[index].status = .pending
                    records[index].details = "Paused"
                    break
                } catch let asmError as ASMError {
                    records[index].status = .error
                    records[index].details = asmError.localizedDescription
                    errorMessage = asmError.localizedDescription
                    break
                } catch {
                    records[index].status = .error
                    records[index].isLockedText = "ERROR"
                    records[index].lockType = "N/A"
                    records[index].details = error.localizedDescription
                    completedCount += 1
                }
            }
        }
    }
}
