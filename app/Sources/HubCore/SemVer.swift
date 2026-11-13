import Foundation

/// Same ordering as api/src/semver.js: MAJOR.MINOR.PATCH, then prerelease below the release.
public enum SemVer {
    struct Parsed {
        var core: [Int]
        var pre: [String]
    }

    static func parse(_ v: String) -> Parsed? {
        var s = v.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: "-", maxSplits: 1).map(String.init)
        guard let first = parts.first else { return nil }
        let nums = first.split(separator: ".").map { Int($0) }
        guard !nums.isEmpty, nums.count <= 3, nums.allSatisfy({ $0 != nil }) else { return nil }
        var core = nums.compactMap { $0 }
        while core.count < 3 { core.append(0) }
        let pre = parts.count > 1 ? parts[1].split(separator: ".").map(String.init) : []
        return Parsed(core: core, pre: pre)
    }

    public static func isValid(_ v: String) -> Bool { parse(v) != nil }

    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        guard let x = parse(a), let y = parse(b) else { return a.compare(b, options: .numeric) }
        for i in 0..<3 where x.core[i] != y.core[i] {
            return x.core[i] < y.core[i] ? .orderedAscending : .orderedDescending
        }
        if x.pre.isEmpty && y.pre.isEmpty { return .orderedSame }
        if x.pre.isEmpty { return .orderedDescending }
        if y.pre.isEmpty { return .orderedAscending }
        for i in 0..<max(x.pre.count, y.pre.count) {
            guard i < x.pre.count else { return .orderedAscending }
            guard i < y.pre.count else { return .orderedDescending }
            let p = x.pre[i], q = y.pre[i]
            if let pn = Int(p), let qn = Int(q) {
                if pn != qn { return pn < qn ? .orderedAscending : .orderedDescending }
            } else if (Int(p) != nil) != (Int(q) != nil) {
                return Int(p) != nil ? .orderedAscending : .orderedDescending
            } else if p != q {
                return p < q ? .orderedAscending : .orderedDescending
            }
        }
        return .orderedSame
    }
}
