import Foundation

public enum UpdateConfiguration {
    public static func isValid(feed: String, publicKey: String) -> Bool {
        guard let url = URLComponents(string: feed), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              let decoded = Data(base64Encoded: publicKey), decoded.count == 32 else { return false }
        return !feed.contains("$(") && !publicKey.contains("$(")
    }
}
