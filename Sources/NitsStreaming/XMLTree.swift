import Foundation

/// An XML document as a tree of values, to read a manifest: element names, attributes and text are kept as they are,
/// namespaces included (prefixes are not resolved), comments and processing instructions are not.
package struct XMLTreeElement {
    var name: String
    package var attributes: [(name: String, value: String)] = []
    package var children: [Node] = []

    package enum Node {
        case element(XMLTreeElement)
        case text(String)
    }

    /// The name without a namespace prefix (`mpd:Period` → `Period`).
    package var localName: String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    package func attribute(_ name: String) -> String? {
        attributes.first { $0.name == name }?.value
    }

    /// The child elements.
    package var elements: [XMLTreeElement] {
        children.compactMap { if case .element(let element) = $0 { element } else { nil } }
    }

    /// The child elements named (without prefix) `localName`.
    package func elements(named localName: String) -> [XMLTreeElement] {
        elements.filter { $0.localName == localName }
    }

    /// The text directly in the element, trimmed.
    package var text: String {
        children.compactMap { if case .text(let text) = $0 { text } else { nil } }
            .joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The document `data` holds; nil when it is not well-formed XML or is larger than `limit` bytes.
    package static func parse(_ data: Data, limit: Int) -> XMLTreeElement? {
        guard data.count <= limit else { return nil }
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), builder.stack.isEmpty else { return nil }
        return builder.root
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var stack: [XMLTreeElement] = []
        var root: XMLTreeElement?

        func parser(
            _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
            qualifiedName qName: String?, attributes attributeDict: [String: String]
        ) {
            // The parser hands the attributes over as a dictionary: sorted, so that the output does not vary.
            stack.append(
                XMLTreeElement(
                    name: elementName,
                    attributes: attributeDict.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }))
        }

        func parser(
            _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
        ) {
            guard let element = stack.popLast() else { return }
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(.element(element))
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            if case .text(let previous)? = stack[stack.count - 1].children.last {
                stack[stack.count - 1].children[stack[stack.count - 1].children.count - 1] = .text(previous + string)
            } else {
                stack[stack.count - 1].children.append(.text(string))
            }
        }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            self.parser(parser, foundCharacters: String(decoding: block, as: UTF8.self))
        }
    }
}
