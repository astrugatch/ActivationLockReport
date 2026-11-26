import Foundation

struct DeviceLockRecord: Identifiable {
    let id = UUID()
    let serialNumber: String
    var status: RecordStatus = .pending
    var isLockedText: String = "-"
    var lockType: String = "-"
    var details: String = "Waiting..."
    var httpStatusCode: Int? = nil
    var rawResponse: String = ""

    enum RecordStatus: String {
        case pending = "Pending"
        case checking = "Checking..."
        case locked = "Locked"
        case unlocked = "Unlocked"
        case notFound = "Not Found"
        case error = "Error"
    }
}

struct ASMLookupResult {
    let status: DeviceLockRecord.RecordStatus
    let isLocked: String
    let lockType: String
    let details: String
    let httpStatusCode: Int?
    let rawResponse: String
}

struct ASMTokenResponse: Decodable {
    let access_token: String
    let token_type: String
    let expires_in: Int
    let scope: String?
}

struct ActivationLockStatusResponse: Decodable {
    let data: ActivationLockData
}

struct ActivationLockData: Decodable {
    let id: String
    let type: String
    let attributes: ActivationLockAttributes?
}

struct ActivationLockAttributes: Decodable {
    let isLocked: Bool?
    let lockType: String?
}

enum ASMError: LocalizedError {
    case invalidCredentials
    case invalidPEMKey(String)
    case tokenRequestFailed(Int, String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidCredentials:
            return "Client ID, Key ID, and Private Key (.pem) are required."
        case .invalidPEMKey(let reason):
            return "Failed to parse .pem private key: \(reason)"
        case .tokenRequestFailed(let code, let body):
            return "OAuth token request failed (HTTP \(code)): \(body)"
        case .invalidResponse:
            return "Received an invalid response from Apple servers."
        }
    }
}
