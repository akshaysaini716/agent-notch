import Foundation

/// The changed lines of an edit, for the permission card's preview.
public enum DiffPreview {
    public struct Line: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case added, removed }
        public var kind: Kind
        public var text: String
    }

    /// Removed lines then added lines, with the unchanged lines both sides share at the start and
    /// end dropped. At most `limit` lines; `hidden` counts the rest.
    public static func lines(old: String, new: String, limit: Int) -> (lines: [Line], hidden: Int) {
        var a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        var b = new.isEmpty ? [] : new.components(separatedBy: "\n")
        while let x = a.first, let y = b.first, x == y { a.removeFirst(); b.removeFirst() }
        while let x = a.last, let y = b.last, x == y { a.removeLast(); b.removeLast() }

        // Drop the indentation every changed line shares, so the code itself fits on the card.
        let indent = (a + b).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
        let all = a.map { Line(kind: .removed, text: String($0.dropFirst(min(indent, $0.count)))) }
            + b.map { Line(kind: .added, text: String($0.dropFirst(min(indent, $0.count)))) }
        guard all.count > limit else { return (all, 0) }
        // Keep both sides visible when the change is large.
        let removedShown = min(a.count, max(limit / 2, limit - b.count))
        let addedShown = limit - removedShown
        let shown = Array(all.prefix(removedShown)) + Array(all.dropFirst(a.count).prefix(addedShown))
        return (shown, all.count - shown.count)
    }
}
