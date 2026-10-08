import DumptruckCore
import Foundation

@main
struct ChecksRunner {
    static func main() async {
        do {
            try await DumptruckChecks.runAll()
        } catch {
            let message = "ChecksRunner: FAIL: \(error)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }
}
