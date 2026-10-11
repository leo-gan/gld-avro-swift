# gld-avro-swift

From-scratch Apache Avro for Swift. Module `Avro`. Codegen CLI `gld-avrogen-swift`.

The library encodes and decodes Avro binary, Avro JSON, object container files (`null` and raw DEFLATE), and single-object frames. It parses `.avsc` and `.avdl`. It does not link libavro.

```bash
swift test
swift run gld-avrogen-swift --schema testdata/avsc/kitchen.avsc --out /tmp/avro-gen
```

Version `0.1.0`. MIT, Copyright (c) 2026 Leonid Ganeline.
