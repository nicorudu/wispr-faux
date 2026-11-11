import AppKit
import UniformTypeIdentifiers

/// A copy of everything on a pasteboard: every item, and every type on each item, with
/// its data. Dictate takes one before writing its own text and puts it back afterwards,
/// so the user's clipboard ends up as it was (BUILD_PLAN.md §1, "Insertion").
///
/// Unlike the teardown, PDF, RTFD and sound data are kept: the MVP promises an identical
/// clipboard, and rich text with an inline image is RTFD. Only file promises are skipped:
/// reading one asks the source app to produce a file. If backups from apps that render
/// formats lazily (e.g. Office) turn out slow, the teardown's skip list is the fallback.
public struct PasteboardSnapshot: Sendable, Equatable {
    public struct Representation: Sendable, Equatable {
        public var type: NSPasteboard.PasteboardType
        public var data: Data

        public init(type: NSPasteboard.PasteboardType, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public struct Item: Sendable, Equatable {
        /// In the order the source app listed them, richest first.
        public var representations: [Representation]

        public init(_ representations: [Representation]) {
            self.representations = representations
        }
    }

    /// Sizes for logs and the menu; never the content itself.
    public struct Summary: Sendable, Equatable, CustomStringConvertible {
        public var itemCount: Int
        public var typeCount: Int
        public var byteCount: Int
        public var containsImage: Bool
        public var containsText: Bool

        /// e.g. "image, 3 types, 1.2 MB" or "empty".
        public var description: String {
            guard itemCount > 0 else { return "empty" }
            let kind = containsImage ? "image" : containsText ? "text" : "data"
            let items = itemCount > 1 ? "\(itemCount) items, " : ""
            let types = typeCount == 1 ? "1 type" : "\(typeCount) types"
            let bytes = ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .memory)
            return "\(kind), \(items)\(types), \(bytes)"
        }
    }

    public var items: [Item]

    public init(items: [Item]) {
        self.items = items
    }

    /// Reads every item and type on `pasteboard`. Types whose data can't be read are left out.
    public init(capturing pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).compactMap { item in
            let representations = item.types
                .filter { !Self.isSkipped($0) }
                .compactMap { type in item.data(forType: type).map { Representation(type: type, data: $0) } }
            return representations.isEmpty ? nil : Item(representations)
        }
    }

    public var isEmpty: Bool { items.isEmpty }

    public var summary: Summary {
        let types = items.flatMap(\.representations)
        return Summary(
            itemCount: items.count,
            typeCount: types.count,
            byteCount: types.reduce(0) { $0 + $1.data.count },
            containsImage: types.contains { Self.conforms($0.type, to: .image) },
            containsText: types.contains { Self.conforms($0.type, to: .text) }
        )
    }

    /// Replaces the contents of `pasteboard` with this snapshot. An empty snapshot leaves
    /// the pasteboard empty. Returns `false` if the pasteboard refused the items.
    @discardableResult
    public func write(to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        guard !items.isEmpty else { return true }
        let objects = items.map { item in
            let object = NSPasteboardItem()
            for representation in item.representations {
                object.setData(representation.data, forType: representation.type)
            }
            return object
        }
        return pasteboard.writeObjects(objects)
    }

    // MARK: - Types

    /// File promises: reading one makes the source app write out a file.
    static func isSkipped(_ type: NSPasteboard.PasteboardType) -> Bool {
        let raw = type.rawValue
        return raw.hasPrefix("com.apple.pasteboard.promised-")
            || raw == "com.apple.NSFilePromiseItemMetaData"
            || raw == "Apple files promise pasteboard type"
    }

    private static func conforms(_ type: NSPasteboard.PasteboardType, to supertype: UTType) -> Bool {
        UTType(type.rawValue)?.conforms(to: supertype) ?? false
    }
}

extension NSPasteboard.PasteboardType {
    /// nspasteboard.org marker: clipboard managers skip items that carry it, so the
    /// text Dictate puts on the clipboard for a moment doesn't land in their history.
    public static let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
}
