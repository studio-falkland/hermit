// swift-tools-version: 5.9
// Hermit benchmark subpackage.
//
// This is a standalone Swift package. It is intentionally separate from the
// root Hermit package so that none of its dependencies (ordo-one/benchmark,
// swift-nio, HdrHistogram, …) are ever pulled into a consumer's resolve graph.
//
// Usage
// -----
//   cd Benchmarks
//   swift package benchmark                         # run all suites
//   swift package benchmark --filter crawl          # run matching benchmarks
//   swift package benchmark baseline update main    # save a named baseline
//   swift package benchmark baseline compare main   # diff against it
//
// Swift version note
// ------------------
// ordo-one/benchmark 1.29.x requires Swift 5.10+.
// If your toolchain is Swift 5.9, pin the dependency to exactly "1.28.0":
//   .package(url: "https://github.com/ordo-one/benchmark", exact: "1.28.0"),

import PackageDescription

let package = Package(
    name: "HermitBenchmarks",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Local path — never fetched, never appears in consumers' resolve graphs.
        .package(path: "../"),
        .package(url: "https://github.com/ordo-one/benchmark", .upToNextMajor(from: "1.4.0")),
        // swift-nio is needed here for the in-process synthetic HTTP server.
        // It is NOT re-exported and will not affect the root package's dep graph.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        .executableTarget(
            name: "HermitBenchmarks",
            dependencies: [
                // "hermit" is the package identity (directory name, lowercased).
                .product(name: "Hermit", package: "hermit"),
                .product(name: "Benchmark", package: "benchmark"),
                // NIOPosix re-exports NIOCore, so both NIOCore and NIOPosix
                // types are available via a single `import NIOPosix`.
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "HermitBenchmarks",
            plugins: [
                .plugin(name: "BenchmarkPlugin", package: "benchmark"),
            ]
        ),
    ]
)
