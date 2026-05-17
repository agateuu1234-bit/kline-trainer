// Kline Trainer Swift Contracts — F1 Models 通用工具区
// Spec: kline_trainer_modules_v1.4.md §十三（L2286）"BinarySearch 扩展 归 F1 通用工具区"
// 消费方：Wave 1 C5 trade marker index lookup（KLineView+Markers.swift:15 hook 点）

import Foundation

extension RandomAccessCollection {
    /// 二分查找分区点：返回首个使 `predicate` 为 `true` 的 index；若无则返回 `endIndex`。
    ///
    /// **前置约束**：`predicate` 必须在 self 上 **monotonic**（所有 false 在所有 true 之前）；
    /// 否则结果未定义。调用方负责传入单调谓词（典型：`{ $0 >= target }`）。
    ///
    /// 复杂度：O(log n)。
    public func partitioningIndex(
        where predicate: (Element) throws -> Bool
    ) rethrows -> Index {
        var lo = startIndex
        var hi = endIndex
        while lo < hi {
            let mid = index(lo, offsetBy: distance(from: lo, to: hi) / 2)
            if try predicate(self[mid]) {
                hi = mid
            } else {
                lo = index(after: mid)
            }
        }
        return lo
    }
}

extension RandomAccessCollection where Element: Comparable {
    /// 首个使 `self[i] >= value` 的 index；若全 `< value` 返回 `endIndex`。
    /// 复杂度：O(log n)。要求 self 升序。
    public func lowerBound(of value: Element) -> Index {
        partitioningIndex { $0 >= value }
    }

    /// 首个使 `self[i] > value` 的 index；若全 `≤ value` 返回 `endIndex`。
    /// 复杂度：O(log n)。要求 self 升序。
    public func upperBound(of value: Element) -> Index {
        partitioningIndex { $0 > value }
    }
}
