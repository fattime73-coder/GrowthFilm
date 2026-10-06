import XCTest
@testable import AlignmentCore

final class TemporalSamplerTests: XCTestCase {
    func testChronologicalOrderAndMissingDates() {
        XCTAssertEqual(TemporalSampler.indices(timestamps: [30, nil, 10, .nan, 20]), [2, 4, 0])
        XCTAssertEqual(TemporalSampler.indices(timestamps: [nil, .infinity]), [])
        XCTAssertEqual(TemporalSampler.indices(timestamps: [0, 1], maximum: 0), [])
    }
    func testUniformTimelineRetainsEndpoints() {
        let times = (0...100).map { Optional(Double($0)) }
        XCTAssertEqual(TemporalSampler.indices(timestamps: times, maximum: 5), [0, 25, 50, 75, 100])
    }
    func testBurstDoesNotDominateLongPeriod() {
        let times = (0..<1000).map { Optional(Double($0) / 1000) } + [100, 200, 300, 400]
        XCTAssertEqual(TemporalSampler.indices(timestamps: times, maximum: 5), [0, 1000, 1001, 1002, 1003])
    }
    func testDefaultLimitIs2000UniquePhotos() {
        let times = (0..<12000).map { Optional(Double($0)) }
        let result = TemporalSampler.indices(timestamps: times)
        XCTAssertEqual(result.count, 2000)
        XCTAssertEqual(Set(result).count, 2000)
        XCTAssertEqual(result.first, 0)
        XCTAssertEqual(result.last, 11999)
        XCTAssertEqual(result, result.sorted())
    }
    func testIdenticalDatesAreDeterministicAndDistinct() {
        let times = Array<Double?>(repeating: 50, count: 101)
        XCTAssertEqual(TemporalSampler.indices(timestamps: times, maximum: 5), [0, 25, 50, 75, 100])
    }
    func testSparseDatesStillProduceRequestedCount() {
        let times: [Double?] = [0, 0, 0, 0, 0, 0, 10000, 10000, 10000]
        let result = TemporalSampler.indices(timestamps: times, maximum: 7)
        XCTAssertEqual(result.count, 7)
        XCTAssertEqual(Set(result).count, 7)
        XCTAssertEqual(result.first, 0)
        XCTAssertEqual(result.last, 8)
        XCTAssertEqual(result, result.sorted())
    }
    func testSmallInputsAndSingleSelection() {
        XCTAssertEqual(TemporalSampler.indices(timestamps: []), [])
        XCTAssertEqual(TemporalSampler.indices(timestamps: [9]), [0])
        XCTAssertEqual(TemporalSampler.indices(timestamps: [0, 4, 10], maximum: 1), [1])
        XCTAssertEqual(TemporalSampler.indices(timestamps: [0, 4, 10], maximum: 2), [0, 2])
    }
}
