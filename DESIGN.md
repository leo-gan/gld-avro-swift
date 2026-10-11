# Apache Avro for Swift (`gld-avro-swift`)

| Field | Value |
| --- | --- |
| **Author** | Leonid Ganeline |
| **Status** | v1 |
| **License** | MIT, Copyright (c) 2026 Leonid Ganeline |
| **Module** | `Avro` |
| **Package** | `gld-avro-swift` |
| **CLI** | `gld-avrogen-swift` |
| **Spec** | Apache Avro 1.11.1 (encodings compatible with 1.12) |

## Goals

1. Encode and decode Avro binary for every primitive and for records, enums, arrays, maps, unions, and fixed values. No libavro, no C Avro library.
2. Zigzag varints for `int` and `long`. Arrays and maps use variable-length blocks, including a negative count plus a size hint.
3. Parse `.avsc` and a practical `.avdl` subset (records, errors, enums, fixed, arrays, maps, unions, `T?`, imports, the common annotations). JSON protocol files (`.avpr`) contribute `types` and ignore `messages`.
4. Parsing canonical form and CRC-64-AVRO. Empty input fingerprints to `0xc15d213aa4d7a795`.
5. A union of `null` and one other type is optional. Every other union is tagged with the schema branch index.
6. Generic values (`AvroValue`) and writer/reader resolution: numeric promotion, string/bytes reinterpretation, field reorder, defaults, reader aliases. Writer-only aliases do not match a name. Fixed also matches size. Unqualified names match across namespaces.
7. Object container files with codecs `null` and `deflate`. `deflate` is raw RFC 1951. The writer emits stored blocks. The reader inflates stored, fixed Huffman, and dynamic Huffman blocks.
8. Single-object encoding: `C3 01`, then the 8-byte little-endian fingerprint, then the datum.
9. Official Avro JSON encoding, including union wrappers. Named union keys use the unqualified name on encode and accept the full name on decode. `bytes` are ISO-8859-1.
10. Codegen emits Swift types with `encodedByteLength`, `encode(into:)`, and `decode(from:)`, plus `schemaJSON` and `fromResolved`.
11. Logical types stay on the underlying wire type. `AvroLogical` converts date, UUID, a small decimal, and duration. Other logical types are stored on the schema and otherwise ignored.

RPC, Snappy, Confluent framing, and a schema registry client are out of scope.

## Layout

```text
src/Avro/            wire, JSON, schema, generic values, resolution, OCF, deflate, codegen
src/gld-avrogen-swift/
tests/               XCTest plus tests/generated
testdata/            schemas and golden bytes
benches/             release ns/op for the kitchen record
examples/            encode-record
```

`Package.swift` is the version surface together with `VERSION` and `avroLibraryVersion`. Generated code imports only `Avro`.

## Wire

| Type | Bytes |
| --- | --- |
| `null` | none |
| `boolean` | `0x00` or `0x01`; any other byte is `badBool` |
| `int`, `long` | zigzag varint; `int` must fit in `Int32` |
| `float`, `double` | IEEE-754 little-endian |
| `bytes`, `string` | zigzag length, then payload; strings must be UTF-8 |
| `fixed` | exactly `size` bytes |
| `enum` | zigzag index |
| `record` | fields in schema order |
| `array`, `map` | blocks, then a zero count |
| `union` | zigzag branch index, then the value |

`zigzagEncode(n) = (n << 1) XOR (n >> 63)` on the two's-complement bits. A varint longer than 10 bytes, or a 10th byte above `1`, is `badVarint`. Encode into `BinaryEncoder` does not throw. Decode throws `DecodeError`.

Block counts above `avroMaxBlockItems` are `range`. OCF schemas above 4 MiB are `schema`. Inflate output above `64_194_304` bytes is `deflate`.

## Schema

`SchemaPool` is an arena of `SchemaNode` values addressed by integer id, so recursive records are ordinary ids. Names follow the spec: a dotted name is a full name, an empty namespace attribute clears the enclosing namespace, and any other name is resolved in the enclosing namespace. The full name is registered before the fields are parsed, and a pre-scan registers later siblings so mutual records in one document resolve.

Unions reject an empty list, an immediate nested union, and two branches of the same non-named kind. Two named types are legal when the full names differ. A field default is Avro JSON for the field type; on a union it must match branch 0.

The parsing canonical form strips docs, aliases, defaults, and logical types, quotes primitive names, writes full names, and emits a named type's object only on the first visit. Later visits, including recursion, emit the full name string.

## Runtime

`AvroValue` is a tree: records are arrays in schema order, maps are ordered pairs, unions are `(index, value)`. `decodeGeneric` is same-schema. `decodeResolving` compiles nothing ahead of the walk; it reads the writer encoding and builds a reader value. Promotions are `int` to `long`/`float`/`double`, `long` to `float`/`double`, `float` to `double`, and `string` to or from `bytes` (bytes must be UTF-8). Enum symbols missing from the reader use the reader enum default or fail. Reader fields that the writer does not have require defaults.

`AvroCodable` is the generated-type protocol. `decodeResolving(_:from:writerSchemaJSON:)` resolves into `AvroValue` and calls `fromResolved`. `encodeJSON` for a generated value round-trips through the binary form and the reader schema, then emits Avro JSON. That keeps one JSON encoder.

Object container metadata is an Avro map of bytes. `avro.schema` is required. A missing `avro.codec` means `null`. Each block is a count, a size, the payload, and the 16-byte sync. The reader resolves every datum from the file schema onto the caller schema.

## Codegen

`emitSwift` walks records, enums, and fixed types, plus non-optional unions. Nullable unions become `Optional`. Recursion is the strongly connected component of the record graph. A field whose type is in that component is an error unless it is wrapped in optional, array, or map, in which case the element is `Box<T>`. `Box` is a class so the generated struct stays a value type with a heap cell inside. Tagged-union zero values pick the first branch that is not a recursive record.

Swift keywords in field names are backtick-escaped. Namespaces become `_` segments (`ex.Kitchen` is `ex_Kitchen`).

## Tests

`swift test` covers zigzag goldens (`150` is `ac 02`, `-1` is `01`), the kitchen record against `testdata/golden/kitchen.hex`, truncated buffers, canonical form, fingerprints, resolution (including namespace and alias cases), JSON unions, single-object frames, OCF `null` and stored-block `deflate`, inflate of Python raw-DEFLATE samples, IDL, and the checked-in generated types. Python `avro` is an oracle for those goldens, not a library dependency.
