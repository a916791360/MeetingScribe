import Foundation
import Security

struct KeychainStore: Sendable {
    static let shared = KeychainStore()

    private let service = "MeetingScribe.summary-model"

    func string(for provider: SummaryModelProvider) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 这条凭据**存不存在**。刻意不返回密文。
    ///
    /// 为什么要单独一个方法：取密文（`kSecReturnData: true`）是一步需要解密的操作，
    /// 当应用的代码签名变了（自签名应用每次重新打包都会变），钥匙串里那条 ACL
    /// 就不再认得它，macOS 会**弹一个系统模态框要登录密码**。而这个框出现在
    /// `MeetingStore.init` 里 —— 于是 `NSApplicationMain` 还没跑完、
    /// **窗口根本没建出来**，用户看到的是"双击了没反应"。
    ///
    /// 只查属性、不取数据就不需要解密，也就不会弹框。所以启动只问"有没有"，
    /// 真的要用（打开设置看一眼 / 开始整理）时才去取密文，那会儿窗口已经在屏幕上了。
    func contains(for provider: SummaryModelProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    @discardableResult
    func save(_ value: String, for provider: SummaryModelProvider) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return true
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    func delete(for provider: SummaryModelProvider) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
