import Testing
import Darwin

@main
struct NHLTestRunner {
    static func main() async {
        let result: CInt = await Testing.__swiftPMEntryPoint()
        exit(result)
    }
}
