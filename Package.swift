// swift-tools-version:6.2
import PackageDescription

// Trimmed for Wish. Upstream ships five products; this fork keeps the two
// that make sense inside an App Sandbox and drops the rest:
//
//   BashSyntax       tokeniser, parser, AST      — kept, no dependencies
//   BashInterpreter  execution, FileSystem, IO   — kept, ShellKit only
//
//   BashCommandKit   ls/cat/grep/sed as Swift    — dropped. Wish's whole
//                    thesis is that a tool is a .wasm module; a second,
//                    competing catalog of native builtins is the opposite
//                    bet. Dropping it also drops SwiftPorts, and with it
//                    libgit2, BoringSSL, SQLite, swift-archive, and
//                    swift-argument-parser.
//   SwiftJSCore      Node-shaped runtime on JSC  — dropped, and with it
//                    CJavaScriptCore and the vendored bun-webkit fetch.
//   BashSwiftScript  Swift-shebang interpreter   — dropped, and with it
//                    the SwiftScript dependency.
//   swift-bash /     CLI front-ends              — dropped; Wish is the
//   swift-js                                       front-end.
//
// What's left resolves to exactly one external package. ShellKit's core
// target conditions swift-subprocess out on iOS (the kernel bans
// posix_spawn there), so on this platform it links nothing at all.
//
// ShellKit is pinned by revision, not `branch: "main"` as upstream has it.
// A floating branch two levels deep is not something this project wants in
// its dependency graph — same reasoning as the WasmKit pin.

let package = Package(
    name: "SwiftBash",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9),
    ],
    products: [
        .library(name: "BashSyntax", targets: ["BashSyntax"]),
        .library(name: "BashInterpreter", targets: ["BashInterpreter"]),
    ],
    dependencies: [
        // ShellKit owns the virtualised runtime context: IO sinks,
        // Environment, the Command protocol, ProcessTable, BinCatalog, and
        // the `Shell.current` TaskLocal. SwiftBash subclasses
        // `ShellKit.Shell` to add bash-specific state on top.
        .package(url: "https://github.com/Cocoanetics/ShellKit",
                 revision: "ce2147463e7f08732112bb8929cd79944942f9d9"),
    ],
    targets: [
        // `<sys/xattr.h>` — Linux's stock Glibc module doesn't surface the
        // extended-attribute syscalls. Header-only. Kept because
        // RealFileSystem references it under `#if os(Linux) || os(Android)`;
        // it costs nothing on Apple platforms, where Darwin already has them.
        .systemLibrary(
            name: "CXattr",
            path: "Sources/CXattr"
        ),
        .target(
            name: "BashSyntax",
            path: "Sources/BashSyntax"
        ),
        .target(
            name: "BashInterpreter",
            dependencies: [
                "BashSyntax",
                .product(name: "ShellKit", package: "ShellKit"),
                .target(name: "CXattr",
                        condition: .when(platforms: [.linux, .android])),
            ],
            path: "Sources/BashInterpreter"
        ),
        .testTarget(
            name: "BashSyntaxTests",
            dependencies: ["BashSyntax"],
            path: "Tests/BashSyntaxTests"
        ),
        .testTarget(
            name: "BashInterpreterTests",
            dependencies: ["BashInterpreter"],
            path: "Tests/BashInterpreterTests"
        ),
    ]
)
