import Foundation

public struct PreviewKeyModifiers: Codable, Equatable, Sendable {
    public let shift: Bool
    public let control: Bool
    public let option: Bool
    public let command: Bool

    public init(shift: Bool = false, control: Bool = false, option: Bool = false, command: Bool = false) {
        self.shift = shift
        self.control = control
        self.option = option
        self.command = command
    }
}

public struct PreviewInteractionEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case touchDown
        case touchMove
        case touchUp
        case scroll
        case keyDown
    }

    public let kind: Kind
    public let x: Double?
    public let y: Double?
    public let deltaX: Double?
    public let deltaY: Double?
    public let key: String?
    public let code: String?
    public let modifiers: PreviewKeyModifiers?

    public init(
        kind: Kind,
        x: Double? = nil,
        y: Double? = nil,
        deltaX: Double? = nil,
        deltaY: Double? = nil,
        key: String? = nil,
        code: String? = nil,
        modifiers: PreviewKeyModifiers? = nil
    ) {
        self.kind = kind
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.key = key
        self.code = code
        self.modifiers = modifiers
    }
}
