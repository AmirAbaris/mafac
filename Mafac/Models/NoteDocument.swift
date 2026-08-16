//
//  NoteDocument.swift
//  Mafac
//
//  Phase 3: the in-memory document model for a note — an ordered list of
//  blocks, each either plain text or a math block, rendered top-to-bottom
//  by NoteEditorView.
//
//  Design notes:
//
//  - `NoteBlock` wraps its `content` in an `Identifiable` struct with a
//    stable `UUID`, rather than making `NoteBlockContent` itself carry the
//    id only on the `.math` case (as the plan sketch suggested). Every
//    block — text or math — needs a stable identity for `ForEach` to diff
//    correctly as the array grows/shrinks/splits (Phase 3's ⌘M handler
//    replaces one text block with three: before-text / math / after-text),
//    so giving *all* blocks a uniform `id` up front is simpler than special
//    -casing text blocks with index-based identity, which breaks the
//    moment a block is inserted or removed anywhere but the end.
//  - No `Codable` conformance yet — that's Phase 4's job (on-disk format),
//    left out here deliberately rather than added speculatively.
//

import Foundation

/// The content of a single note block.
///
/// `Equatable` (added in Phase 4) is used only for change-detection driving
/// debounced autosave (`ContentView` diffs the open `NoteDocument` to decide
/// when to schedule a save) — it has no bearing on the on-disk format, see
/// `NoteDocument+Markdown.swift`.
enum NoteBlockContent: Equatable {
    case text(String)
    case math(latex: String)
}

/// One block in a `NoteDocument`. Order in `NoteDocument.blocks` is the
/// document's reading order, top to bottom.
struct NoteBlock: Identifiable, Equatable {
    let id: UUID
    var content: NoteBlockContent

    init(id: UUID = UUID(), content: NoteBlockContent) {
        self.id = id
        self.content = content
    }

    var isMath: Bool {
        if case .math = content { return true }
        return false
    }
}

/// A note: a title plus an ordered array of blocks.
///
/// Phase 4 adds on-disk persistence (see `NoteDocument+Markdown.swift` for
/// the encode/decode pure functions and `NotesStore.swift` for the
/// file-system side: folder selection, listing, load/save/create/rename/
/// delete). `NoteDocument` itself stays a plain in-memory value type either
/// way — it doesn't know about files.
struct NoteDocument: Equatable {
    var title: String
    var blocks: [NoteBlock]

    /// A fresh note with a single empty text block, ready for the user to
    /// start typing into.
    static func empty(title: String = "Untitled Note") -> NoteDocument {
        NoteDocument(title: title, blocks: [NoteBlock(content: .text(""))])
    }
}
