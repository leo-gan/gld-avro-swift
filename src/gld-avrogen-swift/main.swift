import Avro
import Foundation

@main
struct Avrogen {
    static func main() {
        do {
            try run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            print("gld-avrogen-swift: \(error)")
            Foundation.exit(1)
        }
    }

    static func run(_ args: [String]) throws {
        var schemaPath: String?
        var idlPath: String?
        var outPath: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            switch arg {
            case "--schema":
                schemaPath = try take(args, &index)
            case "--idl":
                idlPath = try take(args, &index)
            case "--out":
                outPath = try take(args, &index)
            case "--version":
                print(avroLibraryVersion)
                return
            case "--help", "-h":
                print("gld-avrogen-swift --schema file.avsc --out dir")
                print("gld-avrogen-swift --idl file.avdl --out dir")
                return
            default:
                throw CodegenError("unknown argument \(arg)")
            }
        }
        guard let outPath else { throw CodegenError("missing --out") }
        if (schemaPath == nil) == (idlPath == nil) {
            throw CodegenError("pass exactly one of --schema or --idl")
        }
        let pool: SchemaPool
        if let schemaPath {
            let text = try String(contentsOfFile: schemaPath, encoding: .utf8)
            pool = try parseAvsc(text)
        } else {
            let text = try String(contentsOfFile: idlPath!, encoding: .utf8)
            pool = try parseAvdl(text, resolver: FileImportResolver(), fromFile: idlPath!)
        }
        let files = try emitSwift(pool: pool)
        if files.isEmpty { throw CodegenError("schema has no named types to emit") }
        try FileManager.default.createDirectory(atPath: outPath, withIntermediateDirectories: true)
        for file in files {
            let path = outPath.hasSuffix("/") ? outPath + file.name : outPath + "/" + file.name
            try file.source.write(toFile: path, atomically: true, encoding: .utf8)
            print(path)
        }
    }

    static func take(_ args: [String], _ index: inout Int) throws -> String {
        guard index < args.count else { throw CodegenError("missing argument value") }
        let value = args[index]
        index += 1
        return value
    }
}
