import Foundation
import Testing
@testable import CasaKit

@Suite("Format")
struct FormattingTests {
    @Test func bytesUseBinaryUnits() {
        #expect(Format.bytes(Int64(0)) == "0 B")
        #expect(Format.bytes(Int64(512)) == "512 B")
        #expect(Format.bytes(Int64(1024)) == "1.00 KB")
        #expect(Format.bytes(Int64(1_610_612_736)) == "1.50 GB")
        #expect(Format.bytes(Int64(13_207_024_435)) == "12.3 GB")
        #expect(Format.bytes(Int64(53_687_091_200)) == "50.0 GB")
        #expect(Format.bytes(Int64(128 * 1_073_741_824)) == "128 GB")
        #expect(Format.bytes(Int64(-5)) == "0 B")
    }

    @Test func trafficShowsUsedOfLimit() {
        #expect(Format.traffic(used: 3_221_225_472, limit: 53_687_091_200) == "3.00 GB of 50.0 GB")
        #expect(Format.traffic(used: 3_221_225_472, limit: nil) == "3.00 GB used")
        #expect(Format.traffic(used: 100, limit: 0) == "100 B used")
    }

    @Test func trafficFractionIsClamped() {
        #expect(Format.trafficFraction(used: 50, limit: 100) == 0.5)
        #expect(Format.trafficFraction(used: 500, limit: 100) == 1)
        #expect(Format.trafficFraction(used: 5, limit: nil) == nil)
    }

    @Test func percentRounds() {
        #expect(Format.percent(12.5) == "13%")
        #expect(Format.percent(0) == "0%")
    }

    @Test func uptimeUsesTheTwoLargestUnits() {
        #expect(Format.uptime(seconds: 987_654) == "11 d 10 h")
        #expect(Format.uptime(seconds: 5 * 3600 + 12 * 60 + 9) == "5 h 12 min")
        #expect(Format.uptime(seconds: 180) == "3 min")
        #expect(Format.uptime(seconds: 12) == "under a minute")
    }
}

@Suite("ExpiryInfo")
struct ExpiryTests {
    let now = Date(timeIntervalSince1970: 1_792_000_000)
    func ms(plusDays days: Double) -> Int64 { Int64((now.timeIntervalSince1970 + days * 86_400) * 1000) }

    @Test func zeroMeansNoExpiry() {
        let info = ExpiryInfo.describe(expiryTime: 0, now: now)
        #expect(info.kind == .never)
        #expect(info.text == "No expiry")
        #expect(!info.isUrgent)
    }

    @Test func futureDates() {
        let info = ExpiryInfo.describe(expiryTime: ms(plusDays: 12.5), now: now)
        #expect(info.kind == .active)
        #expect(info.text == "Expires in 12 days")
        #expect(!info.isUrgent)
        #expect(ExpiryInfo.describe(expiryTime: ms(plusDays: 1.2), now: now).text == "Expires in 1 day")
    }

    @Test func lessThanThreeDaysIsUrgent() {
        #expect(ExpiryInfo.describe(expiryTime: ms(plusDays: 2.9), now: now).isUrgent)
        #expect(!ExpiryInfo.describe(expiryTime: ms(plusDays: 3.1), now: now).isUrgent)
    }

    @Test func hoursAndMinutes() {
        #expect(ExpiryInfo.describe(expiryTime: ms(plusDays: 5.0 / 24 + 0.001), now: now).text == "Expires in 5 hours")
        #expect(ExpiryInfo.describe(expiryTime: ms(plusDays: 20.5 / 1440), now: now).text == "Expires in 20 minutes")
        #expect(ExpiryInfo.describe(expiryTime: ms(plusDays: 10.0 / 86_400), now: now).text == "Expires in under a minute")
    }

    @Test func pastDatesAreExpired() {
        let info = ExpiryInfo.describe(expiryTime: ms(plusDays: -3.5), now: now)
        #expect(info.kind == .expired)
        #expect(info.text == "Expired 3 days ago")
        #expect(info.isUrgent)
    }

    @Test func negativeValuesStartOnFirstUse() {
        let info = ExpiryInfo.describe(expiryTime: -30 * 86_400_000, now: now)
        #expect(info.kind == .startsOnFirstUse(days: 30))
        #expect(info.text == "Starts on first use, then 30 days")
        #expect(!info.isUrgent)
    }
}

@Suite("QRCode")
struct QRCodeTests {
    @Test func rendersABitmapForALink() throws {
        let image = try #require(QRCode.cgImage(for: "https://vpn.example.com:8443/sub/abc123", scale: 4))
        #expect(image.width == image.height)
        #expect(image.width > 40)
    }

    @Test func emptyTextHasNoCode() {
        #expect(QRCode.cgImage(for: "") == nil)
    }
}
