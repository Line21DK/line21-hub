import XCTest
@testable import ControlCore

// Fixtures are real responses from control/server with seeded Stripe test events.
final class ControlCoreTests: XCTestCase {
    func testDecodesOverview() throws {
        let json = #"{"active":2,"trialing":1,"pastDue":1,"newThisMonth":1,"canceled30d":1,"mrr":{"dkk":27720},"revenue30d":{}}"#
        let o = try JSONDecoder().decode(Overview.self, from: Data(json.utf8))
        XCTAssertEqual(o.active, 2)
        XCTAssertEqual(Format.money(o.mrr), "DKK 277.20")
        XCTAssertEqual(Format.money(o.revenue30d), "0")
    }

    func testDecodesSubscribers() throws {
        let json = #"{"subscribers":[{"id":"cus_A1","email":"mette.hansen@example.com","name":"Mette Hansen","country":"DK","livemode":false,"status":"active","product":"proxel","interval":"month","amount":9900,"currency":"dkk","renewsAt":"2026-12-07T13:49:32.000Z","endsAt":null,"since":"2026-10-08T13:49:32.000Z"},{"id":"cus_X","email":null,"name":null,"status":"none","product":null,"interval":null,"amount":null,"currency":null,"renewsAt":null,"endsAt":null,"since":null}]}"#
        let list = try JSONDecoder().decode(SubscriberList.self, from: Data(json.utf8)).subscribers
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].subtitle, "Mette Hansen · DK")
        XCTAssertEqual(Format.plan(product: list[0].product, interval: list[0].interval), "PROXEL · Monthly")
        XCTAssertEqual(Format.money(list[0].amount, list[0].currency), "DKK 99.00")
        XCTAssertEqual(Format.day(list[0].renewsAt), "2026-12-07")
        XCTAssertEqual(list[1].title, "cus_X")
        XCTAssertEqual(Format.status(list[1].status), "No plan")
    }

    func testDecodesDetail() throws {
        let json = #"{"customer":{"livemode":false,"eventAt":1794923372,"id":"cus_D4","email":"markus@example.de","name":"Markus Vogel","country":"DE","createdAt":"2026-09-08T13:49:32.000Z","deleted":false},"subscriptions":[{"livemode":false,"eventAt":1794923372,"id":"sub_cus_D4","customerId":"cus_D4","status":"past_due","product":"proxel","priceId":"price_m","interval":"month","intervalCount":1,"amount":9900,"currency":"dkk","quantity":1,"trialEnd":null,"currentPeriodEnd":"2026-12-07T13:49:32.000Z","cancelAtPeriodEnd":false,"canceledAt":null,"endedAt":null,"createdAt":"2026-09-08T13:49:32.000Z"}],"invoices":[{"livemode":false,"eventAt":1794923372,"id":"in_fail","customerId":"cus_D4","subscriptionId":"sub_cus_D4","status":"failed","amountDue":9900,"amountPaid":0,"currency":"dkk","createdAt":"2026-11-16T13:49:32.000Z","paidAt":null,"hostedUrl":null}]}"#
        let d = try JSONDecoder().decode(SubscriberDetail.self, from: Data(json.utf8))
        XCTAssertEqual(d.stripeURL.absoluteString, "https://dashboard.stripe.com/test/customers/cus_D4")
        XCTAssertEqual(d.subscriptions[0].nextDate, "2026-12-07T13:49:32.000Z")
        XCTAssertEqual(d.invoices[0].amount, 9900)
        XCTAssertEqual(Format.status(d.invoices[0].status), "Failed")
    }

    func testDecodesHubStats() throws {
        let json = #"{"days":7,"activeInstalls":3,"reportingHubs":2,"events":{"check":4},"downloads":{"lineseparator-ofx-macos":{"0.3.0":2}},"installs":{},"failures":{"floatblur-ofx-macos":{"admin_cancelled":1}},"installed":{},"hostVersions":{"davinci-resolve":{"20.2":1}},"hubVersions":{"0.1.9":2},"osVersions":{"15.1":2},"daily":[{"day":"2026-11-16","active":2,"downloads":1,"installs":0,"failures":1}],"targets":{"lineseparator-ofx-macos":{"label":"LineSeparator","latest":"0.3.0"},"davinci-resolve":{"label":"DaVinci Resolve","latest":null}}}"#
        let s = try JSONDecoder().decode(HubStats.self, from: Data(json.utf8))
        XCTAssertEqual(s.total(s.downloads), 2)
        XCTAssertEqual(s.label("lineseparator-ofx-macos"), "LineSeparator")
        XCTAssertEqual(s.label("unknown"), "unknown")
        XCTAssertEqual(s.daily.first?.active, 2)
    }

    func testInitials() {
        XCTAssertEqual(Format.initials("mette.hansen@example.com"), "MH")
        XCTAssertEqual(Format.initials("Lea"), "L")
        XCTAssertEqual(Format.initials("—"), "?")
    }
}
