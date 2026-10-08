import Foundation

public struct HTTPRequest: Equatable, Sendable {
    public var method: String
    public var path: String
    /// Header names are lower-cased.
    public var headers: [String: String]
    public var body: Data
}

public enum HTTPParseResult: Equatable, Sendable {
    /// More bytes needed. `expectedTotal` is the full request size once the headers are known,
    /// so callers can wait for it instead of re-parsing on every read.
    case incomplete(expectedTotal: Int?)
    case complete(HTTPRequest)
    case invalid(String)
}

/// Minimal HTTP/1.1 request parser for the local hook endpoint: one request per connection,
/// `Content-Length` or chunked bodies.
public enum HTTPParser {
    public static let maxHeaderBytes = 64 * 1024
    /// Write/Edit payloads include whole file contents, so leave room.
    public static let maxBodyBytes = 32 * 1024 * 1024

    public static func parse(_ data: Data) -> HTTPParseResult {
        let bytes = [UInt8](data)
        guard let headerEnd = find([13, 10, 13, 10], in: bytes, from: 0) else {
            return bytes.count > maxHeaderBytes ? .invalid("headers too large") : .incomplete(expectedTotal: nil)
        }
        let head = String(decoding: bytes[0..<headerEnd], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("bad request line") }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headerEnd + 4
        let body: [UInt8]
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            switch decodeChunked(bytes, from: bodyStart) {
            case .incomplete: return .incomplete(expectedTotal: nil)
            case .invalid(let reason): return .invalid(reason)
            case .complete(let decoded): body = decoded
            }
        } else {
            guard let length = Int(headers["content-length"] ?? "0"), length >= 0 else {
                return .invalid("bad content-length")
            }
            guard length <= maxBodyBytes else { return .invalid("body too large") }
            guard bytes.count - bodyStart >= length else { return .incomplete(expectedTotal: bodyStart + length) }
            body = Array(bytes[bodyStart..<(bodyStart + length)])
        }

        let path = String(requestLine[1]).components(separatedBy: "?")[0]
        return .complete(HTTPRequest(method: String(requestLine[0]), path: path, headers: headers, body: Data(body)))
    }

    private enum Chunked {
        case incomplete
        case invalid(String)
        case complete([UInt8])
    }

    private static func decodeChunked(_ bytes: [UInt8], from start: Int) -> Chunked {
        var index = start
        var body: [UInt8] = []
        while true {
            guard let lineEnd = find([13, 10], in: bytes, from: index) else { return .incomplete }
            let sizeField = String(decoding: bytes[index..<lineEnd], as: UTF8.self)
                .split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard let size = Int(sizeField, radix: 16), size >= 0 else { return .invalid("bad chunk size") }
            index = lineEnd + 2
            if size == 0 { return .complete(body) }
            guard body.count + size <= maxBodyBytes else { return .invalid("body too large") }
            guard bytes.count >= index + size + 2 else { return .incomplete }
            body.append(contentsOf: bytes[index..<(index + size)])
            index += size + 2
        }
    }

    private static func find(_ needle: [UInt8], in bytes: [UInt8], from start: Int) -> Int? {
        guard bytes.count >= needle.count, start <= bytes.count - needle.count else { return nil }
        search: for index in start...(bytes.count - needle.count) {
            for (offset, byte) in needle.enumerated() where bytes[index + offset] != byte { continue search }
            return index
        }
        return nil
    }
}

public enum HTTPResponse {
    public static func make(status: Int, contentType: String = "application/json", body: Data) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 404: "Not Found"][status] ?? "Error"
        let head = "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: \(contentType)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }
}
