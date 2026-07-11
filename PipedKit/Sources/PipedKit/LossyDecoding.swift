import Foundation

private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

private struct AnyDecodableValue: Decodable {
    init(from decoder: Decoder) throws {
        if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                _ = try? array.decode(AnyDecodableValue.self)
            }
            return
        }

        if let object = try? decoder.container(keyedBy: AnyCodingKey.self) {
            for key in object.allKeys {
                _ = try? object.decode(AnyDecodableValue.self, forKey: key)
            }
            return
        }

        let value = try decoder.singleValueContainer()
        if value.decodeNil() { return }
        if (try? value.decode(Bool.self)) != nil { return }
        if (try? value.decode(Double.self)) != nil { return }
        if (try? value.decode(String.self)) != nil { return }
    }
}

extension KeyedDecodingContainer {
    func decodeLossyArray<Element: Decodable>(
        _ type: [Element].Type,
        forKey key: Key
    ) throws -> [Element]? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        var container = try nestedUnkeyedContainer(forKey: key)
        var output: [Element] = []
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                output.append(element)
            } else if (try? container.decode(AnyDecodableValue.self)) == nil {
                break
            }
        }
        return output
    }
}
