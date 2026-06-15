import Testing
@testable import KlineTrainerContracts

@Suite("ToastState：latest-wins token 调度核（host-testable，§B.1）")
struct ToastStateTests {

    @Test("present 设置 message 并返回单调 token")
    func present_setsMessageAndToken() {
        var s = ToastState()
        let t1 = s.present("A")
        #expect(s.message == "A")
        let t2 = s.present("B")
        #expect(s.message == "B")
        #expect(t2 > t1)
    }

    @Test("过期旧 token 不清当前（latest-wins）")
    func expireStaleToken_keepsCurrent() {
        var s = ToastState()
        let t1 = s.present("A")
        _ = s.present("B")
        s.expire(token: t1)
        #expect(s.message == "B")
    }

    @Test("过期当前 token 清空 message")
    func expireCurrentToken_clears() {
        var s = ToastState()
        let t = s.present("A")
        s.expire(token: t)
        #expect(s.message == nil)
    }
}
