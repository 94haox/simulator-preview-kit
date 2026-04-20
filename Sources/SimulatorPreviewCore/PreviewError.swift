import Foundation

public enum PreviewError: Error, CustomStringConvertible {
    case message(String)
    case invalidAppBundle(String)
    case missingBundleIdentifier(String)

    public var description: String {
        switch self {
        case .message(let value):
            return value
        case .invalidAppBundle(let path):
            return "Invalid app bundle: \(path)"
        case .missingBundleIdentifier(let path):
            return "App bundle is missing CFBundleIdentifier: \(path)"
        }
    }

    public static func userMessage(for error: Error) -> String {
        if let error = error as? PreviewError {
            return error.description
        }
        if let error = error as? CommandFailure {
            return error.description
        }
        return String(describing: error)
    }
}
