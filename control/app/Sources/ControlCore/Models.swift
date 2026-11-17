import Foundation

// Shapes of the LINE21 Control server's JSON (control/server/src). Money is in minor units (øre, cents).

public struct Overview: Decodable, Equatable {
    public var active: Int
    public var trialing: Int
    public var pastDue: Int
    public var newThisMonth: Int
    public var canceled30d: Int
    public var mrr: [String: Double]
    public var revenue30d: [String: Double]

    public init(active: Int = 0, trialing: Int = 0, pastDue: Int = 0, newThisMonth: Int = 0, canceled30d: Int = 0, mrr: [String: Double] = [:], revenue30d: [String: Double] = [:]) {
        self.active = active
        self.trialing = trialing
        self.pastDue = pastDue
        self.newThisMonth = newThisMonth
        self.canceled30d = canceled30d
        self.mrr = mrr
        self.revenue30d = revenue30d
    }
}

public struct Subscriber: Decodable, Identifiable, Equatable {
    public var id: String
    public var email: String?
    public var name: String?
    public var country: String?
    public var livemode: Bool?
    public var status: String
    public var product: String?
    public var interval: String?
    public var amount: Double?
    public var currency: String?
    public var renewsAt: String?
    public var endsAt: String?
    public var since: String?

    public var title: String { email ?? name ?? id }
    public var subtitle: String { [email == nil ? nil : name, country].compactMap { $0 }.joined(separator: " · ") }
}

public struct SubscriberList: Decodable {
    public var subscribers: [Subscriber]
}

public struct Customer: Decodable, Equatable {
    public var id: String
    public var email: String?
    public var name: String?
    public var country: String?
    public var livemode: Bool?
    public var createdAt: String?
}

public struct Subscription: Decodable, Identifiable, Equatable {
    public var id: String
    public var status: String?
    public var product: String?
    public var interval: String?
    public var amount: Double?
    public var currency: String?
    public var trialEnd: String?
    public var currentPeriodEnd: String?
    public var cancelAtPeriodEnd: Bool?
    public var createdAt: String?
    public var livemode: Bool?

    /// The date that matters next: when a trial converts, else when the period ends.
    public var nextDate: String? { status == "trialing" ? trialEnd : currentPeriodEnd }
}

public struct Invoice: Decodable, Identifiable, Equatable {
    public var id: String
    public var status: String?
    public var amountDue: Double?
    public var amountPaid: Double?
    public var currency: String?
    public var createdAt: String?
    public var paidAt: String?
    public var hostedUrl: String?

    public var amount: Double? { status == "paid" ? amountPaid : amountDue }
    public var date: String? { paidAt ?? createdAt }
}

public struct SubscriberDetail: Decodable {
    public var customer: Customer
    public var subscriptions: [Subscription]
    public var invoices: [Invoice]

    public var livemode: Bool { customer.livemode ?? subscriptions.first?.livemode ?? false }
    public var stripeURL: URL {
        URL(string: "https://dashboard.stripe.com/\(livemode ? "" : "test/")customers/\(customer.id)")!
    }
}

/// The Hub API's anonymous usage stats, passed through by the Control server.
public struct HubStats: Decodable {
    public struct Day: Decodable, Identifiable {
        public var day: String
        public var active: Int
        public var downloads: Int
        public var installs: Int
        public var failures: Int
        public var id: String { day }
    }

    public struct Target: Decodable {
        public var label: String?
        public var latest: String?
    }

    public var days: Int
    public var activeInstalls: Int
    public var reportingHubs: Int
    public var downloads: [String: [String: Int]]
    public var installs: [String: [String: Int]]
    public var failures: [String: [String: Int]]
    public var installed: [String: [String: Int]]
    public var hostVersions: [String: [String: Int]]
    public var hubVersions: [String: Int]
    public var osVersions: [String: Int]
    public var daily: [Day]
    public var targets: [String: Target]?

    public func label(_ target: String) -> String { targets?[target]?.label ?? target }
    public func total(_ table: [String: [String: Int]]) -> Int { table.values.flatMap(\.values).reduce(0, +) }
}

public struct APIError: Decodable, Error, LocalizedError {
    public var error: String
    public var errorDescription: String? { error }
}
