import Testing
import KlineTrainerContracts

@Suite("ReviewEndPrompt")
struct ReviewEndPromptTests {
    @Test("有净改动 → 弹保存确认")
    func netChangedPrompts() {
        #expect(ReviewEndPrompt.shouldPrompt(netChanged: true) == true)
    }

    @Test("无净改动 → 不弹，直接丢弃退出")
    func noChangeSkipsPrompt() {
        #expect(ReviewEndPrompt.shouldPrompt(netChanged: false) == false)
    }
}
