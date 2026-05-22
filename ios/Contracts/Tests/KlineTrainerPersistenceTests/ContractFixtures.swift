import Foundation

/// 加载 repo-root tests/contract-fixtures/<name>.json（P1↔B3 共享契约层）。
/// 用 #filePath 向上找含 tests/contract-fixtures 的目录作 repo root，
/// 对目录重构鲁棒（不硬编码层级深度）。
enum ContractFixtures {
    static func data(_ name: String) throws -> Data {
        let url = repoRoot().appending(path: "tests/contract-fixtures/\(name).json")
        return try Data(contentsOf: url)
    }

    private static func repoRoot() -> URL {
        var dir = URL(filePath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        while true {
            if fm.fileExists(atPath: dir.appending(path: "tests/contract-fixtures").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            precondition(parent != dir, "tests/contract-fixtures not found above \(#filePath)")
            dir = parent
        }
    }
}
