import DowlioCore

/// Which downloads are selected, changed the way Finder changes a selection of files.
public struct RowSelection: Equatable, Sendable {
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
    }

    public private(set) var selected: Set<DownloadID> = []
    /// The row a range starts from: the last one clicked without ⇧.
    private var anchor: DownloadID?
    /// The moving end of a range made with ⇧ and the arrow keys.
    private var focus: DownloadID?

    public init() {}

    /// The one selected download, or `nil` with none or several.
    public var single: DownloadID? {
        selected.count == 1 ? selected.first : nil
    }

    public func contains(_ id: DownloadID) -> Bool {
        selected.contains(id)
    }

    /// `rows` are the downloads shown, in order.
    public mutating func click(_ id: DownloadID, in rows: [DownloadID], modifiers: Modifiers = []) {
        if modifiers.contains(.shift), let anchor, let range = Self.range(from: anchor, to: id, in: rows) {
            selected = modifiers.contains(.command) ? selected.union(range) : range
            focus = id
            return
        }
        if modifiers.contains(.command) {
            if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        } else {
            selected = [id]
        }
        anchor = id
        focus = id
    }

    public mutating func selectAll(in rows: [DownloadID]) {
        selected = Set(rows)
        anchor = rows.first
        focus = rows.last
    }

    public mutating func clear() {
        selected = []
        anchor = nil
        focus = nil
    }

    /// ↑ and ↓ move the selection to the next row. With ⇧ they stretch it from the anchor instead.
    public mutating func move(by step: Int, in rows: [DownloadID], extending: Bool = false) {
        guard !rows.isEmpty else { return }
        let from = (focus ?? anchor).flatMap { rows.firstIndex(of: $0) }
        let index = from.map { min(max($0 + step, 0), rows.count - 1) } ?? (step > 0 ? 0 : rows.count - 1)
        let target = rows[index]
        if extending, let anchor, let range = Self.range(from: anchor, to: target, in: rows) {
            selected = range
            focus = target
        } else {
            selected = [target]
            anchor = target
            focus = target
        }
    }

    /// The rows a drag rectangle touches. With ⌘ held they join what was selected when the drag
    /// began, `base`.
    public mutating func drag(over ids: [DownloadID], adding: Bool, base: Set<DownloadID> = []) {
        selected = adding ? base.union(ids) : Set(ids)
        anchor = ids.first ?? anchor
        focus = ids.last ?? focus
    }

    /// Drops rows that are no longer shown, after a filter, a search or a removal.
    public mutating func keepOnly(_ rows: [DownloadID]) {
        selected.formIntersection(rows)
        if let anchor, !selected.contains(anchor) { self.anchor = nil }
        if let focus, !selected.contains(focus) { self.focus = nil }
    }

    /// A right-click acts on the selection when it lands on a selected row, and on that row alone
    /// otherwise, as in Finder.
    public mutating func prepareContextMenu(for id: DownloadID, in rows: [DownloadID]) {
        guard !selected.contains(id) else { return }
        click(id, in: rows)
    }

    private static func range(from start: DownloadID, to end: DownloadID, in rows: [DownloadID]) -> Set<DownloadID>? {
        guard let a = rows.firstIndex(of: start), let b = rows.firstIndex(of: end) else { return nil }
        return Set(rows[min(a, b)...max(a, b)])
    }
}
