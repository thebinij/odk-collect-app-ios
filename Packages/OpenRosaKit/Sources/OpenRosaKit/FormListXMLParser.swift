import Foundation

enum FormListParsingError: Error {
    case invalidXML(underlying: Error?)
}

/// Parses an OpenRosa `formList` (xformsList) XML response into `[RemoteForm]`.
final class FormListXMLParser: NSObject, XMLParserDelegate {
    private var forms: [RemoteForm] = []
    private var currentValue = ""
    private var insideXform = false

    private var formID: String?
    private var name: String?
    private var version: String?
    private var formHash: String?
    private var downloadURLString: String?
    private var manifestURLString: String?

    static func parse(_ data: Data) throws -> [RemoteForm] {
        let parser = XMLParser(data: data)
        let delegate = FormListXMLParser()
        parser.delegate = delegate
        guard parser.parse() else {
            throw FormListParsingError.invalidXML(underlying: parser.parserError)
        }
        return delegate.forms
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        currentValue = ""
        if elementName == "xform" {
            insideXform = true
            formID = nil
            name = nil
            version = nil
            formHash = nil
            downloadURLString = nil
            manifestURLString = nil
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentValue += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let trimmed = currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
        defer { currentValue = "" }
        guard insideXform else { return }

        switch elementName {
        case "formID": formID = trimmed
        case "name": name = trimmed
        case "version": version = trimmed.isEmpty ? nil : trimmed
        case "hash": formHash = trimmed.isEmpty ? nil : trimmed
        case "downloadUrl": downloadURLString = trimmed
        case "manifestUrl": manifestURLString = trimmed.isEmpty ? nil : trimmed
        case "xform":
            insideXform = false
            if
                let formID, !formID.isEmpty,
                let downloadURLString, let downloadURL = URL(string: downloadURLString)
            {
                forms.append(
                    RemoteForm(
                        formID: formID,
                        name: (name?.isEmpty == false ? name! : formID),
                        version: version,
                        hash: formHash,
                        downloadURL: downloadURL,
                        manifestURL: manifestURLString.flatMap(URL.init(string:))
                    )
                )
            }
        default:
            break
        }
    }
}
