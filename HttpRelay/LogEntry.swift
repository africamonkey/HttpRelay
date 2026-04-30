import Foundation

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let host: String
    let port: Int
    let path: String
    let query: String?
    let method: HTTPMethod
    let requestHeaders: [String: String]
    var responseStatusCode: Int?
    var responseHeaders: [String: String]?
    var txBytes: Int64
    var rxBytes: Int64
    var duration: TimeInterval?

    enum HTTPMethod: String, Equatable, CaseIterable {
        case get = "GET"
        case post = "POST"
        case put = "PUT"
        case delete = "DELETE"
        case patch = "PATCH"
        case head = "HEAD"
        case options = "OPTIONS"
        case connect = "CONNECT"
        case unknown = "UNKNOWN"
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: timestamp)
    }

    var fullURL: String {
        if let query = query, !query.isEmpty {
            return "\(host):\(port)\(path)?\(query)"
        }
        return "\(host):\(port)\(path)"
    }

    var statusCodeCategory: String? {
        guard let code = responseStatusCode else { return nil }
        switch code {
        case 200..<300: return "2xx"
        case 300..<400: return "3xx"
        case 400..<500: return "4xx"
        case 500..<600: return "5xx"
        default: return nil
        }
    }

    var formattedDuration: String {
        guard let duration = duration else { return "—" }
        if duration < 1 {
            return String(format: "%.0fms", duration * 1000)
        }
        return String(format: "%.2fs", duration)
    }

    var formattedTxBytes: String {
        ByteCountFormatter.string(fromByteCount: txBytes, countStyle: .binary)
    }

    var formattedRxBytes: String {
        ByteCountFormatter.string(fromByteCount: rxBytes, countStyle: .binary)
    }

    var isFailed: Bool {
        guard let code = responseStatusCode else { return false }
        return code >= 400
    }

    static func == (lhs: LogEntry, rhs: LogEntry) -> Bool {
        lhs.id == rhs.id
    }
}
