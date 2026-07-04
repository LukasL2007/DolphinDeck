import XCTest

@testable import Peripheral

class PeripheralTests: XCTestCase {
    func testApplicationDataExchangeSerialization() {
        let payload: [UInt8] = Array("DD1|HELLO|TEST".utf8)
        let main = Request.application(.dataExchange(payload)).serialize()

        guard case .appDataExchangeRequest(let request) = main.content else {
            return XCTFail("Expected app data exchange request")
        }
        XCTAssertEqual(Array(request.data), payload)
    }

    func testIncomingApplicationDataExchange() {
        let payload: [UInt8] = Array("DD1|EVENT|FIND_PHONE".utf8)
        let main = PB_Main.with {
            $0.commandID = 0
            $0.commandStatus = .ok
            $0.appDataExchangeRequest = .with {
                $0.data = .init(payload)
            }
        }

        let message = IncomingMessage(decoding: main)
        guard case .appDataExchange(let decoded) = message else {
            return XCTFail("Expected incoming app data exchange")
        }
        XCTAssertEqual(decoded, payload)
    }
}
