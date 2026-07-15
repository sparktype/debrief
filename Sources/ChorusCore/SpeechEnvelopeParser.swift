import Foundation

public enum SpeechEnvelopeParser {
    private static let prefix = "<!-- chorus:speak "
    private static let suffix = " -->"
    private static let requiredKeys: Set<String> = ["v", "text", "voice", "speed", "volume"]

    public static func extract(from message: String) -> SpeechEnvelope? {
        var upperBound = message.endIndex

        while let opening = message.range(
            of: prefix,
            options: .backwards,
            range: message.startIndex..<upperBound
        ) {
            if let closing = message.range(of: suffix, range: opening.upperBound..<message.endIndex) {
                let json = String(message[opening.upperBound..<closing.lowerBound])
                if let envelope = decodeAndValidate(json) {
                    return envelope
                }
            }
            upperBound = opening.lowerBound
        }

        return nil
    }

    private static func decodeAndValidate(_ json: String) -> SpeechEnvelope? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == requiredKeys,
              let envelope = try? JSONDecoder().decode(SpeechEnvelope.self, from: data)
        else {
            return nil
        }

        do {
            try envelope.validate()
            return envelope
        } catch {
            return nil
        }
    }
}
