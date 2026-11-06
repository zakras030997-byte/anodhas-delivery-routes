import Foundation
import PDFKit

#if TRANSFER_TEST_STUB
import SwiftUI
@MainActor final class RouteStore: ObservableObject {
    @Published var showImport = false
    var current: RoutePlan? = nil
    func updatePlan(affectsRoute: Bool = true, _ edit: (inout RoutePlan) -> Void) {}
}
enum FreightFormat {
    static func number(_ value: Double, digits: Int = 1) -> String {
        guard value.isFinite else { return "Не рассчитано" }
        let f = NumberFormatter(); f.locale = Locale(identifier: "ru_RU"); f.numberStyle = .decimal
        f.maximumFractionDigits = digits
        return f.string(from: NSNumber(value: value)) ?? String(value)
    }
    static func km(_ meters: Double) -> String { number(meters / 1000) + " км" }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "Не рассчитано" }
        let minutes = Int((seconds / 60).rounded())
        return minutes < 60 ? "\(minutes) мин" : "\(minutes / 60) ч \(minutes % 60) мин"
    }
    static func money(_ amount: Decimal?, currency: String) -> String {
        guard let amount, !amount.isNaN else { return "Не рассчитано" }
        let f = NumberFormatter(); f.locale = Locale(identifier: "ru_RU"); f.numberStyle = .decimal
        f.minimumFractionDigits = 2; f.maximumFractionDigits = 2
        return (f.string(from: NSDecimalNumber(decimal: amount)) ?? "Не рассчитано") + " " + currency
    }
}

#endif

@main struct TransferCheck {
    @MainActor static func main() throws {
        var passed: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ title: String) throws {
            guard condition() else { throw NSError(domain: "TransferCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: title]) }; passed.append(title)
        }
        let source = "\u{FEFF}Номер заказа;Груз;Адрес доставки;Масса, кг;Объём, м³;Палеты;Доставка с;Доставка до;Разгрузка, мин;Примечание\r\n1;\"Чай; кофе\";Санкт-Петербург;\"2,5\";0.2;1;10.11.2026 10:00;10.11.2026 12:00;15;\"первая строка\nвторая строка\"\r\n"
        let table = try Transfer.table(source)
        let mapping = Transfer.suggestedMapping(table)
        let preview = Transfer.preview(table, mapping: mapping, existing: [])
        try check(preview.problems.isEmpty, "BOM, quoted delimiter, multiline, decimal comma and Russian date")
        try check(preview.orders.first?.cargo == "Чай; кофе", "Quoted semicolon retained")
        try check(preview.orders.first?.deliveryWindow.from == "2026-11-10 10:00", "Date normalized without ambiguity")
        try check(preview.orders.first?.delivery.confirmed == false, "Imported addresses require confirmation")
        try check(!Transfer.preview(table, mapping: mapping, existing: preview.orders).problems.isEmpty, "Existing order duplicate rejected")
        let tab = try Transfer.table("Номер\tАдрес\n2\tМосква\n")
        try check(tab.headers.count == 2, "TSV parsed")
        do { _ = try Transfer.table("Номер;Адрес\n1;\"незакрыто"); throw RouteFailure.invalid("Missing quote accepted") } catch RouteFailure.invalid(let message) { try check(message.contains("кавычка"), "Unclosed quote rejected") }
        let units = try Transfer.table("Номер;Адрес;кг\n1;Москва;25 кг")
        try check(!Transfer.preview(units, mapping: Transfer.suggestedMapping(units), existing: []).problems.isEmpty, "Unknown units rejected")
        let dates = try Transfer.table("Номер;Адрес;Доставка с\n1;Москва;11/10/26 10:00")
        try check(!Transfer.preview(dates, mapping: Transfer.suggestedMapping(dates), existing: []).problems.isEmpty, "Ambiguous date rejected")
        var fifty = [DeliveryOrder](); for i in 0..<50 { var o = DeliveryOrder(); o.number = "old-\(i)"; fifty.append(o) }
        try check(!Transfer.preview(tab, mapping: Transfer.suggestedMapping(tab), existing: fifty).problems.isEmpty, "50-operation limit enforced before applying")
        var plan = RoutePlan(); plan.name = "Проверка маршрута"; var vehicle = FleetVehicle(); vehicle.name = "Грузовик"; plan.vehicles = [vehicle]
        var order = preview.orders[0]; order.number = "=SUM(1,2)"; order.contact = "СЕКРЕТНЫЙКОНТАКТ"; order.phone = "СЕКРЕТНЫЙТЕЛЕФОН"; order.note = String(repeating: "Длинная инструкция водителю: груз принять по накладной. ", count: 90); plan.orders = [order]
        let step = PlannedStep(orderID: order.id, kind: .delivery, title: "Выгрузка", address: "Санкт-Петербург", timeZone: "Europe/Moscow", arrival: 1_800_000_000, waitingSeconds: 0, serviceSeconds: 900, departure: 1_800_000_900, kgAfter: 0, m3After: 0, palletsAfter: 0, metersFromPrevious: 25000, drivingFromPrevious: 2000)
        let route = PlannedRoute(vehicleID: vehicle.id, vehicleName: vehicle.name, departure: 1_799_998_000, finish: 1_800_000_900, steps: [step], meters: 25000, drivingSeconds: 2000)
        let variant = PlanVariant(name: "Проверка", revision: 0, provider: "Valhalla", goal: .time, routes: [route])
        plan.variants = [variant]; plan.selectedVariant = variant.id
        let csv = try Transfer.csv(plan: plan, variant: variant)
        let csvText = String(data: csv, encoding: .utf8)!
        try check(csvText.contains("'=SUM"), "Spreadsheet formulas neutralized")
        try check(!csvText.contains("СЕКРЕТНЫЙ"), "CSV contacts omitted by default")
        let contactCSV = try Transfer.csv(plan: plan, variant: variant, includeContacts: true)
        try check(String(data: contactCSV, encoding: .utf8)!.contains("СЕКРЕТНЫЙКОНТАКТ"), "CSV contacts included only explicitly")
        let json = try Transfer.json(plan: plan)
        let copy = try Transfer.decodePlan(json)
        try check(copy.id != plan.id && copy.orders[0].id != order.id && copy.vehicles[0].id != vehicle.id, "JSON copy generates fresh identities")
        try check(copy.orders[0].deliveryWindow == order.deliveryWindow && copy.orders[0].note == order.note, "JSON keeps original fields and dates")
        try check(copy.variants.isEmpty && copy.selectedVariant == nil && copy.manualOrder.isEmpty, "JSON copy requires a fresh route calculation")
        var invalid = plan; invalid.variants[0].routes[0].vehicleID = UUID()
        do { _ = try Transfer.decodePlan(try Transfer.json(plan: invalid)); throw NSError(domain: "TransferCheck", code: 2) } catch RouteFailure.invalid { passed.append("Invalid JSON references rejected") }
        let pdf = try Transfer.pdf(plan: plan, variant: variant)
        try pdf.write(to: URL(fileURLWithPath: "Verification/transfer-route-sheet.pdf"))
        guard let document = PDFDocument(data: pdf), let text = document.string else { throw RouteFailure.invalid("PDF unreadable") }
        try text.write(toFile: "Verification/transfer-pdf-text.txt", atomically: true, encoding: .utf8)
        try check(document.pageCount > 1, "Long driver instructions paginate")
        try check(text.contains("Санкт-Петербург") && text.contains("Europe/Moscow"), "PDF contains readable Cyrillic and timezone")
        try check(!text.contains("СЕКРЕТНЫЙ"), "PDF contacts omitted by default")
        try check(text.contains("© OpenStreetMap contributors"), "PDF attribution retained")
        try pdf.write(to: URL(fileURLWithPath: "Verification/transfer-route-sheet.pdf"))
        try csv.write(to: URL(fileURLWithPath: "Verification/transfer-route-sheet.csv"))
        let report = passed.map { "PASS: " + $0 }.joined(separator: "\n") + "\nTotal: \(passed.count)\n"
        try report.write(toFile: "Verification/transfer-checks.txt", atomically: true, encoding: .utf8)
        print(report)
    }
}
