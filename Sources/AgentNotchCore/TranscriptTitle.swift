import Foundation

/// Reads a session's title from its transcript (`transcript_path` in every hook payload):
/// the title Claude generates, `{"type":"ai-title","aiTitle":"…"}`, which is what `/resume` lists.
/// A `customTitle` (a name you set) wins when present.
public enum TranscriptTitle {
    /// Transcripts grow to tens of MB; titles are re-written as the session goes, so the latest
    /// one is almost always in the last chunk.
    public static let chunkSize = 1 << 20

    /// Latest title in the file, reading backwards from the end one chunk at a time.
    public static func read(path: String, chunkSize: Int = chunkSize) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }

        var end = size
        // Bytes of a line cut off at the start of the previous (later) chunk.
        var carry = Data()
        while end > 0 {
            let start = end > UInt64(chunkSize) ? end - UInt64(chunkSize) : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let chunk = try? handle.read(upToCount: Int(end - start)) else { return nil }
            var data = chunk + carry
            // Unless this is the start of the file, the first line may be partial: keep it for the next round.
            if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                carry = data[data.startIndex..<newline]
                data = data[newline...]
            } else {
                carry = Data()
            }
            if let title = latest(in: data) { return title }
            end = start
        }
        return nil
    }

    /// The last title in a run of JSONL lines.
    public static func latest(in data: Data) -> String? {
        var custom: String?
        var generated: String?
        for line in data.split(separator: UInt8(ascii: "\n")) {
            // Cheap filter before parsing: most lines are messages and tool output.
            guard line.count < 4096,
                  line.range(of: Data("Title\"".utf8)) != nil,
                  let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let title = clean(json["customTitle"]) { custom = title }
            if let title = clean(json["aiTitle"]) { generated = title }
        }
        return custom ?? generated
    }

    private static func clean(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
