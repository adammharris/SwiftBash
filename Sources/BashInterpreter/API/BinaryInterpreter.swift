import Foundation

/// A handler the shell dispatches to when a path-invoked executable
/// turns out to be a *binary* whose leading bytes it recognises.
///
/// ``ScriptInterpreter`` covers the `#!`-shebang case, which is the only
/// way a text script can name its interpreter. A binary has no shebang —
/// it identifies itself by magic number, which is what the kernel's
/// `binfmt_misc` matches on and what this protocol mirrors. Registering
/// one makes `./tool.wasm` (or `./prog.elf`, or any other format the
/// embedder can execute in-process) run instead of failing with
/// `command not found`.
///
/// ```swift
/// shell.registerBinaryInterpreter(name: "wasm", magic: [0x00, 0x61, 0x73, 0x6D]) { ctx in
///     try await runtime.run(module: ctx.path, argv: ctx.argv)
/// }
/// ```
///
/// The context carries the *path*, not the file's contents. Magic-number
/// matching only needs a bounded prefix, so the dispatcher never reads
/// the whole file — a 10 MB module costs a single small read before
/// control reaches the interpreter, which is then free to mmap it, hand
/// the path to a runtime that caches by URL, or stream it. That is the
/// whole reason this isn't just ``ScriptInterpreter`` with a `Data`
/// payload.
///
/// Every registered interpreter inherits the calling shell via
/// `Shell.current` (TaskLocal), so the body can read environment,
/// positional parameters, stdio sinks, and sandbox state without any
/// explicit threading — same contract as ``ScriptInterpreter``.
public protocol BinaryInterpreter: Sendable {
    /// Identifier for this handler, used as the registry key.
    /// Registering a second interpreter under an existing name
    /// replaces it.
    var name: String { get }

    /// Leading bytes that identify the format — `[0x00, 0x61, 0x73,
    /// 0x6D]` for WebAssembly, `[0x7F, 0x45, 0x4C, 0x46]` for ELF.
    ///
    /// Matched against the file's first bytes. Must be non-empty; an
    /// empty magic would match every file and is ignored by the
    /// dispatcher.
    var magic: [UInt8] { get }

    /// Execute the file at ``BinaryInterpreterContext/path``.
    /// Implementations write to `Shell.current.stdout` / `.stderr` and
    /// read `Shell.current.stdin`.
    func run(_ context: BinaryInterpreterContext) async throws -> ExitStatus
}

/// Inputs handed to a ``BinaryInterpreter``.
public struct BinaryInterpreterContext: Sendable {
    /// Absolute path the binary was resolved to, via
    /// ``Shell/resolvePath(_:)`` and the shell's ``Shell/fileSystem``.
    /// This is a path in the *shell's* namespace, not necessarily the
    /// host's — a sandboxed `FileSystem` is free to map it elsewhere.
    public let path: String

    /// The bytes the dispatcher read while probing for a magic-number
    /// match. Long enough to have matched ``BinaryInterpreter/magic``
    /// and no longer than the probe window; interpreters that need the
    /// rest of the file read it themselves from ``path``.
    public let prefix: Data

    /// argv as the program would observe it: index 0 is the path as the
    /// user typed it, indices 1+ are its arguments.
    ///
    /// Deliberately *not* rewritten to the canonical path — a multicall
    /// binary dispatches on `argv[0]`, so the name the user typed is
    /// load-bearing and has to survive.
    public let argv: [String]

    public init(path: String, prefix: Data, argv: [String]) {
        self.path = path
        self.prefix = prefix
        self.argv = argv
    }
}

/// A ``BinaryInterpreter`` backed by a closure — the short form for
/// host-side registrations.
public struct ClosureBinaryInterpreter: BinaryInterpreter {
    public let name: String
    public let magic: [UInt8]
    private let body: @Sendable (BinaryInterpreterContext) async throws -> ExitStatus

    public init(name: String,
                magic: [UInt8],
                body: @Sendable @escaping (BinaryInterpreterContext) async throws -> ExitStatus) {
        self.name = name
        self.magic = magic
        self.body = body
    }

    public func run(_ context: BinaryInterpreterContext) async throws -> ExitStatus {
        try await body(context)
    }
}
