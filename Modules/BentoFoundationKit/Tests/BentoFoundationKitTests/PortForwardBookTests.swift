import Foundation
import XCTest
@testable import BentoFoundationKit

@MainActor
final class PortForwardBookTests: XCTestCase {
    private let box = LinkHost(remoteID: "box", label: "box")

    func testLocalHostNeedsNoTunnel() async throws {
        let book = PortForwardBook<Int>()
        var opened = 0
        let f = try await book.forward(remotePort: 5173, on: .local(label: "here"),
                                       connection: { _ in () },
                                       open: { _, _ in opened += 1; return 1 })
        XCTAssertEqual(f.localPort, 5173)
        XCTAssertEqual(opened, 0)
        XCTAssertTrue(book.active.isEmpty)
    }

    func testSamePortIsSharedNotReopened() async throws {
        let book = PortForwardBook<Int>()
        var opened = 0
        let open: (Void, PortForward) async throws -> Int = { _, _ in opened += 1; return opened }
        let a = try await book.forward(remotePort: 41234, on: box, connection: { _ in () }, open: open)
        let b = try await book.forward(remotePort: 41234, on: box, connection: { _ in () }, open: open)
        XCTAssertEqual(a, b)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(book.forwards(remoteID: "box"), [a])
        XCTAssertEqual(book.remove(a), 1)
        XCTAssertFalse(book.contains(a))
    }

    func testRefusesBeforeAskingTheTransport() async {
        let book = PortForwardBook<Int>()
        do {
            _ = try await book.forward(remotePort: 80, on: box, connection: { _ in () },
                                       open: { _, _ in XCTFail("opened"); return 0 })
            XCTFail("privileged port forwarded")
        } catch let e as PortForwardError {
            XCTAssertEqual(e, .unsupported("Port 80 isn’t forwardable"))
        } catch { XCTFail("\(error)") }

        do {
            _ = try await book.forward(remotePort: 41235, on: box,
                                       connection: { _ -> Void? in nil },
                                       open: { _, _ in XCTFail("opened"); return 0 })
            XCTFail("forwarded without a connection")
        } catch let e as PortForwardError {
            XCTAssertEqual(e, .unsupported("No live connection to box"))
        } catch { XCTFail("\(error)") }
    }

    func testFailedOpenIsNotRecorded() async {
        let book = PortForwardBook<Int>()
        do {
            _ = try await book.forward(remotePort: 41236, on: box, connection: { _ in () },
                                       open: { _, _ in throw PortForwardError.couldNotReach(self.box) })
            XCTFail("expected failure")
        } catch let e as PortForwardError {
            XCTAssertEqual(e, .hostUnreachable("Couldn’t reach box"))
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(book.active.isEmpty)
    }
}
