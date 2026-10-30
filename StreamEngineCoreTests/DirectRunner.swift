import Testing
import Darwin

@main
struct StreamEngineTestRunner {
    static func main() async {
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
