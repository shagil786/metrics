// MCPInstallCommand: where the built `portmaster-mcp` is, and the line that registers it.
//
// The Settings page's **Copy install command** button exists because the path to the
// built binary is not something a person can be expected to know: SwiftPM's bin directory
// varies per machine, per toolchain and per configuration, which is why the README tells
// people to *ask* SwiftPM rather than assume. This file is the asking, and the one place
// the answer is turned into a command.
//
// **The double-prefix bug is why the path helper is a tested function.** Slice 1 shipped
// `claude mcp add portmaster -- "$(cd Core && swift build -c release --show-bin-path)/portmaster-mcp"`
// with a `$PWD/` prefix over the top of what `--show-bin-path` had already made absolute
// — so the registered command named a file that does not exist, and the symptom (a client
// that cannot start the server) points nowhere near the mistake. `binaryPath(in:relativeTo:)`
// therefore distinguishes an absolute directory from a relative one and never prefixes the
// former.
//
// What this file does **not** do is run anything. `claude mcp add` writes the user's
// client configuration; it has never been executed from this repository, so neither the
// command nor the caption claims otherwise.

import Foundation

/// The `claude mcp add` line, and the path it names.
public enum MCPInstallCommand {

    /// The name the client registers the server under.
    public static let clientName = "portmaster"

    /// How the binary is built. Named here rather than in the page so the notice, the
    /// README and a person reading either of them get the same line.
    public static let buildCommand = "cd Core && swift build -c release --product portmaster-mcp"

    /// The absolute path to the built `portmaster-mcp` inside `binDirectory`.
    ///
    /// `relativeTo` is only consulted for a **relative** `binDirectory`, because that is
    /// the only case in which something is missing: `claude mcp add` stores the string it
    /// is given and the client later spawns the binary with its own working directory, so
    /// a relative path silently becomes a path relative to somewhere else.
    ///
    /// The absolute branch is the whole reason this is a function with tests. `--show-bin-path`
    /// prints an absolute path on this toolchain, and prefixing that with a working
    /// directory yields a path that does not exist.
    ///
    /// Trailing separators on either argument are absorbed rather than doubled, and an
    /// empty `binDirectory` means the base directory itself. With no base at all a relative
    /// directory is left alone rather than having a leading separator invented for it,
    /// which would name the filesystem root.
    public static func binaryPath(in binDirectory: String, relativeTo basePath: String) -> String {
        let directory = withoutTrailingSeparator(binDirectory)
        let base = withoutTrailingSeparator(basePath)
        let resolved: String
        if directory.isEmpty {
            resolved = base
        } else if binDirectory.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            resolved = directory
        } else if base.isEmpty {
            resolved = directory
        } else {
            resolved = base + "/" + directory
        }
        // Both inputs are already separator-trimmed, so `resolved` is too — except in
        // the `directory.isEmpty` case, where `base` was the answer and is already clean.
        return resolved.isEmpty
            ? MCPStdioRunner.serverName
            : resolved + "/" + MCPStdioRunner.serverName
    }

    /// The command a person pastes into their client's terminal.
    ///
    /// Single-quoted when the path contains anything a shell would treat as structure, so
    /// a Mac whose home directory has a space in it gets a command that works. `portmaster`
    /// and the `claude mcp add` words are deliberately left unquoted: this is a line
    /// somebody reads and edits, and quoting the whole thing makes it harder to check.
    public static func command(binaryPath: String) -> String {
        let quoted = needsShellQuoting(binaryPath) ? "'\(binaryPath)'" : binaryPath
        return "claude mcp add \(clientName) -- \(quoted)"
    }

    /// The first candidate that is an executable file, or `nil` when none is.
    ///
    /// The existence check is a parameter so the choice of *where to look* can be tested
    /// without a filesystem, and so this stays a pure function of the list it is given.
    /// Order is the caller's: release before debug, because a debug binary found first is a
    /// different program from the one the docs describe.
    public static func locateBinary(
        in candidates: [String], isExecutableFile: (String) -> Bool
    ) -> String? {
        candidates.first(where: isExecutableFile)
    }

    /// Where a SwiftPM package's binaries land, release first.
    ///
    /// Two layouts because the toolchain's default changed: `.build/release` on older
    /// SwiftPM, `.build/out/Products/Release` on newer ones (including the toolchain this
    /// was written against). Both, in that order, so the page finds the binary either way
    /// rather than telling a person it is missing when it is on disk two directories over.
    /// Empty for an empty package path — there is nothing to hang these off.
    public static func binDirectories(packagePath: String) -> [String] {
        let trimmed = packagePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let root = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        return [
            root + "/.build/out/Products/Release",
            root + "/.build/release",
            root + "/.build/out/Products/Debug",
            root + "/.build/debug",
        ]
    }

    /// The path with surrounding whitespace and any trailing separator removed, so the
    /// join below can never produce `//` — a doubled separator is a path that resolves to
    /// the same place but reads like a different one, and is the shape a hand-written
    /// prefix keeps taking.
    private static func withoutTrailingSeparator(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmedSlashes = trimmed
        while trimmedSlashes.hasSuffix("/") { trimmedSlashes.removeLast() }
        return trimmedSlashes
    }

    /// The SwiftPM package this file was compiled from, as a directory path.
    ///
    /// `#filePath` is the only thing a shipped app has that can point at a checkout at
    /// all: it is the path the compiler saw, so on the machine that built the app it names
    /// the real `Core` directory. On any other machine it names nothing, and the honest
    /// outcome is that `locateBinary` finds no binary and the page says it has not been
    /// built — never a path that does not exist.
    public static var compiledPackagePath: String {
        packageRoot(containingSourceFileAt: #filePath, isPackage: isPackageDirectory)
    }

    /// Walks up from `sourceFile` to the nearest ancestor that is a package directory.
    ///
    /// A function with an injected probe so the walk can be tested without a checkout,
    /// and bounded because an unbounded walk out of `/` eventually runs out of path
    /// segments — at which point the answer is "not found" and the page says so.
    static func packageRoot(
        containingSourceFileAt sourceFile: String,
        isPackage: (String) -> Bool
    ) -> String {
        let path = sourceFile.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked before it reaches `URL`, which resolves an empty path to the process's
        // current directory rather than failing — so an empty input would otherwise walk
        // up from wherever the app happens to be and name that as the package.
        guard !path.isEmpty else { return "" }
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        // Bounded by the path's own component count: each step removes one, so this can
        // never loop, and it stops at the root without needing a separate check.
        var remaining = directory.split(separator: "/").count
        while remaining > 0 {
            if isPackage(directory) { return directory }
            let parent = URL(fileURLWithPath: directory).deletingLastPathComponent().path
            if parent == directory { break }
            directory = parent
            remaining -= 1
        }
        return ""
    }

    /// Whether `directory` is a SwiftPM package root.
    private static func isPackageDirectory(_ directory: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: directory).appendingPathComponent("Package.swift").path
        )
    }

    /// Whether a shell would take this string apart rather than read it as one word.
    ///
    /// Conservative on purpose: quoting something that did not need it only makes the
    /// command uglier to read, but *not* quoting something that needed it produces a
    /// command that silently registers two arguments.
    private static func needsShellQuoting(_ path: String) -> Bool {
        path.unicodeScalars.contains { scalar in
            CharacterSet.alphanumerics.contains(scalar) == false
                && CharacterSet(charactersIn: "/._-").contains(scalar) == false
        }
    }
}
