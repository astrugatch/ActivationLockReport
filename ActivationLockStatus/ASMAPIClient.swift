import Foundation
import CryptoKit

enum ASMPacingPhase: Sendable, Equatable {
    case steadyPacing(secondsRemaining: Double)
    case serverCooldown(secondsRemaining: Double)
    case networkRetry(attempt: Int, maxAttempts: Int, secondsRemaining: Double)
    case requesting(serialNumber: String)
}

@MainActor
final class ASMAPIClient {
    private var cachedToken: String?
    private var tokenExpiration: Date = .distantPast

    // Uniform start-to-start cadence: 1 request every 3.20s (~18.75 req/min).
    let requestIntervalSeconds: Double = 3.20
    private var nextAllowedRequestDate: Date = .distantPast

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()

    private struct JWTHeader: Encodable {
        let alg = "ES256"
        let kid: String
        let typ = "JWT"
    }

    private struct JWTPayload: Encodable {
        let iss: String
        let sub: String
        let aud = "https://account.apple.com/auth/oauth2/v2/token"
        let iat: Int
        let exp: Int
        let jti: String
    }

    func resetToken() {
        cachedToken = nil
        tokenExpiration = .distantPast
    }

    /// Estimates remaining wall-clock seconds for `uncompletedCount` devices under uniform pacing.
    func estimatedSecondsRemaining(
        uncompletedCount: Int,
        currentPhase: ASMPacingPhase?
    ) -> TimeInterval {
        guard uncompletedCount > 0 else { return 0 }

        let avgRequestRTT: Double = 0.45
        let remainingAfterCurrent = max(uncompletedCount - 1, 0)

        guard let phase = currentPhase else {
            let initialWait = max(nextAllowedRequestDate.timeIntervalSinceNow, 0)
            return initialWait + Double(remainingAfterCurrent) * requestIntervalSeconds + avgRequestRTT
        }

        switch phase {
        case .steadyPacing(let waitLeft),
             .serverCooldown(let waitLeft),
             .networkRetry(_, _, let waitLeft):
            return waitLeft + Double(remainingAfterCurrent) * requestIntervalSeconds + avgRequestRTT

        case .requesting:
            if remainingAfterCurrent == 0 {
                return avgRequestRTT
            }
            let waitUntilNextStarts = max(nextAllowedRequestDate.timeIntervalSinceNow, 0)
            return waitUntilNextStarts + Double(remainingAfterCurrent - 1) * requestIntervalSeconds + avgRequestRTT
        }
    }

    /// Checks Activation Lock status and captures the raw HTTP status code and JSON body.
    func fetchActivationLockStatus(
        serialNumber: String,
        clientId: String,
        keyId: String,
        pemKey: String,
        allowAuthRetry: Bool = true,
        onPhaseChange: (@MainActor (ASMPacingPhase) -> Void)? = nil
    ) async throws -> ASMLookupResult {
        try Task.checkCancellation()

        let token = try await validAccessToken(clientId: clientId, keyId: keyId, pemKey: pemKey)

        try await acquireUniformSlot(onPhaseChange: onPhaseChange)
        onPhaseChange?(.requesting(serialNumber: serialNumber))

        let baseEndpoint = URL(string: "https://api-school.apple.com/v1/orgDevices")!
            .appendingPathComponent(serialNumber)
            .appendingPathComponent("activationLockStatus")
        var urlComponents = URLComponents(url: baseEndpoint, resolvingAgainstBaseURL: false)
        urlComponents?.queryItems = [
            URLQueryItem(name: "fields[activationLockStatus]", value: "isLocked,lockType")
        ]
        let endpoint = urlComponents?.url ?? baseEndpoint

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var httpAttempt = 0
        while true {
            try Task.checkCancellation()

            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await performDataRequest(request) { attempt, maxAttempts, remaining in
                    onPhaseChange?(.networkRetry(attempt: attempt, maxAttempts: maxAttempts, secondsRemaining: remaining))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let errText = "Request failed before receiving HTTP response:\n\(error.localizedDescription)"
                print("[ASM API] \(serialNumber) (Network Error):\n\(errText)\n")
                return ASMLookupResult(
                    status: .error,
                    isLocked: "ERROR",
                    lockType: "N/A",
                    details: "Network error: \(error.localizedDescription)",
                    httpStatusCode: nil,
                    rawResponse: errText
                )
            }

            let rawText = formatRawJSON(data)
            print("[ASM API] \(serialNumber) (HTTP \(http.statusCode)):\n\(rawText)\n")

            switch http.statusCode {
            case 200:
                do {
                    let decoded = try JSONDecoder().decode(ActivationLockStatusResponse.self, from: data)
                    guard let locked = decoded.data.attributes?.isLocked else {
                        return ASMLookupResult(
                            status: .error,
                            isLocked: "UNKNOWN",
                            lockType: decoded.data.attributes?.lockType ?? "N/A",
                            details: "HTTP 200, but attributes.isLocked was missing/null — inspect Raw JSON",
                            httpStatusCode: http.statusCode,
                            rawResponse: rawText
                        )
                    }
                    let lockType = decoded.data.attributes?.lockType ?? (locked ? "Unknown" : "None")
                    return ASMLookupResult(
                        status: locked ? .locked : .unlocked,
                        isLocked: locked ? "TRUE" : "FALSE",
                        lockType: lockType,
                        details: locked ? "Activation Lock is active (\(lockType))" : "Activation Lock is off",
                        httpStatusCode: http.statusCode,
                        rawResponse: rawText
                    )
                } catch {
                    return ASMLookupResult(
                        status: .error,
                        isLocked: "ERROR",
                        lockType: "N/A",
                        details: "Decode error: \(error.localizedDescription)",
                        httpStatusCode: http.statusCode,
                        rawResponse: rawText
                    )
                }

            case 401 where allowAuthRetry:
                resetToken()
                return try await fetchActivationLockStatus(
                    serialNumber: serialNumber,
                    clientId: clientId,
                    keyId: keyId,
                    pemKey: pemKey,
                    allowAuthRetry: false,
                    onPhaseChange: onPhaseChange
                )

            case 403:
                return ASMLookupResult(
                    status: .error,
                    isLocked: "ERROR",
                    lockType: "N/A",
                    details: "HTTP 403 Forbidden: Check API account privileges",
                    httpStatusCode: http.statusCode,
                    rawResponse: rawText
                )

            case 404:
                return ASMLookupResult(
                    status: .notFound,
                    isLocked: "N/A",
                    lockType: "N/A",
                    details: "Device not managed in Apple School Manager",
                    httpStatusCode: http.statusCode,
                    rawResponse: rawText
                )

            case 429, 500, 502, 503, 504:
                if httpAttempt < 4 {
                    httpAttempt += 1
                    let fallbackWait = http.statusCode == 429 ? Double(httpAttempt * 5) : Double(httpAttempt * 3)
                    let retryAfter = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? fallbackWait
                    try await sleepWithCountdown(seconds: retryAfter) { remaining in
                        onPhaseChange?(.serverCooldown(secondsRemaining: remaining))
                    }
                    nextAllowedRequestDate = Date().addingTimeInterval(requestIntervalSeconds)
                    onPhaseChange?(.requesting(serialNumber: serialNumber))
                    continue
                }
                let bodySnippet = String(data: data, encoding: .utf8)?.prefix(160) ?? "Server busy"
                return ASMLookupResult(
                    status: .error,
                    isLocked: "ERROR",
                    lockType: "N/A",
                    details: "HTTP \(http.statusCode): \(bodySnippet)",
                    httpStatusCode: http.statusCode,
                    rawResponse: rawText
                )

            default:
                let bodySnippet = String(data: data, encoding: .utf8)?.prefix(160) ?? "Unknown error"
                return ASMLookupResult(
                    status: .error,
                    isLocked: "ERROR",
                    lockType: "N/A",
                    details: "HTTP \(http.statusCode): \(bodySnippet)",
                    httpStatusCode: http.statusCode,
                    rawResponse: rawText
                )
            }
        }
    }

    private func formatRawJSON(_ data: Data) -> String {
        guard !data.isEmpty else { return "(Empty HTTP response body)" }
        if let jsonObject = try? JSONSerialization.jsonObject(with: data),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyString = String(data: prettyData, encoding: .utf8) {
            return prettyString
        }
        return String(data: data, encoding: .utf8) ?? "(\(data.count) bytes non-UTF8 response)"
    }

    // MARK: - Uniform Start-to-Start Pacing

    private func acquireUniformSlot(
        onPhaseChange: (@MainActor (ASMPacingPhase) -> Void)?
    ) async throws {
        while true {
            try Task.checkCancellation()
            let waitRemaining = nextAllowedRequestDate.timeIntervalSinceNow
            if waitRemaining <= 0.01 {
                break
            }
            onPhaseChange?(.steadyPacing(secondsRemaining: waitRemaining))
            try await Task.sleep(for: .seconds(min(waitRemaining, 0.15)))
        }

        nextAllowedRequestDate = Date().addingTimeInterval(requestIntervalSeconds)
    }

    private func sleepWithCountdown(
        seconds: Double,
        onTick: @MainActor (Double) -> Void
    ) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { break }
            onTick(remaining)
            try await Task.sleep(for: .seconds(min(remaining, 0.15)))
        }
    }

    // MARK: - Resilient Network Execution

    private func performDataRequest(
        _ request: URLRequest,
        maxRetries: Int = 4,
        onRetryTick: (@MainActor (Int, Int, Double) -> Void)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0

        while true {
            try Task.checkCancellation()

            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw ASMError.invalidResponse
                }
                return (data, http)
            } catch is CancellationError {
                throw CancellationError()
            } catch let urlError as URLError where urlError.code == .cancelled {
                throw CancellationError()
            } catch let urlError as URLError where isTransientNetworkError(urlError) && attempt < maxRetries {
                attempt += 1
                let delaySeconds = pow(2.0, Double(attempt - 1))
                try await sleepWithCountdown(seconds: delaySeconds) { remaining in
                    onRetryTick?(attempt, maxRetries, remaining)
                }
                nextAllowedRequestDate = Date().addingTimeInterval(requestIntervalSeconds)
                continue
            }
        }
    }

    private func isTransientNetworkError(_ error: URLError) -> Bool {
        switch error.code {
        case .networkConnectionLost,
             .timedOut,
             .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .resourceUnavailable:
            return true
        default:
            return false
        }
    }

    // MARK: - OAuth 2.0 Token Management

    private func validAccessToken(clientId: String, keyId: String, pemKey: String) async throws -> String {
        if let token = cachedToken, Date() < tokenExpiration {
            return token
        }

        let cleanClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanKeyId = keyId.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPEM = pemKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanClientId.isEmpty, !cleanKeyId.isEmpty, !cleanPEM.isEmpty else {
            throw ASMError.invalidCredentials
        }

        let assertion = try createClientAssertionJWT(
            clientId: cleanClientId,
            keyId: cleanKeyId,
            pemKey: cleanPEM
        )

        let tokenURL = URL(string: "https://account.apple.com/auth/oauth2/token")!
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let bodyPairs = [
            ("grant_type", "client_credentials"),
            ("client_id", cleanClientId),
            ("client_assertion", assertion),
            ("client_assertion_type", "urn:ietf:params:oauth:client-assertion-type:jwt-bearer"),
            ("scope", "school.api")
        ]
        let formBody = bodyPairs
            .map { "\(formURLEncode($0.0))=\(formURLEncode($0.1))" }
            .joined(separator: "&")
        request.httpBody = Data(formBody.utf8)

        let (data, http) = try await performDataRequest(request)

        guard http.statusCode == 200 else {
            let errorBody = String(data: data, encoding: .utf8) ?? "No response body"
            throw ASMError.tokenRequestFailed(http.statusCode, errorBody)
        }

        let tokenResponse = try JSONDecoder().decode(ASMTokenResponse.self, from: data)
        cachedToken = tokenResponse.access_token
        tokenExpiration = Date().addingTimeInterval(TimeInterval(max(tokenResponse.expires_in - 300, 60)))
        return tokenResponse.access_token
    }

    private func createClientAssertionJWT(clientId: String, keyId: String, pemKey: String) throws -> String {
        let privateKey = try parseP256PrivateKey(from: pemKey)

        let now = Int(Date().timeIntervalSince1970)
        let header = JWTHeader(kid: keyId)
        let payload = JWTPayload(
            iss: clientId,
            sub: clientId,
            iat: now,
            exp: now + 3600,
            jti: UUID().uuidString
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let headerB64 = try encoder.encode(header).base64URLEncodedString()
        let payloadB64 = try encoder.encode(payload).base64URLEncodedString()
        let signingInput = "\(headerB64).\(payloadB64)"

        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        let signatureB64 = signature.rawRepresentation.base64URLEncodedString()

        return "\(signingInput).\(signatureB64)"
    }

    // MARK: - PEM & ASN.1 Key Parsing

    private func parseP256PrivateKey(from pemString: String) throws -> P256.Signing.PrivateKey {
        let normalized = pemString
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let key = try? P256.Signing.PrivateKey(pemRepresentation: normalized) {
            return key
        }

        if normalized.contains("ENCRYPTED") {
            throw ASMError.invalidPEMKey("Private key is passphrase-encrypted. Decrypt it first.")
        }

        do {
            let derData = try extractPEMDerBytes(from: normalized)

            if let key = try? P256.Signing.PrivateKey(derRepresentation: derData) {
                return key
            }

            let rawScalar = try extractP256RawScalar(from: Array(derData))
            return try P256.Signing.PrivateKey(rawRepresentation: rawScalar)
        } catch let error as ASMError {
            throw error
        } catch {
            throw ASMError.invalidPEMKey(error.localizedDescription)
        }
    }

    private func extractPEMDerBytes(from pemString: String) throws -> Data {
        let lines = pemString.components(separatedBy: "\n")
        var base64Lines: [String] = []
        var insideKeyBlock = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.contains("RSA PRIVATE KEY") {
                throw ASMError.invalidPEMKey("RSA key detected; Apple School Manager requires an EC P-256 key.")
            }

            if line == "-----BEGIN EC PRIVATE KEY-----" || line == "-----BEGIN PRIVATE KEY-----" {
                insideKeyBlock = true
                base64Lines.removeAll()
                continue
            }

            if line == "-----END EC PRIVATE KEY-----" || line == "-----END PRIVATE KEY-----" {
                if insideKeyBlock && !base64Lines.isEmpty {
                    break
                }
                insideKeyBlock = false
                continue
            }

            if line.hasPrefix("-----") || line.contains(":") {
                continue
            }

            if insideKeyBlock {
                base64Lines.append(line)
            }
        }

        guard !base64Lines.isEmpty else {
            throw ASMError.invalidPEMKey("No PRIVATE KEY or EC PRIVATE KEY block found in .pem file.")
        }

        let joinedBase64 = base64Lines.joined()
        guard let derData = Data(base64Encoded: joinedBase64, options: .ignoreUnknownCharacters),
              !derData.isEmpty else {
            throw ASMError.invalidPEMKey("Base64 decoding of .pem content failed.")
        }

        return derData
    }

    private func extractP256RawScalar(from derBytes: [UInt8]) throws -> Data {
        var cursor = 0
        let root = try readASN1TLV(from: derBytes, cursor: &cursor)
        guard root.tag == 0x30 else {
            throw ASMError.invalidPEMKey("Expected ASN.1 SEQUENCE at root of private key.")
        }

        var seqCursor = 0
        let version = try readASN1TLV(from: root.value, cursor: &seqCursor)
        guard version.tag == 0x02 else {
            throw ASMError.invalidPEMKey("Expected ASN.1 INTEGER version field.")
        }

        if version.value == [0x01] {
            let privateKeyOctets = try readASN1TLV(from: root.value, cursor: &seqCursor)
            guard privateKeyOctets.tag == 0x04 else {
                throw ASMError.invalidPEMKey("Expected ASN.1 OCTET STRING for EC private key.")
            }
            return try normalizeP256Scalar(privateKeyOctets.value)

        } else if version.value == [0x00] || version.value.isEmpty {
            let algorithm = try readASN1TLV(from: root.value, cursor: &seqCursor)
            guard algorithm.tag == 0x30 else {
                throw ASMError.invalidPEMKey("Expected ASN.1 SEQUENCE for PKCS#8 algorithm identifier.")
            }
            let wrappedKey = try readASN1TLV(from: root.value, cursor: &seqCursor)
            guard wrappedKey.tag == 0x04 else {
                throw ASMError.invalidPEMKey("Expected ASN.1 OCTET STRING for PKCS#8 key payload.")
            }
            if wrappedKey.value.count == 32 && wrappedKey.value.first != 0x30 {
                return Data(wrappedKey.value)
            }
            return try extractP256RawScalar(from: wrappedKey.value)

        } else {
            throw ASMError.invalidPEMKey("Unsupported ASN.1 private key version.")
        }
    }

    private func normalizeP256Scalar(_ bytes: [UInt8]) throws -> Data {
        if bytes.count == 32 {
            return Data(bytes)
        } else if bytes.count == 33 && bytes[0] == 0x00 {
            return Data(bytes.dropFirst())
        } else if !bytes.isEmpty && bytes.count < 32 {
            return Data(repeating: 0, count: 32 - bytes.count) + Data(bytes)
        } else {
            throw ASMError.invalidPEMKey("Expected a 32-byte P-256 key scalar, found \(bytes.count) bytes.")
        }
    }

    private func readASN1TLV(from bytes: [UInt8], cursor: inout Int) throws -> (tag: UInt8, value: [UInt8]) {
        guard cursor < bytes.count else {
            throw ASMError.invalidPEMKey("Unexpected end of ASN.1 key data.")
        }
        let tag = bytes[cursor]
        cursor += 1

        guard cursor < bytes.count else {
            throw ASMError.invalidPEMKey("Missing ASN.1 length byte.")
        }
        let firstLenByte = bytes[cursor]
        cursor += 1

        let length: Int
        if (firstLenByte & 0x80) == 0 {
            length = Int(firstLenByte)
        } else {
            let octetCount = Int(firstLenByte & 0x7F)
            guard octetCount > 0, octetCount <= 4, cursor + octetCount <= bytes.count else {
                throw ASMError.invalidPEMKey("Invalid ASN.1 length encoding.")
            }
            var computedLength = 0
            for _ in 0..<octetCount {
                computedLength = (computedLength << 8) | Int(bytes[cursor])
                cursor += 1
            }
            length = computedLength
        }

        guard length >= 0, cursor + length <= bytes.count else {
            throw ASMError.invalidPEMKey("Truncated ASN.1 field in key.")
        }

        let value = Array(bytes[cursor..<(cursor + length)])
        cursor += length
        return (tag, value)
    }

    private func formURLEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
