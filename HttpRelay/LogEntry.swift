import Foundation

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let host: String
    let port: Int
    let status: LogStatus

    enum LogStatus: String, Equatable {
        case connect = "CONNECT"
        case connected = "200 OK"
        case closed = "CLOSED"
        case error = "ERROR"
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }

    var displayString: String {
        "\(formattedTime)  \(host):\(port)  \(status.rawValue)"
    }
}
