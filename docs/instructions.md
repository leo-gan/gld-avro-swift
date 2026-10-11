# Instructions

Swift 6 is required. This tree is developed with Swift 6.3.

```bash
swift test
swift build --product gld-avrogen-swift
bash scripts/check-generated.sh
bash scripts/run-bench.sh
```

`scripts/run-tests.sh` prepends a local Swiftly install when that directory exists, then runs `swift test`.

## Library

```swift
import Avro

let pool = try parseAvsc(schemaJSON)
let bytes = try encodeGeneric(value, pool: pool)
let back = try decodeGeneric(bytes, pool: pool)
```

`SchemaPool` holds named types by full name. `parseAvdl` reads IDL. `parseAvpr` reads a JSON protocol file and keeps `types`, ignoring `messages`.

`canonicalForm` is the parsing canonical form. `crc64Avro` fingerprints that UTF-8 text. The empty byte string fingerprints to `0xc15d213aa4d7a795`.

## Codegen

```bash
swift run gld-avrogen-swift --schema testdata/avsc/kitchen.avsc --out /tmp/avro-out
swift run gld-avrogen-swift --idl testdata/avdl/kitchen.avdl --out /tmp/avro-out
```

Each named type becomes a Swift file that imports `Avro`. Generated values implement `encodedByteLength()`, `encode(into:)`, `decode(from:)`, `schemaJSON`, and `fromResolved`. Add the files to an executable or library target that depends on `Avro`.

A nullable union (`["null", T]` or `[T, "null"]`) becomes `T?`. The branch index still follows the schema. Other unions become enums. A recursive record field is `Box<T>`, a class, because a Swift struct cannot contain itself. A non-optional recursive field is rejected. A tagged union's zero-value initializer uses the first branch that is not a recursive record.

## Containers and JSON

`OCFWriter` / `readOCF` handle object container files. Codecs are `null` and `deflate`. `deflate` is raw DEFLATE (RFC 1951), not zlib and not gzip. The writer emits stored blocks. The reader accepts stored, fixed Huffman, and dynamic Huffman blocks.

`encodeSingleObject` writes `C3 01`, the 8-byte little-endian fingerprint, and the datum. Decode checks the fingerprint against `schemaJSON`, or against a writer schema when you pass one and want resolution.

`encodeJSON` / `decodeJSON` use the Avro JSON encoding. Non-finite floats throw `DecodeError.Kind.badJSONNumber`.
