# Why Avro

Avro keeps the schema next to the data instead of tagging every field. A record is the concatenation of its fields in schema order. Integers are zigzag varints. Arrays and maps are runs of blocks, not length-prefixed blobs with a type code on each element. That is compact when the reader already knows the writer schema, and it is why a decoder cannot guess a type from the bytes alone.

Writers and readers are allowed to disagree. Resolution promotes `int` to `long`, `float`, or `double`, reorders fields, fills reader fields from defaults, and skips writer fields the reader dropped. Named types match on the unqualified name. A reader alias can rename a writer type. A writer alias does not.

Two representations share one schema. Binary is the datum, the object container file, and the single-object frame (`C3 01` plus the little-endian CRC-64-AVRO fingerprint of the parsing canonical form). JSON is the official Avro JSON encoding: unions are either `null` or a one-key object such as `{"string":"a"}`, and `bytes` are ISO-8859-1 strings. It is not a dump of a Swift dictionary.

A union of `null` and one other type is optional. Any other union is tagged with the schema branch index. The index is the writer's index on the way out and the reader's index after resolution.

Logical types (`date`, `uuid`, decimal, duration) stay on the underlying Avro type on the wire. Helper functions in `AvroLogical` convert the ones this library implements. The schema still records `logicalType` so a later reader can see it.
