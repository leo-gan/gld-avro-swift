# gld-avro-swift

Apache Avro for Swift, written in Swift. The package name is `gld-avro-swift`. The import module is `Avro`. The codegen tool is `gld-avrogen-swift`.

The library encodes and decodes the Avro binary datum, Avro JSON, object container files, and single-object frames. Schemas come from `.avsc` JSON or `.avdl` IDL. There is no libavro dependency.

| Surface | Name |
| --- | --- |
| Module | `Avro` |
| CLI | `gld-avrogen-swift` |
| Wire | zigzag integers, blocks, records, enums, arrays, maps, unions, fixed |
| Container | `null` and raw DEFLATE (`deflate`) |
| Version file | `VERSION` |

Binary encode of a generated value does not throw. Decode throws `DecodeError` with a kind, a byte offset, and a field index (`0` when the field is unknown).
