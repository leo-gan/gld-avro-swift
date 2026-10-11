# Test data

Test records live under `testdata/`. They are ordinary inputs for the unit tests. They are not a product schema and they are not imported from another repository.

| Path | Role |
| --- | --- |
| `testdata/avsc/kitchen.avsc` | Record with null, bool, int, long, float, double, bytes, string, array, map, enum, fixed, a null union, and a nested record |
| `testdata/avsc/longlist.avsc` | Recursive list, `next` is `["null","LongList"]` |
| `testdata/avsc/mutual.avsc` | Records `A` and `B` that point at each other |
| `testdata/avsc/node.avsc` | Tagged union `["Node","string"]` |
| `testdata/avdl/kitchen.avdl` | IDL form of the kitchen shape |
| `testdata/avpr/demo.avpr` | JSON protocol; `messages` are ignored |
| `testdata/golden/` | Oracle bytes for the kitchen datum and two integers |

`tests/generated/` is what `gld-avrogen-swift` emits for those schemas. `scripts/check-generated.sh` regenerates into a temp directory and diffs.

The kitchen datum's binary form is fixed in `testdata/golden/kitchen.hex`. It was produced by Python `avro` 1.11.3. Fingerprints of `"null"`, `"int"`, the kitchen parsing canonical form, and `LongList` are checked against the same oracle. A truncated prefix of the kitchen datum must throw `DecodeError` kind `eof`.

`swift test` does not need Python. `scripts/gen_golden.py` exits quietly when the `avro` module is absent.
