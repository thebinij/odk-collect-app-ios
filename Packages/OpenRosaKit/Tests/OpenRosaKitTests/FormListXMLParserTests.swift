import XCTest
@testable import OpenRosaKit

final class FormListXMLParserTests: XCTestCase {
    func testParsesTypicalFormListResponse() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xforms xmlns="http://openrosa.org/xforms/xformsList">
          <xform>
            <formID>widgets</formID>
            <name>Widgets</name>
            <version>2015083101</version>
            <hash>md5:c98d61bc6db3c774f6f66e9057c46f47</hash>
            <downloadUrl>https://example.org/formXml?formId=widgets</downloadUrl>
            <manifestUrl>https://example.org/xformsManifest?formId=widgets</manifestUrl>
          </xform>
          <xform>
            <formID>simple</formID>
            <name>Simple Form</name>
            <downloadUrl>https://example.org/formXml?formId=simple</downloadUrl>
          </xform>
        </xforms>
        """
        let forms = try FormListXMLParser.parse(Data(xml.utf8))

        XCTAssertEqual(forms.count, 2)

        XCTAssertEqual(forms[0].formID, "widgets")
        XCTAssertEqual(forms[0].name, "Widgets")
        XCTAssertEqual(forms[0].version, "2015083101")
        XCTAssertEqual(forms[0].hash, "md5:c98d61bc6db3c774f6f66e9057c46f47")
        XCTAssertEqual(forms[0].downloadURL.absoluteString, "https://example.org/formXml?formId=widgets")
        XCTAssertEqual(forms[0].manifestURL?.absoluteString, "https://example.org/xformsManifest?formId=widgets")

        XCTAssertEqual(forms[1].formID, "simple")
        XCTAssertNil(forms[1].version)
        XCTAssertNil(forms[1].hash)
        XCTAssertNil(forms[1].manifestURL)
    }

    func testEmptyFormListReturnsNoForms() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xforms xmlns="http://openrosa.org/xforms/xformsList"></xforms>
        """
        let forms = try FormListXMLParser.parse(Data(xml.utf8))
        XCTAssertTrue(forms.isEmpty)
    }

    func testEntryMissingFormIDIsSkipped() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xforms xmlns="http://openrosa.org/xforms/xformsList">
          <xform>
            <name>No ID</name>
            <downloadUrl>https://example.org/formXml?formId=noid</downloadUrl>
          </xform>
          <xform>
            <formID>ok</formID>
            <name>OK</name>
            <downloadUrl>https://example.org/formXml?formId=ok</downloadUrl>
          </xform>
        </xforms>
        """
        let forms = try FormListXMLParser.parse(Data(xml.utf8))
        XCTAssertEqual(forms.map(\.formID), ["ok"])
    }

    func testEntryMissingNameFallsBackToFormID() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <xforms xmlns="http://openrosa.org/xforms/xformsList">
          <xform>
            <formID>unnamed</formID>
            <downloadUrl>https://example.org/formXml?formId=unnamed</downloadUrl>
          </xform>
        </xforms>
        """
        let forms = try FormListXMLParser.parse(Data(xml.utf8))
        XCTAssertEqual(forms.first?.name, "unnamed")
    }

    func testMalformedXMLThrows() {
        let data = Data("not xml at all <<<".utf8)
        XCTAssertThrowsError(try FormListXMLParser.parse(data))
    }
}
