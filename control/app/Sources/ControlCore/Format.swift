import Foundation

/// Display helpers shared by the views. All text is English.
public enum Format {
    public static let productNames = ["proxel": "PROXEL"]

    public static let statusNames = [
        "active": "Active", "trialing": "In trial", "past_due": "Past due", "unpaid": "Unpaid", "canceled": "Canceled",
        "incomplete": "Incomplete", "incomplete_expired": "Expired", "paused": "Paused", "none": "No plan",
        "paid": "Paid", "failed": "Failed", "open": "Open", "void": "Void", "draft": "Draft", "uncollectible": "Uncollectible",
    ]

    public static func status(_ s: String?) -> String { s.flatMap { statusNames[$0] ?? $0 } ?? "—" }

    public static func plan(product: String?, interval: String?) -> String {
        let name = product.map { productNames[$0] ?? $0 } ?? "—"
        switch interval {
        case "month": return "\(name) · Monthly"
        case "year": return "\(name) · Yearly"
        case let i?: return "\(name) · \(i)"
        case nil: return name
        }
    }

    /// 9900 + "dkk" → "DKK 99.00". Stripe amounts are in minor units.
    public static func money(_ minor: Double?, _ currency: String?) -> String {
        guard let minor, let currency, !currency.isEmpty else { return "—" }
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.locale = Locale(identifier: "en_US_POSIX")
        f.currencyCode = currency.uppercased()
        f.currencySymbol = currency.uppercased() + " "
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: NSNumber(value: minor / 100)) ?? "\(currency.uppercased()) \(minor / 100)"
    }

    /// Several currencies joined: "DKK 277.20 + EUR 12.00". Empty → "0".
    public static func money(_ byCurrency: [String: Double]) -> String {
        let parts = byCurrency.sorted { $0.key < $1.key }.map { money($0.value, $0.key) }
        return parts.isEmpty ? "0" : parts.joined(separator: " + ")
    }

    /// "2026-11-17T12:00:00.000Z" → "2026-11-17".
    public static func day(_ iso: String?) -> String { iso.map { String($0.prefix(10)) } ?? "—" }

    public static func initials(_ s: String) -> String {
        let letters = s.split(whereSeparator: { !$0.isLetter }).prefix(2).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
