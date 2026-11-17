import Foundation
import Testing

@testable import NitsStreaming

@Suite("Not served: the reason in the error")
struct NotServedReasonTests {
    @Test("An error's message tells the status and the host that answered, beside the name the playlist lists")
    func messageTellsStatusAndHost() throws {
        let listed = try #require(URL(string: "https://live.nits.invalid/140?sq=363"))
        let error = PlaylistSourceError.load(
            .notServed(listed, reason: .status(204, host: "rr1---sn-test.googlevideo.com")))
        let message = "\(error)"
        #expect(message.contains("live.nits.invalid/140?sq=363"))
        #expect(message.contains("HTTP 204 from rr1---sn-test.googlevideo.com"))
    }
}
