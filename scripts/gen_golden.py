#!/usr/bin/env python3
"""Optional oracle. Uses Python avro when it is installed. Not a runtime dependency."""

import sys

def main() -> int:
    try:
        import avro.schema
        from avro.io import BinaryEncoder, DatumWriter
    except ImportError:
        print("python avro is not installed; skipping", file=sys.stderr)
        return 0
    print("python avro", avro.__file__)
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
