// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "gld-avro-swift",
    products: [
        .library(name: "Avro", targets: ["Avro"]),
        .executable(name: "gld-avrogen-swift", targets: ["gld-avrogen-swift"]),
        .executable(name: "avro-bench", targets: ["avro-bench"]),
        .executable(name: "encode-record", targets: ["encode-record"]),
    ],
    targets: [
        .target(name: "Avro", path: "src/Avro"),
        .executableTarget(
            name: "gld-avrogen-swift",
            dependencies: ["Avro"],
            path: "src/gld-avrogen-swift"
        ),
        .executableTarget(
            name: "avro-bench",
            dependencies: ["Avro"],
            path: "benches"
        ),
        .executableTarget(
            name: "encode-record",
            dependencies: ["Avro"],
            path: "examples"
        ),
        .testTarget(
            name: "AvroTests",
            dependencies: ["Avro"],
            path: "tests"
        ),
    ]
)
