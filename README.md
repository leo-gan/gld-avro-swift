# gld-avro-swift

From-scratch Apache Avro for Swift. Module `Avro`. Codegen CLI `gld-avrogen-swift`.

The runtime encodes and decodes Avro binary, Avro JSON, object container files (`null` and raw DEFLATE), and single-object frames. It parses `.avsc` and `.avdl`, computes the parsing canonical form and CRC-64-AVRO, and resolves a writer schema onto a reader schema. It does not link libavro.

```bash
swift test
swift run gld-avrogen-swift --schema testdata/avsc/kitchen.avsc --out /tmp/avro-gen
swift run encode-record
```

```swift
import Avro

let pool = try parseAvsc(schemaJSON)
let bytes = try encodeGeneric(value, pool: pool)
let back = try decodeGeneric(bytes, pool: pool)
```

Version `0.2.0` (`VERSION`). MIT, Copyright (c) 2026 Leonid Ganeline.

Docs: `mkdocs build --strict` with `requirements-docs.txt`.
