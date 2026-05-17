import Testing
import Foundation
@testable import KlineTrainerContracts

@Suite("BinarySearch.partitioningIndex generic")
struct PartitioningIndexTests {
    @Test func emptyCollection_returnsEndIndex() {
        let arr: [Int] = []
        let idx = arr.partitioningIndex { $0 >= 5 }
        #expect(idx == arr.endIndex)
        #expect(idx == 0)
    }

    @Test func singleElement_predicateAlwaysTrue_returnsStart() {
        let arr = [10]
        let idx = arr.partitioningIndex { $0 >= 5 }
        #expect(idx == 0)
    }

    @Test func singleElement_predicateAlwaysFalse_returnsEnd() {
        let arr = [10]
        let idx = arr.partitioningIndex { $0 >= 100 }
        #expect(idx == 1)
        #expect(idx == arr.endIndex)
    }

    @Test func multipleElements_partitionInMiddle() {
        let arr = [1, 3, 5, 7, 9]
        let idx = arr.partitioningIndex { $0 >= 5 }
        #expect(idx == 2)
    }

    @Test func multipleElements_allTrue_returnsStart() {
        let arr = [10, 20, 30]
        let idx = arr.partitioningIndex { $0 >= 5 }
        #expect(idx == 0)
    }

    @Test func multipleElements_allFalse_returnsEnd() {
        let arr = [1, 2, 3]
        let idx = arr.partitioningIndex { $0 >= 100 }
        #expect(idx == 3)
    }

    /// codex R1 finding 3 修：消费方 C5 marker lookup 是 ArraySlice<KLineCandle>（非零起始）；
    /// 如果实现假设零起始 offset，本测试在 zero-based ArraySlice impl 上 fail。
    @Test func arraySlice_nonZeroStartIndex_returnsAbsoluteIndex() {
        let arr = [1, 3, 5, 7, 9, 11, 13]
        let slice = arr[2...5]  // [5, 7, 9, 11]，startIndex = 2，endIndex = 6
        let idx = slice.partitioningIndex { $0 >= 9 }
        #expect(idx == 4)
        #expect(slice.startIndex == 2)
        let endIdx = slice.partitioningIndex { $0 >= 100 }
        #expect(endIdx == slice.endIndex)
        #expect(endIdx == 6)
    }
}

@Suite("BinarySearch.lowerBound / upperBound for Comparable")
struct ComparableBoundTests {
    @Test func lowerBound_exactMatch_returnsFirstOccurrence() {
        let arr = [1, 3, 5, 5, 5, 7]
        #expect(arr.lowerBound(of: 5) == 2)
    }

    @Test func upperBound_exactMatch_returnsAfterLastOccurrence() {
        let arr = [1, 3, 5, 5, 5, 7]
        #expect(arr.upperBound(of: 5) == 5)
    }

    @Test func lowerBound_belowMin_returnsStartIndex() {
        let arr = [10, 20, 30]
        #expect(arr.lowerBound(of: 5) == 0)
    }

    @Test func lowerBound_betweenValues_returnsInsertionPoint() {
        let arr = [10, 20, 30]
        #expect(arr.lowerBound(of: 15) == 1)
    }

    @Test func lowerBound_aboveMax_returnsEndIndex() {
        let arr = [10, 20, 30]
        #expect(arr.lowerBound(of: 100) == 3)
        #expect(arr.lowerBound(of: 100) == arr.endIndex)
    }

    @Test func upperBound_belowMin_returnsStartIndex() {
        let arr = [10, 20, 30]
        #expect(arr.upperBound(of: 5) == 0)
    }

    @Test func upperBound_betweenValues_returnsInsertionPoint() {
        let arr = [10, 20, 30]
        #expect(arr.upperBound(of: 15) == 1)
    }

    @Test func upperBound_aboveMax_returnsEndIndex() {
        let arr = [10, 20, 30]
        #expect(arr.upperBound(of: 100) == 3)
        #expect(arr.upperBound(of: 100) == arr.endIndex)
    }
}
