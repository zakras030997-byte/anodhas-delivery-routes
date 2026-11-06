import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum ExportKind { case summaryCSV, itineraryPDF, projectJSON }

struct FreightTable {
    var headers: [String]
    var rows: [[String]]
}

enum ImportField: String, CaseIterable, Identifiable {
    case number = "Номер заказа", cargo = "Груз", kg = "Масса, кг", m3 = "Объём, м³", pallets = "Палеты"
    case delivery = "Адрес доставки", deliveryLat = "Широта доставки", deliveryLon = "Долгота доставки", deliveryZone = "Пояс доставки"
    case deliveryFrom = "Доставка с", deliveryUntil = "Доставка до", deliveryMinutes = "Разгрузка, мин"
    case pickup = "Адрес погрузки", pickupLat = "Широта погрузки", pickupLon = "Долгота погрузки", pickupZone = "Пояс погрузки"
    case pickupFrom = "Погрузка с", pickupUntil = "Погрузка до", pickupMinutes = "Погрузка, мин"
    case priority = "Приоритет", skills = "Требования", contact = "Контакт", phone = "Телефон", revenue = "Выручка", note = "Примечание"
    var id: String { rawValue }
    var aliases: [String] {
        switch self {
        case .number: return ["number", "order", "номер", "номерзаказа", "заказ"]
        case .cargo: return ["cargo", "товар", "груз", "наименование"]
        case .kg: return ["kg", "масса", "масса,кг", "вес", "вескг", "кг"]
        case .m3: return ["m3", "объем", "объём", "объём,м³", "объемм3"]
        case .pallets: return ["pallets", "палеты", "паллеты"]
        case .delivery: return ["delivery", "address", "адрес", "адресдоставки", "выгрузка"]
        case .deliveryLat: return ["deliverylat", "широтадоставки", "latitude", "широта"]
        case .deliveryLon: return ["deliverylon", "долготадоставки", "longitude", "долгота"]
        case .deliveryZone: return ["deliveryzone", "поясдоставки", "timezone", "часовойпояс"]
        case .deliveryFrom: return ["deliveryfrom", "доставкас", "окнос", "с"]
        case .deliveryUntil: return ["deliveryuntil", "доставкадо", "окнодо", "до"]
        case .deliveryMinutes: return ["deliveryminutes", "разгрузка,мин", "разгрузкамин", "обслуживаниемин"]
        case .pickup: return ["pickup", "адреспогрузки", "погрузка"]
        case .pickupLat: return ["pickuplat", "широтапогрузки"]
        case .pickupLon: return ["pickuplon", "долготапогрузки"]
        case .pickupZone: return ["pickupzone", "пояспогрузки"]
        case .pickupFrom: return ["pickupfrom", "погрузкас"]
        case .pickupUntil: return ["pickupuntil", "погрузкадо"]
        case .pickupMinutes: return ["pickupminutes", "погрузка,мин", "погрузкамин"]
        case .priority: return ["priority", "приоритет"]
        case .skills: return ["skills", "требования"]
        case .contact: return ["contact", "контакт", "клиент"]
        case .phone: return ["phone", "телефон"]
        case .revenue: return ["revenue", "выручка", "стоимостьзаказа"]
        case .note: return ["note", "примечание", "комментарий"]
        }
    }
}

struct FreightImportPreview {
    var orders: [DeliveryOrder]
    var problems: [String]
}

enum Transfer {
    struct Document: Codable { var version = 1; var plan: RoutePlan }
    static func json(plan: RoutePlan) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Document(plan: plan))
        guard data.count <= 10 * 1024 * 1024 else { throw RouteFailure.invalid("План больше 10 МиБ. Сократите сохранённую историю вариантов перед переносом JSON.") }
        return data
    }
    static func decodePlan(_ data: Data) throws -> RoutePlan {
        guard data.count <= 10 * 1024 * 1024 else { throw RouteFailure.invalid("JSON больше 10 МиБ.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let doc = try decoder.decode(Document.self, from: data)
        guard doc.version == 1 else { throw RouteFailure.invalid("Версия плана не поддерживается.") }
        var plan = doc.plan
        guard plan.vehicles.count <= 5, plan.operationCount <= 50 else { throw RouteFailure.invalid("В плане больше 5 машин или 50 операций.") }
        guard Set(plan.vehicles.map(\.id)).count == plan.vehicles.count,
              Set(plan.orders.map(\.id)).count == plan.orders.count else { throw RouteFailure.invalid("В JSON повторяются идентификаторы машин или заказов.") }
        guard plan.orders.allSatisfy({ (0...100).contains($0.priority) }),
              Set(plan.variants.map(\.id)).count == plan.variants.count,
              plan.vehicles.allSatisfy({ Set($0.breaks.map(\.id)).count == $0.breaks.count }) else { throw RouteFailure.invalid("В JSON неверный приоритет или повторяющиеся идентификаторы.") }
        let vehicleIDs = Set(plan.vehicles.map(\.id)), orderIDs = Set(plan.orders.map(\.id))
        guard plan.selectedVariant == nil || plan.variants.contains(where: { $0.id == plan.selectedVariant }) else { throw RouteFailure.invalid("JSON ссылается на отсутствующий вариант.") }
        for v in plan.variants {
            guard Set(v.routes.map(\.id)).count == v.routes.count,
                  v.unassigned.allSatisfy({ orderIDs.contains($0) }),
                  v.routes.allSatisfy({ vehicleIDs.contains($0.vehicleID) && $0.steps.allSatisfy { $0.orderID == nil || orderIDs.contains($0.orderID!) } }) else { throw RouteFailure.invalid("Нарушены ссылки в сохранённых маршрутах JSON.") }
        }
        // A fresh copy retains the user's inputs. Results must be recalculated for this copy.
        plan.id = UUID(); plan.createdAt = Date(); plan.name += " — копия"
        for i in plan.vehicles.indices { plan.vehicles[i].id = UUID(); for j in plan.vehicles[i].breaks.indices { plan.vehicles[i].breaks[j].id = UUID() } }
        for i in plan.orders.indices { plan.orders[i].id = UUID() }
        plan.variants = []; plan.selectedVariant = nil; plan.manualOrder = []; plan.revision = 0
        return plan
    }
    static func table(_ input: String) throws -> FreightTable {
        guard input.utf8.count <= 5 * 1024 * 1024 else { throw RouteFailure.invalid("Таблица больше 5 МиБ.") }
        let text = input.hasPrefix("\u{FEFF}") ? String(input.dropFirst()) : input
        let candidates: [Character] = ["\t", ";", ","]
        let firstRecord: String = { var quoted = false; var s = ""; for c in text { if c == "\"" { quoted.toggle() }; if (c == "\n" || c == "\r" || c == "\r\n") && !quoted { break }; s.append(c) }; return s }()
        func count(_ delimiter: Character) -> Int { var q = false; var n = 0; for c in firstRecord { if c == "\"" { q.toggle() }; if c == delimiter && !q { n += 1 } }; return n }
        let delimiter = candidates.max(by: { count($0) < count($1) }) ?? ","
        var records: [[String]] = [], record: [String] = [], field = "", quoted = false, closed = false
        let chars = Array(text); var i = 0
        func appendRecord() { record.append(field); if record.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { records.append(record) }; record = []; field = ""; closed = false }
        while i < chars.count {
            let c = chars[i]
            if quoted {
                if c == "\"" { if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false; closed = true } } else { field.append(c) }
            } else if c == "\"" {
                guard field.isEmpty && !closed else { throw RouteFailure.invalid("Кавычки внутри незакавыченного поля, строка \(records.count + 1).") }; quoted = true
            } else if c == delimiter { record.append(field); field = ""; closed = false
            } else if c == "\n" || c == "\r" || c == "\r\n" { appendRecord(); if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
            } else { guard !closed || c.isWhitespace else { throw RouteFailure.invalid("Текст после закрывающей кавычки, строка \(records.count + 1).") }; if !closed { field.append(c) } }
            i += 1
        }
        guard !quoted else { throw RouteFailure.invalid("В таблице не закрыта кавычка.") }
        if !field.isEmpty || !record.isEmpty { appendRecord() }
        guard let headers = records.first, !headers.isEmpty, records.count > 1 else { throw RouteFailure.invalid("Нужна строка заголовков и хотя бы одна строка данных.") }
        guard records.count - 1 <= 500, headers.count <= 100 else { throw RouteFailure.invalid("Допускается до 500 строк и 100 колонок.") }
        let rows = Array(records.dropFirst())
        guard rows.allSatisfy({ $0.count == headers.count }) else { throw RouteFailure.invalid("Число колонок различается. Проверьте разделитель и кавычки.") }
        return FreightTable(headers: headers, rows: rows)
    }
    static func suggestedMapping(_ table: FreightTable) -> [ImportField: Int] {
        func normalize(_ text: String) -> String { text.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "_", with: "") }
        var result: [ImportField: Int] = [:]
        for field in ImportField.allCases { if let index = table.headers.firstIndex(where: { field.aliases.map(normalize).contains(normalize($0)) || normalize(field.rawValue) == normalize($0) }) { result[field] = index } }
        return result
    }
    static func preview(_ table: FreightTable, mapping: [ImportField: Int], existing: [DeliveryOrder]) -> FreightImportPreview {
        var orders: [DeliveryOrder] = [], problems: [String] = []
        for field in [ImportField.number, .delivery] where mapping[field] == nil { problems.append("Сопоставьте колонку «\(field.rawValue)».") }
        guard problems.isEmpty else { return FreightImportPreview(orders: [], problems: problems) }
        let mapped = Array(mapping.values)
        if Set(mapped).count != mapped.count { problems.append("Одна колонка назначена нескольким полям. Исправьте сопоставление.") }
        var numbers = Set(existing.map { $0.number.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        for (index, row) in table.rows.enumerated() {
            func value(_ field: ImportField) -> String { guard let c = mapping[field], row.indices.contains(c) else { return "" }; return row[c].trimmingCharacters(in: .whitespacesAndNewlines) }
            func problem(_ message: String) { problems.append("Строка \(index + 2): \(message)") }
            var order = DeliveryOrder(); order.number = value(.number); order.cargo = value(.cargo)
            if order.number.isEmpty { problem("нет номера заказа.") }
            else if !numbers.insert(order.number.lowercased()).inserted { problem("номер «\(order.number)» уже есть в плане или повторяется в таблице.") }
            order.kg = value(.kg); order.m3 = value(.m3); order.pallets = value(.pallets)
            order.delivery.address = value(.delivery); order.delivery.latitude = value(.deliveryLat); order.delivery.longitude = value(.deliveryLon)
            if !value(.deliveryZone).isEmpty { order.delivery.timeZone = value(.deliveryZone) }
            if order.delivery.address.isEmpty { problem("нет адреса доставки.") }
            order.deliveryWindow.from = value(.deliveryFrom); order.deliveryWindow.until = value(.deliveryUntil); order.deliveryMinutes = value(.deliveryMinutes)
            order.pickup.address = value(.pickup); order.pickup.latitude = value(.pickupLat); order.pickup.longitude = value(.pickupLon)
            if !value(.pickupZone).isEmpty { order.pickup.timeZone = value(.pickupZone) }
            order.pickupWindow.from = value(.pickupFrom); order.pickupWindow.until = value(.pickupUntil); order.pickupMinutes = value(.pickupMinutes)
            if !order.pickup.address.isEmpty { order.mode = .shipment }
            order.skills = value(.skills); order.contact = value(.contact); order.phone = value(.phone); order.revenue = value(.revenue); order.note = value(.note)
            if !value(.priority).isEmpty { if let n = Int(value(.priority)), (0...100).contains(n) { order.priority = n } else { problem("приоритет должен быть целым числом от 0 до 100.") } }
            for (label, text, integer) in [("масса", order.kg, false), ("объём", order.m3, false), ("палеты", order.pallets, true), ("разгрузка", order.deliveryMinutes, false), ("погрузка", order.pickupMinutes, false), ("выручка", order.revenue, false)] where !text.isEmpty {
                guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite, number >= 0, (!integer || number.rounded() == number) else { problem("\(label): нужно неотрицательное число без единиц измерения."); continue }
            }
            for p in [order.delivery, order.pickup] where !p.address.isEmpty {
                if TimeZone(identifier: p.timeZone) == nil { problem("неизвестный часовой пояс «\(p.timeZone)».") }
                if (!p.latitude.isEmpty || !p.longitude.isEmpty) && p.coordinate == nil { problem("неверные координаты для «\(p.address)».") }
            }
            func normalizeDate(_ text: String) -> String? {
                if text.isEmpty { return "" }
                for format in ["yyyy-MM-dd HH:mm", "dd.MM.yyyy HH:mm"] { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = format; f.isLenient = false; if let date = f.date(from: text), f.string(from: date) == text { f.dateFormat = "yyyy-MM-dd HH:mm"; return f.string(from: date) } }
                return nil
            }
            for path in [\DeliveryOrder.deliveryWindow.from, \.deliveryWindow.until, \.pickupWindow.from, \.pickupWindow.until] {
                let input = order[keyPath: path]
                if let output = normalizeDate(input) { order[keyPath: path] = output } else { problem("дата «\(input)» неоднозначна. Нужен формат ГГГГ-ММ-ДД ЧЧ:ММ или ДД.ММ.ГГГГ ЧЧ:ММ.") }
            }
            orders.append(order)
        }
        if existing.reduce(0, { $0 + ($1.mode == .shipment ? 2 : 1) }) + orders.reduce(0, { $0 + ($1.mode == .shipment ? 2 : 1) }) > 50 { problems.append("После импорта будет больше 50 операций. Сократите таблицу; частичный импорт не выполняется.") }
        return FreightImportPreview(orders: orders, problems: problems)
    }
    static func csv(plan: RoutePlan, variant: PlanVariant, includeContacts: Bool = false) throws -> Data {
        var rows = [["План", "Вариант", "Машина", "Номер остановки", "Операция", "Заказ", "Груз", "Адрес", "Прибытие", "Выезд", "Часовой пояс", "Ожидание, мин", "Работа, мин", "Масса после, кг", "Объём после, м³", "Палеты после", "Плечо, км", "Примечание"] + (includeContacts ? ["Контакт", "Телефон"] : [])]
        for route in variant.routes {
            for (index, step) in route.steps.enumerated() {
                let order = plan.orders.first { $0.id == step.orderID }
                var row = [plan.name, variant.name, route.vehicleName, String(index + 1), step.title, order?.number ?? "", order?.cargo ?? "", step.address, RouteTime.local(step.arrival, zone: step.timeZone), RouteTime.local(step.departure, zone: step.timeZone), step.timeZone, String(step.waitingSeconds / 60), String(step.serviceSeconds / 60), String(step.kgAfter), String(step.m3After), String(step.palletsAfter), String(step.metersFromPrevious / 1000), order?.note ?? ""]
                if includeContacts { row += [order?.contact ?? "", order?.phone ?? ""] }; rows.append(row)
            }
        }
        rows.append(["Итого", "Пробег, км", String(variant.totalMeters / 1000), "В дороге, мин", String(variant.totalDrivingSeconds / 60)])
        let economy = Economy.calculate(plan: plan, variant: variant)
        for line in economy.lines { rows.append([line.name, line.amount.map { NSDecimalNumber(decimal: $0).stringValue } ?? "Не рассчитано", plan.currency]) }
        rows.append(["Известные затраты", NSDecimalNumber(decimal: economy.knownTotal).stringValue, plan.currency])
        rows.append(["Выручка", economy.revenue.map { NSDecimalNumber(decimal: $0).stringValue } ?? "Не рассчитано", plan.currency])
        rows.append(["Расчётный остаток", economy.balance.map { NSDecimalNumber(decimal: $0).stringValue } ?? "Не рассчитано", plan.currency])
        rows.append(["Неполные данные", economy.missing.joined(separator: "; ")])
        rows.append(["Проверка", (variant.issues + variant.routes.flatMap(\.issues)).joined(separator: "; ")])
        rows.append(["Данные дорог", variant.provider, "© OpenStreetMap contributors · Valhalla"])
        return Data(("\u{FEFF}" + rows.map { $0.map(csvCell).joined(separator: ";") }.joined(separator: "\r\n")).utf8)
    }
    private static func csvCell(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = "=+-@".contains(trimmed.first ?? " ") || value.first == "\t" || value.first == "\r" ? "'" + value : value
        return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
    @MainActor static func pdf(plan: RoutePlan, variant: PlanVariant, includeContacts: Bool = false) throws -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw RouteFailure.invalid("Не удалось создать PDF.") }
        let pageWidth: CGFloat = 595.28, pageHeight: CGFloat = 841.89, left: CGFloat = 44, width: CGFloat = 507
        var y: CGFloat = 0, page = 0
        let old = NSGraphicsContext.current
        defer { NSGraphicsContext.current = old }
        func begin() {
            if page > 0 { context.endPDFPage() }; var rect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
            context.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: &rect, length: MemoryLayout<CGRect>.size)] as CFDictionary)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false); y = 44; page += 1
            let footer = "Маршруты доставки · \(page) · © OpenStreetMap contributors · Valhalla"
            (footer as NSString).draw(at: NSPoint(x: left, y: 22), withAttributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.darkGray])
        }
        func paragraph(_ text: String, heading: Bool = false) {
            let font = (NSFont(name: heading ? "Arial-BoldMT" : "ArialMT", size: heading ? 13 : 10)) ?? (heading ? NSFont.boldSystemFont(ofSize: 13) : NSFont.systemFont(ofSize: 10))
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            for source in text.components(separatedBy: "\n") {
                var line = ""
                func draw() { if y + 18 > pageHeight - 44 { begin() }; (line as NSString).draw(at: NSPoint(x: left, y: pageHeight - y - 13), withAttributes: attrs); y += 15; line = "" }
                for word in source.components(separatedBy: " ") {
                    let proposal = line.isEmpty ? word : line + " " + word
                    if (proposal as NSString).size(withAttributes: attrs).width > width && !line.isEmpty { draw() }
                    if !line.isEmpty { line += " " }
                    for character in word {
                        if ((line + String(character)) as NSString).size(withAttributes: attrs).width > width && !line.isEmpty { draw() }
                        line.append(character)
                    }
                }
                draw()
            }
            y += 5
        }
        begin(); paragraph("Маршрутный лист — \(plan.name)", heading: true)
        paragraph("Вариант: \(variant.name)\nРасчёт: \(ISO8601DateFormatter().string(from: variant.calculatedAt))\nИсточник дорог: \(variant.provider)")
        if variant.revision != plan.revision { paragraph("ВНИМАНИЕ: данные изменились после расчёта. Этот маршрут устарел.") }
        for route in variant.routes {
            paragraph("Машина: \(route.vehicleName)", heading: true)
            if let vehicle = plan.vehicles.first(where: { $0.id == route.vehicleID }) { paragraph("Номер: \(vehicle.plate) · Водитель: \(vehicle.driver)") }
            paragraph("Пробег: \(FreightFormat.km(route.meters)) · В дороге: \(FreightFormat.duration(route.drivingSeconds))")
            for (index, step) in route.steps.enumerated() {
                paragraph("\(index + 1). \(step.title)", heading: true)
                paragraph("\(step.address)\nПрибытие: \(RouteTime.local(step.arrival, zone: step.timeZone))\nВыезд: \(RouteTime.local(step.departure, zone: step.timeZone))\nОжидание: \(FreightFormat.duration(step.waitingSeconds)); обслуживание: \(FreightFormat.duration(step.serviceSeconds))\nГруз после: \(FreightFormat.number(step.kgAfter)) кг · \(FreightFormat.number(step.m3After, digits: 3)) м³ · \(step.palletsAfter) пал.")
                if let order = plan.orders.first(where: { $0.id == step.orderID }) { paragraph("Заказ \(order.number): \(order.cargo)\n\(order.note)"); if includeContacts { paragraph("Контакт: \(order.contact), \(order.phone)") } }
            }
            for issue in route.issues { paragraph("Проверить: " + issue) }
        }
        paragraph("Итоги", heading: true)
        paragraph("Всего: \(FreightFormat.km(variant.totalMeters)); в дороге: \(FreightFormat.duration(variant.totalDrivingSeconds)); полное время: \(FreightFormat.duration(variant.totalSeconds))")
        let economy = Economy.calculate(plan: plan, variant: variant)
        for line in economy.lines { paragraph("\(line.name): \(FreightFormat.money(line.amount, currency: plan.currency))") }
        paragraph("Известные затраты: \(FreightFormat.money(economy.knownTotal, currency: plan.currency))\nВыручка: \(FreightFormat.money(economy.revenue, currency: plan.currency))\nРасчётный остаток: \(FreightFormat.money(economy.balance, currency: plan.currency))")
        if !economy.missing.isEmpty { paragraph("Неполные данные: " + economy.missing.joined(separator: ", ")) }
        for issue in variant.issues { paragraph("Проверить: " + issue) }
        if !variant.unassigned.isEmpty { paragraph("Не включены заказы: " + variant.unassigned.map { id in plan.orders.first(where: { $0.id == id })?.number ?? id.uuidString }.joined(separator: ", ")) }
        paragraph("Перед выездом проверьте ограничения дорог, пропуска, расписание и условия оплаты. Это план по введённым данным.")
        context.endPDFPage(); context.closePDF(); return data as Data
    }
}

struct FreightImportView: View {
    @ObservedObject var store: RouteStore
    @State private var input = ""
    @State private var table: FreightTable?
    @State private var mapping: [ImportField: Int] = [:]
    @State private var problem = ""
    @State private var confirm = false
    private var preview: FreightImportPreview? { table.map { Transfer.preview($0, mapping: mapping, existing: store.current?.orders ?? []) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Добавить заказы из таблицы").font(.title2.weight(.semibold)); Spacer(); Button("Закрыть") { store.showImport = false } }
            Text("CSV или TSV в UTF-8, либо таблица, скопированная из Excel. До 5 МиБ и 500 строк для просмотра. Данные применяются целиком после проверки.").foregroundStyle(.secondary)
            if let table {
                HStack { Text("\(table.rows.count) строк · \(table.headers.count) колонок"); Spacer(); Button("Другая таблица") { self.table = nil; confirm = false } }
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Сопоставьте колонки").font(.headline)
                            ForEach(ImportField.allCases) { field in
                                Picker(field.rawValue, selection: Binding(get: { mapping[field] ?? -1 }, set: { value in mapping[field] = value < 0 ? nil : value; confirm = false })) {
                                    Text("Не импортировать").tag(-1)
                                    ForEach(table.headers.indices, id: \.self) { i in Text("\(i + 1). \(table.headers[i])").tag(i) }
                                }
                            }
                        }.padding(.trailing, 10)
                    }.frame(minWidth: 320)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Предварительный просмотр").font(.headline)
                            if let preview {
                                ForEach(Array(preview.orders.prefix(8).enumerated()), id: \.offset) { _, order in
                                    VStack(alignment: .leading, spacing: 3) { Text("\(order.number) · \(order.cargo)").fontWeight(.medium); Text(order.delivery.address); Text("\(order.kg) кг · \(order.m3) м³ · \(order.pallets) пал.").font(.caption).foregroundStyle(.secondary) }.padding(.vertical, 5)
                                    Divider()
                                }
                                if preview.orders.count > 8 { Text("И ещё \(preview.orders.count - 8) строк.").foregroundStyle(.secondary) }
                                ForEach(Array(preview.problems.prefix(30).enumerated()), id: \.offset) { _, issue in Text(issue).foregroundStyle(.orange) }
                                if preview.problems.count > 30 { Text("Всего ошибок: \(preview.problems.count)").foregroundStyle(.orange) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 10)
                    }.frame(minWidth: 340)
                }
                Text("Числа вводятся без единиц; окна — ГГГГ-ММ-ДД ЧЧ:ММ или ДД.ММ.ГГГГ ЧЧ:ММ. Импортированные адреса и координаты нужно подтвердить перед расчётом.").font(.caption).foregroundStyle(.secondary)
                Toggle("Я проверил сопоставление и список заказов", isOn: $confirm)
                Button("Добавить \(preview?.orders.count ?? 0) заказов") { apply() }.buttonStyle(.borderedProminent).disabled(!confirm || preview?.problems.isEmpty != true || preview?.orders.isEmpty != false)
            } else {
                TextEditor(text: $input).font(.system(.body, design: .monospaced)).border(Color.secondary.opacity(0.3)).accessibilityLabel("Таблица заказов").frame(minHeight: 280)
                HStack { Button("Открыть CSV / TSV…") { open() }; Button("Проверить таблицу") { parse() }.buttonStyle(.borderedProminent).disabled(input.isEmpty); Spacer() }
            }
            if !problem.isEmpty { Text(problem).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(24).frame(width: 900, height: 690)
    }
    private func open() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let values = try url.resourceValues(forKeys: [.fileSizeKey]); guard (values.fileSize ?? Int.max) <= 5 * 1024 * 1024 else { throw RouteFailure.invalid("Таблица больше 5 МиБ.") }; input = try String(contentsOf: url, encoding: .utf8); parse() } catch { problem = error.localizedDescription }
    }
    private func parse() { do { let result = try Transfer.table(input); table = result; mapping = Transfer.suggestedMapping(result); problem = ""; confirm = false } catch { problem = error.localizedDescription } }
    private func apply() { guard let preview, preview.problems.isEmpty, !preview.orders.isEmpty, confirm else { return }; store.updatePlan { $0.orders += preview.orders }; store.showImport = false }
}
