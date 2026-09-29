import Foundation

let path = "MyApp/SourceMatcher.swift"
var content = try! String(contentsOfFile: path, encoding: .utf8)
let searchStr = "let title = [programme.title, programme.subtitle ?? \"\"].joined(separator: \" \")"
let replaceStr = "let title = [programme.title, programme.subtitle ?? \"\", programme.description ?? \"\"].joined(separator: \" \")"
content = content.replacingOccurrences(of: searchStr, with: replaceStr)
try! content.write(toFile: path, atomically: true, encoding: .utf8)

