// swift-tools-version:5.9
// Modified from Herdrup https://github.com/jerryfane/herdrup commit 93c6578666e656c3206661389e81853bcc0b88da by Elysium Technologies.
// Third-party MIT license terms in LICENSE are unchanged.
//
// Vendored copy of SwiftTerm, previously consumed as a remote package pin
// (`project.yml` -> exactVersion "1.15.0").
//
//   upstream: https://github.com/migueldeicaza/SwiftTerm.git
//   revision: dd2fb8ac5b861e7bf617c872895e338f38165648   (tag v1.15.0)
//
// It lives in the app repository because the terminal fixes this app needs are
// emulator-level (logical viewport anchoring across reflow, a no-soft-reset
// resize commit, presentation hooks) and must be reviewable and reproducible in
// one change. Source modifications are marked with `herdr:` comments; local
// regression tests and a platform guard for upstream iOS-only tests accompany them.
//
// Differences from the upstream manifest, all deliberate:
//   * only the `SwiftTerm` library and its `SwiftTermTests` test target are
//     declared — the Fuzz/Termcast executables, benchmark targets, docc plugin
//     and argument-parser dependency serve upstream tooling this app never
//     builds, so the library has no external package dependencies at all.
//   * the optional Metal shader is copied as source instead of compiled. This
//     companion uses SwiftTerm's default CoreText renderer, so requiring Xcode's
//     separately downloaded Metal toolchain would add build machinery for an
//     unused path. SwiftTerm can still runtime-compile the copied source if a
//     future target explicitly enables Metal.

import PackageDescription

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = []
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v11),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: [
        .library(
            name: "SwiftTerm",
            targets: ["SwiftTerm"]
        )
    ],
    targets: [
        .target(
            name: "SwiftTerm",
            path: "Sources/SwiftTerm",
            exclude: platformExcludes + ["Mac/README.md"],
            resources: [
                .copy("Apple/Metal/Shaders.metal")
            ]
        ),
        .testTarget(
            name: "SwiftTermTests",
            dependencies: ["SwiftTerm"],
            path: "Tests/SwiftTermTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
