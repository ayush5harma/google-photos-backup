import Foundation

public enum ICloudCommand: String, Encodable, Sendable {
    case status, signIn = "sign-in", verify2FA = "verify-2fa", backup, reclaimStatus = "reclaim-status"
}

public struct ICloudRequest: Encodable, Sendable {
    public let command: ICloudCommand
    public let account: String?
    public let password: String?
    public let code: String?
    public let stateDir: String
    public let stagingDir: String?
    public let authData: String?

    enum CodingKeys: String, CodingKey {
        case command, account, password, code
        case stateDir = "state_dir"
        case stagingDir = "staging_dir"
        case authData = "auth_data"
    }

    public init(command: ICloudCommand, account: String?, stateDir: String, password: String? = nil,
                code: String? = nil, stagingDir: String? = nil, authData: String? = nil) {
        self.command = command
        self.account = account
        self.password = password
        self.code = code
        self.stateDir = stateDir
        self.stagingDir = stagingDir
        self.authData = authData
    }

    public func encoded() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(UInt8(ascii: "\n"))
        return data
    }
}

public enum ICloudAuthStatus: String, Sendable {
    case signedIn = "signed_in"
    case signedOut = "signed_out"
    case needs2FA = "needs_2fa"
}

/// 2026-10-15: A failed sign-in for another account must leave the last verified session reachable.
public struct ICloudAccountState: Equatable, Sendable {
    public private(set) var confirmedAccount: String?
    public private(set) var pendingAccount: String?

    public init(confirmedAccount: String?) {
        self.confirmedAccount = confirmedAccount
    }

    public var selectedAccount: String { pendingAccount ?? confirmedAccount ?? "" }
    public var hasSavedSession: Bool { confirmedAccount != nil }

    public mutating func beginSignIn(_ account: String) { pendingAccount = account }
    public mutating func beginAnotherAccount() { pendingAccount = "" }

    @discardableResult
    public mutating func useSavedSession() -> String? {
        pendingAccount = nil
        return confirmedAccount
    }

    @discardableResult
    public mutating func confirmSignIn() -> String? {
        if let pendingAccount, !pendingAccount.isEmpty { confirmedAccount = pendingAccount }
        pendingAccount = nil
        return confirmedAccount
    }
}

public enum ICloudEvent: Equatable, Sendable {
    case auth(ICloudAuthStatus)
    case progress(completed: Int, total: Int)
    case item(uploaded: Bool)
    case itemFailed
    case done(uploaded: Int, existing: Int, failed: Int, pending: Int)
    case stopped
    case reclaim(enabled: Bool)
    case failure(kind: String)
    case unknown

    public static func decode(_ data: Data) -> ICloudEvent? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        func int(_ key: String) -> Int { (object[key] as? NSNumber)?.intValue ?? 0 }
        switch type {
        case "auth":
            guard let status = object["status"] as? String,
                  let value = ICloudAuthStatus(rawValue: status) else { return nil }
            return .auth(value)
        case "progress":
            return .progress(completed: int("completed"), total: int("total"))
        case "item":
            return .item(uploaded: object["status"] as? String == "uploaded")
        case "item_failed": return .itemFailed
        case "done":
            return .done(uploaded: int("uploaded"), existing: int("existing"),
                         failed: int("failed"), pending: int("pending"))
        case "stopped": return .stopped
        case "reclaim": return .reclaim(enabled: object["enabled"] as? Bool == true)
        case "fatal": return .failure(kind: object["kind"] as? String ?? "unknown")
        default: return .unknown
        }
    }
}
