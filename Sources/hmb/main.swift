// WP0 stub; WP5 owns this file (§5.5: compress, estimate, score, inspect, bench).
import Foundation
import HMBBench
import HMBEngine
import HMBModel

let arguments = CommandLine.arguments.dropFirst()
if arguments.first == "--version" {
    print("hmb (WP0 scaffold) · \(EnginePrimitives.codecVersions)")
    exit(0)
}
FileHandle.standardError.write(Data("hmb: not implemented yet (WP5). Try `hmb --version`.\n".utf8))
exit(64)
