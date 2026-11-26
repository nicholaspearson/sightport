import XCTest
@testable import SightportCore

final class ResourceAgeTests: XCTestCase {
    func testAgeBoundariesAndNextChange() throws {
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2020-01-01T12:30:00Z"))
        let day = 86_400
        for (seconds, expected, next) in [(-2, "0s", 1), (59, "59s", 60), (60, "1m", 120),
                                          (3600, "1h", 7200), (day, "1d", 2 * day),
                                          (365 * day, "365d", 366 * day), (366 * day, "1y", 367 * day),
                                          (1191 * day, "3y95d", 1192 * day)] {
            let age = ResourceAge(createdAt: start, now: start.addingTimeInterval(Double(seconds)))
            XCTAssertEqual(age.text, expected)
            XCTAssertEqual(age.nextChange, start.addingTimeInterval(Double(next)))
        }
    }
}
