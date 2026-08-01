import Testing
import Foundation
@testable import BashInterpreter

/// The binary counterpart to ``ScriptInterpreterTests``. A `#!`-shebang
/// is the only way a *text* file can name its interpreter; a binary
/// identifies itself by magic number, which is what these cover.
@Suite(.timeLimit(.minutes(1))) struct BinaryInterpreterTests {

    /// The WebAssembly magic — `\0asm`. Used throughout because it's
    /// the case this hook was added for, and because its leading NUL
    /// is exactly what makes the pre-existing text/binary heuristic
    /// reject the file.
    private static let wasmMagic: [UInt8] = [0x00, 0x61, 0x73, 0x6D]

    private static func writeExecutable(
        _ bytes: [UInt8],
        to path: String
    ) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: path)
    }

    private static func bashQuote(_ str: String) -> String {
        "'" + str.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// A scratch directory that cleans itself up.
    private static func withTempDir(
        _ body: (String) async throws -> Void
    ) async throws {
        let dir = NSTemporaryDirectory() + "swift-bash-binary-\(UUID().uuidString)"
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try await body(dir)
    }

    private actor Sink {
        var contexts: [BinaryInterpreterContext] = []
        func record(_ ctx: BinaryInterpreterContext) { contexts.append(ctx) }
    }

    // MARK: magic matching

    @Test func matchesLongestMagicFirst() {
        let shell = Shell()
        shell.registerBinaryInterpreter(name: "short", magic: [0x00]) { _ in .success }
        shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { _ in .success }
        let matched = shell.matchingBinaryInterpreter(for: Data(Self.wasmMagic))
        #expect(matched?.name == "wasm")
    }

    @Test func emptyMagicNeverMatches() {
        let shell = Shell()
        shell.registerBinaryInterpreter(name: "greedy", magic: []) { _ in .success }
        #expect(shell.matchingBinaryInterpreter(for: Data([0x01])) == nil)
    }

    @Test func probeLengthCoversLongestMagicAndTextHeuristic() {
        let shell = Shell()
        #expect(shell.binaryProbeLength == 1024)
        shell.registerBinaryInterpreter(
            name: "long", magic: Array(repeating: 0xAB, count: 2048)) { _ in .success }
        #expect(shell.binaryProbeLength == 2048)
    }

    // MARK: end-to-end dispatch

    /// The case the hook exists for: `./tool.wasm` runs instead of
    /// failing with `command not found`. Before this, the leading NUL
    /// made `looksLikeTextScript` reject the file, and with no shebang
    /// there was no interpreter to reach.
    @Test func registeredInterpreterRunsOnPathInvocation() async throws {
        try await Self.withTempDir { dir in
            let cap = CapturingShell()
            let path = dir + "/tool.wasm"
            try Self.writeExecutable(Self.wasmMagic + [0x01, 0x00, 0x00, 0x00], to: path)

            let sink = Sink()
            cap.shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { ctx in
                await sink.record(ctx)
                Shell.current.stdout("ran:\(ctx.argv.joined(separator: ","))\n")
                return .success
            }

            try await cap.shell.run("\(Self.bashQuote(path)) one two")

            let ctxs = await sink.contexts
            #expect(ctxs.count == 1)
            #expect(ctxs.first?.path == cap.shell.resolvePath(path))
            #expect(ctxs.first?.prefix.starts(with: Self.wasmMagic) == true)
            #expect(cap.stdout == "ran:\(path),one,two\n")
        }
    }

    /// argv[0] reaches the interpreter as the user typed it, *not*
    /// canonicalised. A multicall module dispatches on argv[0] — one
    /// `coreutils.wasm` answering to `ls`, `cat`, and 72 other names —
    /// so rewriting it to the resolved path would break every one of
    /// them.
    @Test func argvZeroSurvivesUnrewritten() async throws {
        try await Self.withTempDir { dir in
            let cap = CapturingShell()
            try Self.writeExecutable(Self.wasmMagic, to: dir + "/ls.wasm")
            cap.shell.environment.workingDirectory = dir

            let sink = Sink()
            cap.shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { ctx in
                await sink.record(ctx)
                return .success
            }

            try await cap.shell.run("./ls.wasm -la")

            let ctxs = await sink.contexts
            #expect(ctxs.first?.argv == ["./ls.wasm", "-la"])
        }
    }

    /// Exit status propagates to `$?` like any other command.
    @Test func exitStatusPropagates() async throws {
        try await Self.withTempDir { dir in
            let cap = CapturingShell()
            let path = dir + "/fail.wasm"
            try Self.writeExecutable(Self.wasmMagic, to: path)
            cap.shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { _ in
                ExitStatus(3)
            }

            try await cap.shell.run("\(Self.bashQuote(path)); echo status=$?")
            #expect(cap.stdout == "status=3\n")
        }
    }

    /// The execute bit is the trust model — a `.wasm` the user never
    /// marked runnable must not run, and the diagnostic has to say why
    /// rather than claiming the command doesn't exist.
    @Test func nonExecutableBinaryIsRefused() async throws {
        try await Self.withTempDir { dir in
            let cap = CapturingShell()
            let path = dir + "/tool.wasm"
            try Data(Self.wasmMagic).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: path)

            let sink = Sink()
            cap.shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { ctx in
                await sink.record(ctx)
                return .success
            }

            try await cap.shell.run("\(Self.bashQuote(path)); echo status=$?")
            #expect(await sink.contexts.isEmpty)
            #expect(cap.stderr.contains("Permission denied"))
            #expect(cap.stdout == "status=126\n")
        }
    }

    /// An unclaimed binary still falls through to `command not found`
    /// — registering a wasm interpreter must not make every binary
    /// suddenly dispatchable.
    @Test func unmatchedMagicFallsThrough() async throws {
        try await Self.withTempDir { dir in
            let cap = CapturingShell()
            let path = dir + "/prog.elf"
            try Self.writeExecutable([0x7F, 0x45, 0x4C, 0x46], to: path)
            cap.shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { _ in
                Issue.record("wasm interpreter ran for an ELF file")
                return .success
            }

            try await cap.shell.run("\(Self.bashQuote(path)); echo status=$?")
            #expect(cap.stderr.contains("command not found"))
            #expect(cap.stdout == "status=127\n")
        }
    }

    /// Shebang dispatch is untouched by a registered binary
    /// interpreter. The probe runs first, so this pins that a text
    /// script still reaches its `ScriptInterpreter`.
    @Test func shebangDispatchStillWorksAlongsideBinaryInterpreter() async throws {
        try await Self.withTempDir { dir in
            let cap = CapturingShell()
            let path = dir + "/hello.foo"
            try Self.writeExecutable(Array("#!/usr/bin/env foolang\nbody\n".utf8), to: path)

            cap.shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { _ in
                Issue.record("binary interpreter ran for a shebang script")
                return .success
            }
            cap.shell.registerScriptInterpreter(name: "foolang") { _ in
                Shell.current.stdout("script\n")
                return .success
            }

            try await cap.shell.run(Self.bashQuote(path))
            #expect(cap.stdout == "script\n")
        }
    }

    /// A plain text file with no shebang is still interpreted as bash.
    @Test func textScriptFallbackStillWorks() async throws {
        try await Self.withTempDir { dir in
            let cap = CapturingShell()
            let path = dir + "/plain.sh"
            try Self.writeExecutable(Array("echo from-bash\n".utf8), to: path)
            cap.shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { _ in
                Issue.record("binary interpreter ran for a text script")
                return .success
            }

            try await cap.shell.run(Self.bashQuote(path))
            #expect(cap.stdout == "from-bash\n")
        }
    }

    /// Interpreters propagate across `copy()`, so a binary invoked
    /// inside a subshell or pipeline still resolves.
    @Test func interpreterSurvivesSubshell() async throws {
        try await Self.withTempDir { dir in
            let cap = CapturingShell()
            let path = dir + "/tool.wasm"
            try Self.writeExecutable(Self.wasmMagic, to: path)
            cap.shell.registerBinaryInterpreter(name: "wasm", magic: Self.wasmMagic) { _ in
                Shell.current.stdout("ran\n")
                return .success
            }

            try await cap.shell.run("(\(Self.bashQuote(path)))")
            #expect(cap.stdout == "ran\n")
        }
    }
}
