import Foundation

extension Shell {

    // Try dispatching `argv[0]` as a path-invoked external program.
    //
    // Returns its exit status when handled — either the file's leading
    // bytes matched a registered ``BinaryInterpreter``, or it has a
    // `#!`-shebang with a registered ``ScriptInterpreter``, or it's
    // plain text we interpret as bash. Returns `nil` only when the
    // candidate isn't path-shaped, or when the file exists but nothing
    // claims it — both fall through to the caller's `command not
    // found` branch.
    //
    // Behaviour mirrors the kernel's `binfmt_script` plus bash's own
    // permission-error reporting:
    // - token has no `/` → `nil` (treat as bare name, look up in PATH)
    // - non-existent file → `127`, `No such file or directory`
    // - directory or non-regular file → `126`, `Is a directory`
    // - regular file without the execute bit set → `126`,
    //   `Permission denied` (matches `bash ./script` when the file
    //   isn't `chmod +x`'d)
    // - filesystem error probing or reading the path (sandbox denial,
    //   real EACCES, IO error) → `126` with a permission-shaped
    //   diagnostic, NOT `command not found` — the path exists in the
    //   user's command line, masking the failure as a lookup miss is
    //   unhelpful
    // - file's leading bytes match a registered `BinaryInterpreter` →
    //   dispatched to it (checked first — a magic number is a stronger
    //   claim than any heuristic below, and matching it lets us skip
    //   reading the rest of what may be a very large file)
    // - file present, no magic match, no shebang → `nil` (might be a
    //   binary nothing claims; let the caller fall through)
    // - shebang names an interpreter that isn't registered → `nil`
    //
    // Sequential pipeline (path-shape check → metadata → permission
    // gate → magic probe → binary dispatch → file read → shebang parse
    // → interpreter dispatch → optional bash-fallback). Splitting
    // per-stage would scatter the shared
    // `head`/`meta`/`data`/`raw`/`shebangLine` locals.
    // swiftlint:disable:next function_body_length
    func dispatchAsExternalScriptIfApplicable(
        argv: [String]
    ) async throws -> ExitStatus? {
        guard !scriptInterpreters.isEmpty || !binaryInterpreters.isEmpty else {
            return nil
        }
        guard let head = argv.first, looksLikePath(head) else { return nil }

        let resolved = resolvePath(head)
        let meta: FileMetadata?
        do {
            meta = try await fileSystem.metadata(resolved)
        } catch let err as FileSystemError {
            // The path is explicit (`./foo`, `/abs/path`); the user is
            // asking us to run THIS file. Surface the underlying FS
            // error as a 126 rather than masking it as a missing
            // command.
            stderr(
                "\(errorLocationPrefix())\(head): \(err.shellMessage())\n")
            return ExitStatus(126)
        }
        guard let meta else {
            stderr(
                "\(errorLocationPrefix())\(head): No such file or directory\n")
            return ExitStatus(127)
        }
        if meta.kind == .directory {
            stderr(
                "\(errorLocationPrefix())\(head): Is a directory\n")
            return ExitStatus(126)
        }
        // Bash refuses to execute a regular file without an execute
        // bit set (`./script` → `Permission denied` exit 126). Match
        // that here; otherwise we'd happily run a 0644 file the user
        // never marked as runnable. Filesystems whose `metadata`
        // doesn't track POSIX bits report mode 0 — treat those as
        // executable so in-memory test fixtures and the virtual /bin
        // overlay aren't blocked.
        //
        // Windows has no POSIX execute bit, so `RealFileSystem`'s
        // `windowsMetadata` reports `0o644` for every regular file —
        // applying the check there would block every script. Skip
        // the gate on Windows; if a script runs at all, the file
        // already exists and the OS handles the rest.
        #if !os(Windows)
        if meta.mode != 0, (meta.mode & 0o111) == 0 {
            stderr(
                "\(errorLocationPrefix())\(head): Permission denied\n")
            return ExitStatus(126)
        }
        #endif
        // Magic-number probe, before any full read. A binary that a
        // registered interpreter claims is dispatched on the strength
        // of a bounded prefix, so invoking a 10 MB wasm module costs
        // one small read here and nothing more — the interpreter gets
        // the path and loads it however it likes.
        //
        // Checked ahead of the shebang parse because a magic number is
        // an unambiguous self-identification where the tests below are
        // heuristics. An embedder that registers `#!` as a magic
        // therefore shadows shebang dispatch entirely; that is its
        // choice to make, and no real binary format claims those bytes.
        if !binaryInterpreters.isEmpty {
            let probe: Data
            do {
                probe = try await readPrefix(resolved, count: binaryProbeLength)
            } catch let err as FileSystemError {
                stderr(
                    "\(errorLocationPrefix())\(head): \(err.shellMessage())\n")
                return ExitStatus(126)
            }
            if let interpreter = matchingBinaryInterpreter(for: probe) {
                // Same subshell reasoning as the shebang path below:
                // an interpreter mutates `positionalParameters` and
                // `scriptName`, and those must not leak into the
                // parent.
                let context = BinaryInterpreterContext(
                    path: resolved, prefix: probe, argv: argv)
                let sub = copy()
                sub.scriptName = resolved
                sub.positionalParameters = Array(argv.dropFirst())
                return try await sub.withCurrent {
                    try await interpreter.run(context)
                }
            }
        }

        let data: Data
        do {
            data = try await fileSystem.readData(resolved)
        } catch let err as FileSystemError {
            // Same reasoning as the metadata branch above — surface
            // a real read failure on an explicit path rather than
            // hiding it as `command not found`.
            stderr(
                "\(errorLocationPrefix())\(head): \(err.shellMessage())\n")
            return ExitStatus(126)
        }
        // swiftlint:disable:next optional_data_string_conversion
        let raw = String(decoding: data, as: UTF8.self)
        let (rewritten, shebangLine) = stripShebang(raw)

        // Run inside a fresh subshell — interpreters mutate
        // `Shell.current.positionalParameters` and `scriptName` while
        // executing, and we don't want those to leak into the parent.
        // `Shell.copy()` is the single source of truth for what
        // propagates; this stays consistent with `bash FILE` semantics.
        if let shebangLine,
           let parsed = parseShebangLine(shebangLine),
           let interpreter = scriptInterpreters[parsed.interpreter] {
            let context = ScriptInterpreterContext(
                scriptPath: resolved,
                source: rewritten,
                shebang: shebangLine,
                argv: [resolved] + Array(argv.dropFirst()))
            let sub = copy()
            sub.scriptName = resolved
            sub.positionalParameters = Array(argv.dropFirst())
            return try await sub.withCurrent {
                try await interpreter.run(context)
            }
        }

        // No shebang at all → real bash falls back to running the
        // file through `/bin/sh` after a failed `execve(ENOEXEC)`.
        // Since we ARE the shell, just interpret the contents
        // ourselves. The probe rejects obvious binaries (NUL bytes
        // in the first kilobyte) so we don't try to parse an ELF /
        // Mach-O / `.pyc` as bash source.
        //
        // When the file DID have a shebang but it pointed at an
        // interpreter we don't have (e.g. `#!/usr/bin/env python3`
        // on a host with no python registration), keep the previous
        // behaviour and return `nil`. Falling back to bash there
        // would mangle the user's actual interpreter intent.
        if shebangLine == nil, looksLikeTextScript(data) {
            let sub = copy()
            sub.scriptName = resolved
            sub.positionalParameters = Array(argv.dropFirst())
            return try await sub.withCurrent {
                try await sub.run(raw)
            }
        }

        return nil
    }

    /// Read at most `count` bytes from the head of `path`.
    ///
    /// Goes through ``FileSystem/openRead(_:)`` rather than
    /// ``FileSystem/readData(_:)`` so a filesystem that implements real
    /// streaming reads only touches the prefix. The protocol's default
    /// `openRead` buffers the whole file, in which case this costs the
    /// same as `readData` — correct either way, cheap where the
    /// embedder made it cheap.
    private func readPrefix(_ path: String, count: Int) async throws -> Data {
        let source = try await fileSystem.openRead(path)
        var buffer = Data()
        for await chunk in source.bytes {
            buffer.append(chunk)
            if buffer.count >= count { break }
        }
        return buffer.count > count ? Data(buffer.prefix(count)) : buffer
    }

    /// Heuristic for "this file is a script the shell should
    /// interpret, not a binary it should refuse". Real bash uses
    /// the kernel's `ENOEXEC` from a failed `execve(2)`; we
    /// approximate by scanning the first 1 KiB for NUL bytes,
    /// which would never appear in well-formed bash source but
    /// almost always show up in ELF/Mach-O/PE headers and in
    /// most binary blobs (PNG, gzip, etc.).
    private func looksLikeTextScript(_ data: Data) -> Bool {
        return !data.prefix(1024).contains(0)
    }

    /// A token "looks like a path" if it contains a `/` (relative or
    /// absolute). Bare names like `swift-script` are looked up in the
    /// command registry only — they're not paths to script files.
    ///
    /// On Windows, `\` is also accepted because `NSTemporaryDirectory()`
    /// and friends return paths like `C:\Users\…\run.foo`. Without
    /// this, every Windows-shaped temp path falls through to
    /// `command not found`.
    func looksLikePath(_ token: String) -> Bool {
        #if os(Windows)
        return token.contains("/") || token.contains("\\")
        #else
        return token.contains("/")
        #endif
    }
}
