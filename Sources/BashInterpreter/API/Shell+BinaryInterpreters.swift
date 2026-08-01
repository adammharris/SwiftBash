import Foundation

extension Shell {

    /// Register `interpreter` under its `name`, replacing any existing
    /// entry with the same name. Used by the dispatcher to run
    /// path-invoked binaries it recognises by magic number
    /// (`./tool.wasm`, `/abs/path/prog.elf`).
    public func registerBinaryInterpreter(_ interpreter: BinaryInterpreter) {
        binaryInterpreters[interpreter.name] = interpreter
    }

    /// Closure-form registration — equivalent to wrapping `body` in a
    /// ``ClosureBinaryInterpreter``.
    public func registerBinaryInterpreter(
        name: String,
        magic: [UInt8],
        _ body: @Sendable @escaping (BinaryInterpreterContext) async throws -> ExitStatus
    ) {
        binaryInterpreters[name] = ClosureBinaryInterpreter(
            name: name, magic: magic, body: body)
    }

    /// Remove a previously-registered interpreter. Returns the removed
    /// entry, or `nil` if no interpreter was registered under `name`.
    @discardableResult
    public func unregisterBinaryInterpreter(_ name: String) -> BinaryInterpreter? {
        binaryInterpreters.removeValue(forKey: name)
    }

    /// Bytes the dispatcher needs to read before it can decide whether a
    /// file is a recognised binary, a shebang script, or bash source.
    ///
    /// The 1 KiB floor is what ``looksLikeTextScript`` scans for NUL
    /// bytes; a registered magic longer than that raises it. Registering
    /// no interpreters still probes 1 KiB, which is what the
    /// pre-existing text/binary discrimination cost anyway.
    var binaryProbeLength: Int {
        max(1024, binaryInterpreters.values.map(\.magic.count).max() ?? 0)
    }

    /// First registered interpreter whose magic matches `prefix`.
    ///
    /// Ties are broken by longest magic first, so a format whose magic
    /// extends another's wins over the shorter one regardless of
    /// registration order. Beyond that the order is the dictionary's and
    /// therefore unspecified — registering two interpreters with the
    /// same magic is a programming error, not a supported layering.
    func matchingBinaryInterpreter(for prefix: Data) -> BinaryInterpreter? {
        binaryInterpreters.values
            .filter { !$0.magic.isEmpty }
            .sorted { $0.magic.count > $1.magic.count }
            .first { prefix.starts(with: $0.magic) }
    }
}
