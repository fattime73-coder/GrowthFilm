import Foundation

public struct Point: Codable, Equatable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

// All coordinates use image pixels with the origin at the bottom left.
public struct EyePair: Codable, Equatable {
    public var left: Point
    public var right: Point
    public init(_ a: Point, _ b: Point) {
        left = a.x <= b.x ? a : b
        right = a.x <= b.x ? b : a
    }
}

public struct Similarity {
    public var a: Double, b: Double, tx: Double, ty: Double
    public func apply(_ p: Point) -> Point {
        Point(a * p.x - b * p.y + tx, b * p.x + a * p.y + ty)
    }

    public static func align(_ eyes: EyePair, width: Double, height: Double,
                             eyeSpacing: Double, eyeHeight: Double) -> Similarity? {
        let dx = eyes.right.x - eyes.left.x
        let dy = eyes.right.y - eyes.left.y
        let square = dx * dx + dy * dy
        guard square > 4, width > 0, height > 0,
              [dx, dy, width, height, eyeSpacing, eyeHeight].allSatisfy({ $0.isFinite }),
              eyeSpacing > 0, eyeSpacing < 1, eyeHeight > 0, eyeHeight < 1 else { return nil }
        let distance = width * eyeSpacing
        let a = distance * dx / square
        let b = -distance * dy / square
        let cx = (eyes.left.x + eyes.right.x) / 2
        let cy = (eyes.left.y + eyes.right.y) / 2
        return Similarity(a: a, b: b, tx: width / 2 - a * cx + b * cy,
                          ty: height * eyeHeight - b * cx - a * cy)
    }
}
