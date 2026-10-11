# Examples

`examples/EncodeRecord.swift` is a small executable target. It parses a record schema, encodes a generic value, and decodes it.

```swift
import Avro

let schema = """
{"type":"record","name":"Greeting","fields":[
  {"name":"text","type":"string"},
  {"name":"n","type":"int"}]}
"""
let pool = try parseAvsc(schema)
let value = AvroValue.record([.string("hello"), .int(3)])
let bytes = try encodeGeneric(value, pool: pool)
let back = try decodeGeneric(bytes, pool: pool)
```

A generated record is the same bytes with static types:

```swift
let row = ex_Kitchen(
    n: AvroNull(), b: true, i: -7, l: 99, f: 1.5, d: -2.25,
    by: Array("abc".utf8), s: "hi", a: [1, 2, 3], m: ["k": "v"],
    e: .GREEN, fx: ex_Hash4(bytes: [1, 2, 3, 4]), u: "yo",
    inner: ex_Inner(x: 5))
let bytes = encode(row)
let copy = try decode(ex_Kitchen.self, from: bytes)
```

Resolution reads writer bytes into the reader schema, then `fromResolved` fills the generated type:

```swift
let row = try decodeResolving(ex_Kitchen.self, from: bytes, writerSchemaJSON: writerJSON)
```

An object container file with the deflate codec:

```swift
var writer = OCFWriter(schemaJSON: ex_Kitchen.schemaJSON, codec: .deflate)
writer.append(row)
let file = writer.finish()
let rows = try readOCF(ex_Kitchen.self, from: file)
```

Single-object encoding:

```swift
let frame = try encodeSingleObject(row)
let again = try decodeSingleObject(ex_Kitchen.self, from: frame)
```

Build the example with `swift run encode-record`.
