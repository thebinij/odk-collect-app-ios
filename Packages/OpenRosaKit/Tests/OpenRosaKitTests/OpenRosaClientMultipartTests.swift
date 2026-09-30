import XCTest
@testable import OpenRosaKit

final class OpenRosaClientMultipartTests: XCTestCase {
    func testBodyContainsXMLSubmissionFilePart() {
        let xml = Data("<data/>".utf8)
        let body = OpenRosaClient.multipartBody(xml: xml, attachments: [], boundary: "B1")
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("--B1\r\n"))
        XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"xml_submission_file\"; filename=\"submission.xml\"\r\n"))
        XCTAssertTrue(text.contains("Content-Type: text/xml\r\n\r\n"))
        XCTAssertTrue(text.contains("<data/>"))
        XCTAssertTrue(text.hasSuffix("--B1--\r\n"))
    }

    func testBodyIncludesOneNamedPartPerAttachment() {
        let xml = Data("<data/>".utf8)
        let attachments = [
            SubmissionAttachment(filename: "photo1.jpg", contentType: "image/jpeg", data: Data([0xFF, 0xD8])),
            SubmissionAttachment(filename: "audio1.m4a", contentType: "audio/mp4", data: Data([0x01]))
        ]
        let body = OpenRosaClient.multipartBody(xml: xml, attachments: attachments, boundary: "B2")
        let text = String(decoding: body, as: UTF8.self)

        XCTAssertTrue(text.contains("name=\"photo1.jpg\"; filename=\"photo1.jpg\""))
        XCTAssertTrue(text.contains("Content-Type: image/jpeg"))
        XCTAssertTrue(text.contains("name=\"audio1.m4a\"; filename=\"audio1.m4a\""))
        XCTAssertTrue(text.contains("Content-Type: audio/mp4"))

        // Exactly one closing boundary, and it's the very last thing in the body.
        XCTAssertEqual(text.components(separatedBy: "--B2--").count, 2)
        XCTAssertTrue(text.hasSuffix("--B2--\r\n"))
    }

    func testPartsAppearInOrderWithXMLFirst() {
        let xml = Data("<data/>".utf8)
        let attachments = [SubmissionAttachment(filename: "z.jpg", contentType: "image/jpeg", data: Data([1]))]
        let body = OpenRosaClient.multipartBody(xml: xml, attachments: attachments, boundary: "B3")
        let text = String(decoding: body, as: UTF8.self)

        let xmlRange = text.range(of: "xml_submission_file")
        let attachmentRange = text.range(of: "z.jpg")
        XCTAssertNotNil(xmlRange)
        XCTAssertNotNil(attachmentRange)
        if let xmlRange, let attachmentRange {
            XCTAssertTrue(xmlRange.lowerBound < attachmentRange.lowerBound)
        }
    }

    func testBinaryAttachmentDataIsPreservedByteForByte() {
        let xml = Data("<data/>".utf8)
        let binary = Data((0..<256).map { UInt8($0) })
        let attachments = [SubmissionAttachment(filename: "bytes.bin", contentType: "application/octet-stream", data: binary)]
        let body = OpenRosaClient.multipartBody(xml: xml, attachments: attachments, boundary: "B4")

        XCTAssertTrue(body.range(of: binary) != nil)
    }
}
