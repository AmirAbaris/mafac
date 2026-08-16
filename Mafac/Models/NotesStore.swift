//
//  NotesStore.swift
//  Mafac
//
//  Phase 4: owns the on-disk side of persistence — which folder holds the
//  user's notes, listing the `.mafac` files in it, and load/save/create/
//  rename/delete. `NoteDocument+Markdown.swift` (pure, no I/O) handles the
//  string <-> NoteDocument transformation this store reads/writes.
//
//  ## Security-scoped bookmark lifecycle (read this before touching
//  `folderURL` or the two `startAccessingSecurityScopedResource` call
//  sites below)
//
//  Mafac is sandboxed with the "user-selected file read/write" entitlement
//  (see Mafac.entitlements, from Phase 0), not full-disk access. That
//  entitlement grants access to a URL for as long as the process holds an
//  active *security scope* on it:
//
//  - `NSOpenPanel`'s returned URL is already scoped for the *current*
//    process lifetime the moment the user picks it — no
//    `startAccessingSecurityScopedResource` call is required to use it
//    immediately. But that access doesn't survive relaunch. To get access
//    back next launch, the scope has to be captured as a *bookmark*
//    (`URL.bookmarkData(options: .withSecurityScope, ...)`), stored
//    (`UserDefaults` here, since it's small opaque `Data`, not a
//    credential), and *resolved + explicitly re-scoped*
//    (`startAccessingSecurityScopedResource()`) on every subsequent
//    launch.
//  - Every `startAccessingSecurityScopedResource()` call — whether for a
//    freshly bookmarked panel URL or a resolved bookmark on relaunch —
//    MUST be matched by exactly one `stopAccessingSecurityScopedResource()`
//    when that folder is no longer in use (switching to a different
//    folder, or the store being torn down). Unbalanced calls are the
//    classic sandboxing bug this task called out: stop-without-start is a
//    no-op but masks a logic error, and start-without-stop leaks the
//    scope for the process's lifetime (usually harmless until you're
//    juggling multiple folders, but sloppy). `isAccessingSecurityScope`
//    below exists purely to make that pairing an explicit, checkable
//    invariant rather than something implied by control flow: every
///    place that flips `folderURL` to a new value stops the old scope
//    first (if one is held) and only starts a new one after that;
//    `deinit` stops whatever scope is still open when the store goes
//    away.
//  - This store calls `startAccessingSecurityScopedResource()` even on
//    freshly-panel-picked URLs (not strictly required per Apple's docs,
//    since the panel already scopes them for this process run) so that
//    "URL came from a fresh pick" and "URL came from a resolved bookmark"
//    go through one code path (`applyFolder(_:isFreshPick:)`) with one
//    lifecycle story, rather than two subtly different ones. The one
//    functional difference that *does* matter: a fresh pick always gets a
//    new bookmark written to `UserDefaults`; a resolved bookmark only
//    rewrites the stored bookmark if resolution reported it `isStale`.
//
import Foundation
import AppKit

/// One note's identity + display info, as found in the chosen folder.
/// `url` doubles as the stable identity for list diffing/selection — it
/// changes on rename, which callers (`ContentView`/`NotesListView`) handle
/// by re-pointing their selection at the renamed `NoteMetadata`'s new url.
struct NoteMetadata: Identifiable, Hashable {
    var url: URL
    var title: String

    var id: URL { url }
}

enum NotesStoreError: LocalizedError {
    case folderAccessDenied
    case bookmarkResolutionFailed

    var errorDescription: String? {
        switch self {
        case .folderAccessDenied:
            return "Mafac couldn't get access to the selected notes folder. Please choose it again."
        case .bookmarkResolutionFailed:
            return "The saved notes folder couldn't be found — it may have been moved, renamed, or deleted. Please choose it again."
        }
    }
}

@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var notes: [NoteMetadata] = []
    @Published private(set) var folderURL: URL?
    /// Non-nil whenever the folder is unusable and the UI should offer a
    /// "choose folder" affordance — bookmark resolution failure (folder
    /// moved/deleted) or a listing/save error along the way.
    @Published var folderAccessError: String?

    private static let bookmarkDefaultsKey = "mafac.notesFolder.bookmark"

    private let fileManager = FileManager.default

    /// Tracks whether `folderURL` currently has an open security scope, so
    /// every start is matched by exactly one stop. See the type-level doc
    /// comment above for the full lifecycle story.
    ///
    /// `nonisolated(unsafe)` because `deinit` needs to read it to balance
    /// the scope, and `deinit` isn't actor-isolated. Safe in practice: by
    /// the time `deinit` runs there are no other references to `self`, so
    /// there's no concurrent access to race with.
    private nonisolated(unsafe) var isAccessingSecurityScope = false

    /// Mirrors `folderURL` for `deinit`'s sake — `folderURL` itself is
    /// `@Published` and MainActor-isolated, which `deinit` can't touch.
    /// Kept in sync everywhere `folderURL` is assigned.
    private nonisolated(unsafe) var lastKnownFolderURL: URL?

    init() {
        restoreFolderFromBookmark()
    }

    deinit {
        if isAccessingSecurityScope, let url = lastKnownFolderURL {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - Folder selection & bookmark lifecycle

    private func restoreFolderFromBookmark() {
        guard let bookmarkData = UserDefaults.standard.data(forKey: Self.bookmarkDefaultsKey) else {
            // First launch, or the user hasn't picked a folder yet.
            // ContentView is responsible for calling pickFolder() in this
            // state.
            return
        }

        var isStale = false
        let resolvedURL: URL
        do {
            resolvedURL = try URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            folderAccessError = NotesStoreError.bookmarkResolutionFailed.errorDescription
            return
        }

        applyFolder(resolvedURL, isFreshPick: false, rewriteBookmarkIfStale: isStale)
    }

    /// Presents an `NSOpenPanel` for the user to choose (or create) a
    /// notes folder, then switches the store over to it. Call this on
    /// first launch (no stored bookmark) or whenever the user wants to
    /// change/re-pick the folder (including recovering from a bookmark
    /// resolution failure).
    func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder where Mafac will store your notes."

        guard panel.runModal() == .OK, let url = panel.url else { return }
        applyFolder(url, isFreshPick: true, rewriteBookmarkIfStale: false)
    }

    /// Single entry point for switching `folderURL` to a new value,
    /// whatever its source (fresh panel pick or resolved bookmark) — see
    /// the type-level doc comment for why this exists as one path.
    private func applyFolder(_ url: URL, isFreshPick: Bool, rewriteBookmarkIfStale: Bool) {
        // Release the previous folder's scope, if any, before acquiring
        // the new one — keeps exactly one folder's scope open at a time.
        if isAccessingSecurityScope, let previous = folderURL {
            previous.stopAccessingSecurityScopedResource()
            isAccessingSecurityScope = false
        }

        guard url.startAccessingSecurityScopedResource() else {
            folderURL = nil
            lastKnownFolderURL = nil
            folderAccessError = NotesStoreError.folderAccessDenied.errorDescription
            notes = []
            return
        }
        isAccessingSecurityScope = true
        folderURL = url
        lastKnownFolderURL = url
        folderAccessError = nil

        if isFreshPick {
            do {
                try storeBookmark(for: url)
            } catch {
                // Non-fatal: the current session still has live access via
                // the open scope above, it just won't survive a relaunch
                // cleanly. Surface it without blocking use.
                folderAccessError = "Couldn't save a persistent bookmark for this folder (notes will still work this session, but you may need to re-pick the folder next launch): \(error.localizedDescription)"
            }
        } else if rewriteBookmarkIfStale {
            // A stale bookmark still resolved successfully this time,
            // but macOS is telling us its internal path info drifted
            // (e.g. the folder was renamed/moved). Refresh it now so
            // future launches don't keep paying the "stale" cost.
            try? storeBookmark(for: url)
        }

        reloadNotes()
    }

    private func storeBookmark(for url: URL) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        UserDefaults.standard.set(data, forKey: Self.bookmarkDefaultsKey)
    }

    // MARK: - Listing

    /// Re-reads the `.mafac` files in `folderURL`. Safe to call anytime
    /// (e.g. on app activation, or after create/rename/delete) — cheap
    /// directory listing, no file contents read.
    func reloadNotes() {
        guard let folderURL else {
            notes = []
            return
        }
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            let noteURLs = urls.filter { $0.pathExtension.lowercased() == "mafac" }
            notes = noteURLs
                .map { NoteMetadata(url: $0, title: $0.deletingPathExtension().lastPathComponent) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            folderAccessError = nil
        } catch {
            folderAccessError = "Couldn't list notes in the selected folder: \(error.localizedDescription)"
            notes = []
        }
    }

    // MARK: - CRUD

    /// Loads and parses a note from disk. Returns `nil` — and drops the
    /// note from `notes` — if the file no longer exists, handling the
    /// "deleted externally" edge case without crashing: the caller (e.g.
    /// `ContentView`) should fall back to an empty/error state rather than
    /// assume `load` always succeeds for something still in the list.
    func load(_ metadata: NoteMetadata) -> NoteDocument? {
        guard fileManager.fileExists(atPath: metadata.url.path) else {
            notes.removeAll { $0.url == metadata.url }
            return nil
        }
        do {
            let text = try String(contentsOf: metadata.url, encoding: .utf8)
            return NoteMarkdownCodec.decode(text, title: metadata.title)
        } catch {
            folderAccessError = "Couldn't read \"\(metadata.title)\": \(error.localizedDescription)"
            return nil
        }
    }

    /// Encodes and writes `document` to `metadata.url`. Used both for the
    /// explicit save path and for debounced autosave (the debounce timer
    /// itself lives in `ContentView`, not here — this is a plain
    /// synchronous write).
    func save(_ document: NoteDocument, to metadata: NoteMetadata) {
        let markdown = NoteMarkdownCodec.encode(document)
        do {
            try markdown.write(to: metadata.url, atomically: true, encoding: .utf8)
            folderAccessError = nil
        } catch {
            folderAccessError = "Couldn't save \"\(metadata.title)\": \(error.localizedDescription)"
        }
    }

    /// Creates a new empty note file in the current folder, resolving a
    /// name collision by appending a numeric suffix, and returns its
    /// metadata (or nil if there's no folder, or the write fails).
    @discardableResult
    func createNote(named baseName: String = "Untitled") -> NoteMetadata? {
        guard let folderURL else { return nil }
        let url = uniqueURL(for: baseName, in: folderURL)
        let title = url.deletingPathExtension().lastPathComponent
        let document = NoteDocument.empty(title: title)
        let markdown = NoteMarkdownCodec.encode(document)
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            folderAccessError = "Couldn't create note: \(error.localizedDescription)"
            return nil
        }
        reloadNotes()
        return NoteMetadata(url: url, title: title)
    }

    /// Renames a note on disk, resolving a collision with an existing name
    /// the same way `createNote` does. Returns the note's new metadata (its
    /// `url` changes), or nil on failure — callers should keep using the
    /// old metadata/selection if this returns nil.
    @discardableResult
    func rename(_ metadata: NoteMetadata, to newTitle: String) -> NoteMetadata? {
        guard let folderURL else { return nil }
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let newURL = uniqueURL(for: trimmed, in: folderURL, excluding: metadata.url)
        guard newURL != metadata.url else {
            // Name unchanged after sanitizing/collision-resolution —
            // nothing to do, not an error.
            return metadata
        }
        do {
            try fileManager.moveItem(at: metadata.url, to: newURL)
        } catch {
            folderAccessError = "Couldn't rename note: \(error.localizedDescription)"
            return nil
        }
        reloadNotes()
        return NoteMetadata(url: newURL, title: newURL.deletingPathExtension().lastPathComponent)
    }

    /// Moves a note to the Trash (falling back to a permanent delete only
    /// if Trashing itself fails) and drops it from `notes` immediately so
    /// the UI doesn't wait on a `reloadNotes()` round-trip.
    func delete(_ metadata: NoteMetadata) {
        do {
            try fileManager.trashItem(at: metadata.url, resultingItemURL: nil)
        } catch {
            try? fileManager.removeItem(at: metadata.url)
        }
        notes.removeAll { $0.url == metadata.url }
    }

    // MARK: - Name collisions

    /// Returns a `.mafac` URL in `folder` for `baseName` that doesn't
    /// already exist, appending " 2", " 3", ... on collision. `excluding`
    /// lets `rename` treat the note's own current URL as not-a-collision
    /// (so renaming "Foo" to "Foo" — or to a name that only differs by
    /// something the sanitizer strips back to "Foo" — is a no-op rather
    /// than becoming "Foo 2").
    private func uniqueURL(for baseName: String, in folder: URL, excluding: URL? = nil) -> URL {
        let sanitized = sanitize(baseName)
        var candidateName = sanitized
        var suffix = 2
        while true {
            let candidate = folder.appendingPathComponent(candidateName).appendingPathExtension("mafac")
            if candidate == excluding || !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            candidateName = "\(sanitized) \(suffix)"
            suffix += 1
        }
    }

    /// Strips path-separator characters a filename can't contain. Not a
    /// full filename sanitizer (colons, which HFS+ used to forbid, are
    /// left alone since APFS/Finder tolerate them in the modern SDKs this
    /// targets) — just enough to keep `/` from being misread as a path
    /// component.
    private func sanitize(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-")
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
