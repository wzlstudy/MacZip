import Foundation

/// 压缩排除规则的 glob 匹配 (ZIP 引擎自定义排除)。
///
/// 规则语义 (对大小写不敏感):
/// - 规则不含 "/":匹配树中任意层级的**名称** (文件或目录)。匹配到目录即整棵剪枝。
///   例: `*.log`、`node_modules`、`.DS_Store`。
/// - 规则含 "/":对**归档内相对路径**做分段匹配 (每段内 `*` / `?` 通配),
///   且允许匹配为路径的**目录前缀** (同样剪枝子树)。
///   例: `build/*`、`docs/*.md`、`secret/*.key`。
enum ExcludeMatcher {
    /// 任一规则命中即排除。
    static func isExcluded(relativePath: String, patterns: [String]) -> Bool {
        guard !patterns.isEmpty else { return false }
        let path = relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return false }
        for rawPattern in patterns {
            let pattern = rawPattern.trimmingCharacters(in: .whitespaces)
            if matches(pattern: pattern, relativePath: path) { return true }
        }
        return false
    }

    static func matches(pattern: String, relativePath: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        let loweredPath = relativePath.lowercased()
        if !pattern.contains("/") {
            // 任意层级名称匹配:相对路径的任一段命中即排除。
            return loweredPath.split(separator: "/").contains { segment in
                globMatch(segment, pattern.lowercased()[...])
            }
        }
        let patternSegments = pattern.lowercased().split(separator: "/")
        let pathSegments = loweredPath.split(separator: "/")
        // 前缀语义:规则段数不得超过路径段数,且逐段匹配。
        guard patternSegments.count <= pathSegments.count else { return false }
        for (index, patternSegment) in patternSegments.enumerated() {
            if !globMatch(pathSegments[index], patternSegment) { return false }
        }
        return true
    }

    /// 单段 glob:`*` 任意串,`?` 单字符 (大小写不敏感由调用方保证)。
    /// 双指针实现——切勿混用两个不同字符串的下标坐标空间。
    static func globMatch(_ name: some StringProtocol, _ pattern: some StringProtocol) -> Bool {
        let nameChars = Array(name)
        let patternChars = Array(pattern)
        var nameIndex = 0
        var patternIndex = 0
        var starPatternIndex = -1
        var starNameIndex = 0

        while nameIndex < nameChars.count {
            if patternIndex < patternChars.count,
               patternChars[patternIndex] == "?" || patternChars[patternIndex] == nameChars[nameIndex] {
                nameIndex += 1
                patternIndex += 1
            } else if patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
                starPatternIndex = patternIndex
                starNameIndex = nameIndex
                patternIndex += 1
            } else if starPatternIndex >= 0 {
                patternIndex = starPatternIndex + 1
                starNameIndex += 1
                nameIndex = starNameIndex
            } else {
                return false
            }
        }
        while patternIndex < patternChars.count, patternChars[patternIndex] == "*" {
            patternIndex += 1
        }
        return patternIndex == patternChars.count
    }
}
