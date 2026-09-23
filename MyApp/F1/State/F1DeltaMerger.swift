import Foundation

nonisolated enum F1DeltaMerger {
    /// Arrays in snapshots are complete collections. Numeric-key object deltas
    /// patch an existing array by index; racing-number dictionaries stay objects.
    static func merge(_ existing: F1Value, _ delta: F1Value) -> F1Value {
        switch (existing, delta) {
        case (.object(var old), .object(let changes)):
            if changes["_deleted"]?.bool == true { return .null }
            for (key, value) in changes where key != "_deleted" {
                if value["_deleted"].bool == true { old.removeValue(forKey: key) }
                else { old[key] = merge(old[key] ?? .null, value) }
            }
            return .object(old)
        case (.array(var old), .object(let changes)) where changes.keys.allSatisfy({ Int($0).map { $0 >= 0 && $0 < 100_000 } == true }):
            for (key, value) in changes {
                guard let index = Int(key) else { continue }
                if index >= old.count { old.append(contentsOf: repeatElement(.null, count: index - old.count + 1)) }
                old[index] = merge(old[index], value)
            }
            return .array(old)
        default: return delta
        }
    }
    static func indexed(_ value: F1Value) -> [(String, F1Value)] {
        switch value {
        case .array(let array): return array.enumerated().map { (String($0.offset), $0.element) }
        case .object(let object): return object.sorted { (Int($0.key) ?? Int.max, $0.key) < (Int($1.key) ?? Int.max, $1.key) }.map { ($0.key, $0.value) }
        default: return []
        }
    }
}
