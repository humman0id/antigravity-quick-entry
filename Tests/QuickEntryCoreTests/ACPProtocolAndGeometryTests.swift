import XCTest
import CoreGraphics
@testable import QuickEntryCore

final class ACPProtocolAndGeometryTests: XCTestCase {
    func testEncodeSessionPromptWithImageAndText() throws {
        let fakePNG = Data([0x89, 0x50, 0x4E, 0x47])
        let data = try ACPCodec.encodeSessionPrompt(
            id: 7,
            sessionId: "sess_abc",
            promptText: "What is broken here?",
            imagePNGData: fakePNG
        )
        let line = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(line.hasSuffix("\n"))

        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        XCTAssertEqual(json["method"]?.stringValue, "session/prompt")
        XCTAssertEqual(json["id"]?.intValue, 7)
        let blocks = try XCTUnwrap(json["params"]?["prompt"]?.arrayValue)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0]["type"]?.stringValue, "image")
        XCTAssertEqual(blocks[0]["mimeType"]?.stringValue, "image/png")
        XCTAssertEqual(blocks[0]["data"]?.stringValue, fakePNG.base64EncodedString())
        XCTAssertEqual(blocks[1]["type"]?.stringValue, "text")
        XCTAssertEqual(blocks[1]["text"]?.stringValue, "What is broken here?")
    }

    func testDecodeStreamingTextDeltaAndPermissionRequest() throws {
        let updateLine = """
        {"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s1","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"Hello!"}}}}
        """
        let decodedUpdate = try ACPCodec.decodeLine(updateLine)
        XCTAssertEqual(decodedUpdate, .textDelta(sessionId: "s1", text: "Hello!"))

        let permLine = """
        {"jsonrpc":"2.0","id":42,"method":"session/request_permission","params":{"sessionId":"s1","toolCall":{"title":"edit_file Sidebar.tsx","kind":"edit"},"options":[{"optionId":"allow_once","name":"Allow once","kind":"allow_once"},{"optionId":"reject_once","name":"Reject","kind":"reject_once"}]}}
        """
        let decodedPerm = try ACPCodec.decodeLine(permLine)
        if case .permissionRequest(let req) = decodedPerm {
            XCTAssertEqual(req.rpcId, .int(42))
            XCTAssertEqual(req.toolTitle, "edit_file Sidebar.tsx")
            XCTAssertEqual(req.options.count, 2)
            XCTAssertTrue(req.options[0].isAllow)
            XCTAssertFalse(req.options[1].isAllow)
        } else {
            XCTFail("Expected permissionRequest event")
        }
    }

    func testAppKitQuartzCoordinateRoundTrip() {
        let primaryHeight: CGFloat = 900
        let appKitRect = CGRect(x: 100, y: 700, width: 200, height: 150)
        let quartz = CoordinateGeometry.appKitToQuartz(rect: appKitRect, primaryDisplayHeight: primaryHeight)
        XCTAssertEqual(quartz, CGRect(x: 100, y: 50, width: 200, height: 150))

        let roundTrip = CoordinateGeometry.quartzToAppKit(rect: quartz, primaryDisplayHeight: primaryHeight)
        XCTAssertEqual(roundTrip, appKitRect)
    }

    func testScaledPixelSizeCapsLongEdge() {
        let capped = CoordinateGeometry.scaledPixelSize(
            pointSize: CGSize(width: 2000, height: 1000),
            backingScaleFactor: 2.0,
            maxLongEdge: 2560
        )
        XCTAssertEqual(capped.width, 2560)
        XCTAssertEqual(capped.height, 1280)
    }
}
