# Techniques

## Zigzag and blocks

Avro integers are not raw two's complement. `zigzagEncode` maps a signed 64-bit value onto an unsigned varint so small negatives stay one byte: `-1` is `0x01`, `1` is `0x02`, `150` is `0xac 0x02`. The decoder rejects a 10th varint byte that carries bits above the 64-bit remainder.

Arrays and maps are a sequence of blocks. A positive count is that many items. A negative count is followed by a byte size; the size is a hint the decoder checks after reading the items. A zero count ends the value. The writer emits one positive block and a terminating zero. An empty array is a single zero.

## Names and defaults

Records, enums, and fixed values match when the unqualified names match, even across namespaces. Reader aliases are applied to the writer name. Writer aliases are not a match key. Fixed values also need the same size.

A missing reader field needs a JSON default that matches the field type. For a union, that default is the first branch, not a union wrapper. `["string","null"]` with default `null` is a schema error because `null` is not a string.

## Bytes on the hot path

`BinaryEncoder` writes into one `[UInt8]` and reserves before a string or byte payload. `encode` sizes the buffer from `encodedByteLength()` for generated values, so the common path does not grow the array mid-record. A one-byte zigzag value is a single append; longer values stay in the same buffer. Floats and doubles are stored as IEEE-754 little-endian bit patterns, including NaN payloads, on the binary path. The JSON path rejects non-finite numbers.

`SchemaNode` is a class. A decode or encode walk holds a reference instead of copying the field list on every node. Each record caches a wire plan of kind, fixed size, child kind, and a shape flag, so the hot loop does not copy field descriptors or chase a child node for every primitive. Primitive fields, `int` arrays, and `string` maps are written and read in that loop. `AvroValue` stores primitives inline. Only arrays, maps, records, and unions are indirect, so a 14-field record does not allocate a heap box per integer. Huffman codes use a flat table per length instead of a dictionary. Generic encode reuses one buffer per thread. The returned array shares that storage until a later encode on the same thread needs a unique copy. `benches/Bench.swift` times that record. Direct `BinaryEncoder` calls are the floor under the generic tree.

`Box` is a heap cell for recursive generated structs (`LongList`, mutual records). Copying the struct copies the reference. `init` allocates a new cell. Zero-value initializers do not build a recursive `Box`.

## Deflate

Object container codec `deflate` is raw DEFLATE. There is no zlib header. The writer uses stored blocks, split at 65535 bytes, so a round trip does not depend on a Huffman encoder. The reader inflates stored, fixed, and dynamic blocks so a Python or Java file still opens. Inflate output is capped.
