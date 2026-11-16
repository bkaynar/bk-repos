import Foundation

public enum Format {
    /// "2 gündür", "3 saattir", "5 dakikadır": bir şeyin ne zamandır beklediği.
    public static func since(_ date: Date, now: Date = Date()) -> String {
        let (value, unit) = age(date, now: now)
        switch unit {
        case .minute: return value < 1 ? "az önce" : "\(value) dakikadır"
        case .hour: return "\(value) saattir"
        case .day: return "\(value) gündür"
        case .month: return "\(value) aydır"
        case .year: return "\(value) yıldır"
        }
    }

    /// "2 gün önce", "3 saat önce": bir şeyin ne zaman olduğu.
    public static func ago(_ date: Date, now: Date = Date()) -> String {
        let (value, unit) = age(date, now: now)
        switch unit {
        case .minute: return value < 1 ? "az önce" : "\(value) dakika önce"
        case .hour: return "\(value) saat önce"
        case .day: return value == 1 ? "dün" : "\(value) gün önce"
        case .month: return "\(value) ay önce"
        case .year: return "\(value) yıl önce"
        }
    }

    public static func days(_ date: Date, now: Date = Date()) -> Double {
        max(0, now.timeIntervalSince(date)) / 86_400
    }

    enum Unit { case minute, hour, day, month, year }

    static func age(_ date: Date, now: Date) -> (Int, Unit) {
        let seconds = max(0, now.timeIntervalSince(date))
        let days = Int(seconds / 86_400)
        if seconds < 3600 { return (Int(seconds / 60), .minute) }
        if days < 1 { return (Int(seconds / 3600), .hour) }
        if days < 60 { return (days, .day) }
        if days < 730 { return (days / 30, .month) }
        return (days / 365, .year)
    }

    /// Gün sayısını eşik metni olarak yazar: 1 → "1 gün", 0.5 → "12 saat".
    public static func threshold(days: Double) -> String {
        days >= 1 && days == days.rounded() ? "\(Int(days)) gün" : "\(Int((days * 24).rounded())) saat"
    }
}
