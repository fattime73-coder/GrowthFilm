import XCTest
@testable import AlignmentCore

final class AlignmentTests: XCTestCase {
    func testBothEyesLandExactlyOnTargets() throws {
        for eyes in [EyePair(Point(110, 400), Point(280, 450)),
                     EyePair(Point(800, 900), Point(400, 780)),
                     EyePair(Point(20, 20), Point(80, 20))] {
            let t = try XCTUnwrap(Similarity.align(eyes, width: 1080, height: 1920,
                                                  eyeSpacing: 0.28, eyeHeight: 0.62))
            let left = t.apply(eyes.left), right = t.apply(eyes.right)
            XCTAssertEqual(left.x, 388.8, accuracy: 0.00001)
            XCTAssertEqual(right.x, 691.2, accuracy: 0.00001)
            XCTAssertEqual(left.y, 1190.4, accuracy: 0.00001)
            XCTAssertEqual(right.y, 1190.4, accuracy: 0.00001)
        }
    }
    func testRejectsCoincidentEyes() {
        XCTAssertNil(Similarity.align(EyePair(Point(0,0), Point(0,0)), width: 100,
                                      height: 100, eyeSpacing: 0.3, eyeHeight: 0.6))
    }
    func testShapeIsNotDistorted() throws {
        let t = try XCTUnwrap(Similarity.align(EyePair(Point(20,30), Point(70,80)),
                                              width: 1080, height: 1080,
                                              eyeSpacing: 0.25, eyeHeight: 0.6))
        let o = t.apply(Point(0,0)), x = t.apply(Point(1,0)), y = t.apply(Point(0,1))
        XCTAssertEqual(hypot(x.x-o.x, x.y-o.y), hypot(y.x-o.x, y.y-o.y), accuracy: 1e-9)
        XCTAssertEqual((x.x-o.x)*(y.x-o.x)+(x.y-o.y)*(y.y-o.y), 0, accuracy: 1e-9)
    }
}
