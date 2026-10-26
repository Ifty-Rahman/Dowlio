import Foundation

final class XMLTree: NSObject, XMLParserDelegate {
    let name: String
    private let attributes: [String: String]
    private(set) var elements: [XMLTree] = []
    private(set) var text = ""
    private var stack: [XMLTree] = []

    private init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    subscript(_ attribute: String) -> String? { attributes[attribute] }

    func children(_ name: String) -> [XMLTree] { elements.filter { $0.name == name } }

    func baseURL(against base: URL) -> URL {
        guard let value = children("BaseURL").first?.text.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
              let url = URL(string: value, relativeTo: base)?.absoluteURL else { return base }
        return url
    }

    static func parse(_ data: Data) -> XMLTree? {
        let document = XMLTree(name: "", attributes: [:])
        document.stack = [document]
        let parser = XMLParser(data: data)
        parser.delegate = document
        guard parser.parse() else { return nil }
        return document.elements.first
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        let element = XMLTree(name: local, attributes: attributes)
        stack.last?.elements.append(element)
        stack.append(element)
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        stack.removeLast()
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }
}
