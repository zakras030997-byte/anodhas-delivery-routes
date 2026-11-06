import Foundation

enum RouteNumbers {
    static func parse(_ text: String, allowZero: Bool = true) -> Decimal? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = "^(?:[0-9]+|[0-9]{1,3}(?:[ \\u00A0\\u202F][0-9]{3})+)(?:[.,][0-9]{1,6})?$"
        guard s.range(of: pattern, options: .regularExpression) != nil else { return nil }
        let plain = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "\u{00a0}", with: "").replacingOccurrences(of: "\u{202f}", with: "").replacingOccurrences(of: ",", with: ".")
        guard let n = Decimal(string: plain, locale: Locale(identifier: "en_US_POSIX")), !n.isNaN, n >= 0, n <= 1_000_000_000, allowZero || n > 0 else { return nil }
        return n
    }
    static func rounded(_ n: Decimal, scale: Int = 2) -> Decimal {
        var n = n, r = Decimal(); NSDecimalRound(&r, &n, scale, .plain); return r
    }
    static func display(_ n: Decimal?) -> String {
        guard let n, !n.isNaN else { return "Не указано" }
        let f = NumberFormatter(); f.locale = Locale(identifier: "ru_RU"); f.numberStyle = .decimal; f.maximumFractionDigits = 2; f.minimumFractionDigits = 2
        return f.string(from: NSDecimalNumber(decimal: n)) ?? "Не рассчитано"
    }
    static func double(_ n: Decimal) -> Double { NSDecimalNumber(decimal: n).doubleValue }
    static func integer(_ text: String, maximum: Int = 1_000_000) -> Int? {
        guard let n = parse(text), n <= Decimal(maximum), rounded(n, scale: 0) == n else { return nil }
        return NSDecimalNumber(decimal: n).intValue
    }
}

enum RouteTime {
    static func parse(_ local: String, zone: String, offset: String = "") throws -> Int {
        let s = local.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "T", with: " ")
        guard s.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil,
              let tz = TimeZone(identifier: zone) else { throw RouteFailure.invalid("Укажите дату ГГГГ-ММ-ДД ЧЧ:ММ и действующий часовой пояс.") }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd HH:mm"; f.isLenient = false
        guard let naive = f.date(from: s), f.string(from: naive) == s else { throw RouteFailure.invalid("Несуществующая дата или время: \(s).") }
        let year = Calendar(identifier: .gregorian).component(.year, from: naive)
        guard (1970...2100).contains(year) else { throw RouteFailure.invalid("Дата должна быть между 1970 и 2100 годами.") }
        // Candidate UTC offsets are sampled around the date, then every candidate is round-tripped.
        // This detects both nonexistent local times and repeated wall-clock times without relying on Mac's zone.
        let offsets = Set((-72...72).map { tz.secondsFromGMT(for: naive.addingTimeInterval(Double($0) * 3600)) })
        f.timeZone = tz
        let candidates = offsets.compactMap { seconds -> Date? in
            let d = naive.addingTimeInterval(Double(-seconds))
            return f.string(from: d) == s && tz.secondsFromGMT(for: d) == seconds ? d : nil
        }.sorted()
        guard !candidates.isEmpty else { throw RouteFailure.invalid("Местное время \(s) не существует в \(zone). Исправьте время.") }
        let selection = offset.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty {
            guard let seconds = offsetSeconds(selection), let d = candidates.first(where: { tz.secondsFromGMT(for: $0) == seconds }) else { throw RouteFailure.invalid("Смещение \(selection) не соответствует времени \(s) в \(zone).") }
            return Int(d.timeIntervalSince1970)
        }
        guard candidates.count == 1 else { throw RouteFailure.invalid("Время \(s) встречается дважды в \(zone). Укажите смещение UTC, например -04:00 или -05:00.") }
        return Int(candidates[0].timeIntervalSince1970)
    }
    static func offsetSeconds(_ text: String) -> Int? {
        let s = text.uppercased().replacingOccurrences(of: "UTC", with: "")
        if s == "Z" || s == "0" { return 0 }
        guard s.range(of: "^[+-][0-9]{2}:[0-9]{2}$", options: .regularExpression) != nil else { return nil }
        let parts = s.dropFirst().split(separator: ":")
        guard let h = Int(parts[0]), let m = Int(parts[1]), h <= 23, m <= 59 else { return nil }
        return (s.first == "-" ? -1 : 1) * (h * 3600 + m * 60)
    }
    static func parseWithFold(_ local: String, zone: String, offset: String = "") throws -> Int {
        // The optional fold choice applies only to repeated local times; it is not a fixed-zone override.
        do { return try parse(local, zone: zone) }
        catch { guard !offset.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw error }; return try parse(local,zone:zone,offset:offset) }
    }
    static func local(_ seconds: Double, zone: String) -> String {
        guard seconds.isFinite, abs(seconds) <= 4_200_000_000, let tz = TimeZone(identifier: zone) else { return "Некорректное время" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.calendar = Calendar(identifier: .gregorian); f.timeZone = tz; f.dateFormat = "yyyy-MM-dd HH:mm XXX"
        return f.string(from: Date(timeIntervalSince1970: seconds)) + " · " + zone
    }
}

enum PlanChecks {
    private static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
    static func skillNames(_ s: String) -> [String] { Array(Set(s.lowercased().components(separatedBy: CharacterSet(charactersIn: ",;\n")).map(trim).filter { !$0.isEmpty })).sorted() }
    private static func checkPlace(_ place: RoutePlace, label: String) throws {
        guard !trim(place.address).isEmpty, place.coordinate != nil, place.confirmed else { throw RouteFailure.invalid("\(label): подтвердите адрес и координаты.") }
        guard TimeZone(identifier: place.timeZone) != nil else { throw RouteFailure.invalid("\(label): проверьте часовой пояс.") }
    }
    private static func amount(_ text: String, name: String, scale: Int = 1, positive: Bool = false, maximum: Decimal = 1_000_000) throws -> Int {
        guard let n = RouteNumbers.parse(text, allowZero: !positive), n <= maximum else { throw RouteFailure.invalid("\(name): укажите допустимое \(positive ? "положительное" : "неотрицательное") число.") }
        let value = n * Decimal(scale)
        guard RouteNumbers.rounded(value, scale: 0) == value, value <= 2_000_000_000 else { throw RouteFailure.invalid("\(name): слишком высокая точность или большое значение.") }
        return NSDecimalNumber(decimal: value).intValue
    }
    static func serviceSeconds(_ minutes: String, label: String) throws -> Int {
        try amount(minutes, name: label, scale: 60, maximum: 10_080)
    }
    static func window(_ slot: TimeSlot, place: RoutePlace, service: Int, label: String) throws -> (Int, Int) {
        let from = try RouteTime.parseWithFold(slot.from, zone: place.timeZone, offset: slot.foldOffset)
        let until = try RouteTime.parseWithFold(slot.until, zone: place.timeZone, offset: slot.foldOffset)
        let latest = until - (slot.rule == .finish ? service : 0)
        guard latest >= from else { throw RouteFailure.invalid("\(label): обслуживание не помещается во временное окно.") }
        return (from, latest)
    }
    static func prepare(_ plan: RoutePlan) throws -> PreparedPlan {
        var errors: [String] = [], warnings: [String] = [], vehicles: [PreparedVehicle] = [], visits: [PreparedVisit] = []
        guard !trim(plan.name).isEmpty, trim(plan.currency).range(of: "^[A-Za-z]{3}$", options: .regularExpression) != nil else { throw RouteFailure.invalid("Укажите название плана и валюту из трёх латинских букв.") }
        guard (1...5).contains(plan.vehicles.count), !plan.orders.isEmpty, plan.operationCount <= 50 else { throw RouteFailure.invalid("Нужны 1–5 машин и заказы, не более 50 операций погрузки/выгрузки.") }
        guard plan.mode != .intercity || plan.vehicles.count == 1 else { throw RouteFailure.invalid("Междугородний рейс версии 1.0 планируется для одной машины.") }
        guard Set(plan.vehicles.map(\.id)).count == plan.vehicles.count, Set(plan.orders.map(\.id)).count == plan.orders.count else { throw RouteFailure.invalid("В плане повторяются внутренние идентификаторы.") }
        let breakIDs = plan.vehicles.flatMap { $0.breaks.map(\.id) }
        guard Set(breakIDs).count == breakIDs.count else { throw RouteFailure.invalid("В плане повторяются идентификаторы перерывов.") }
        let numbers = plan.orders.map { trim($0.number).lowercased() }
        guard numbers.allSatisfy({ !$0.isEmpty }), Set(numbers).count == numbers.count else { throw RouteFailure.invalid("Номера заказов обязательны и должны отличаться.") }
        let palletsUsed = plan.orders.contains { (RouteNumbers.parse($0.pallets) ?? 0) > 0 }
        let allSkills = Array(Set(plan.vehicles.flatMap { skillNames($0.skills) } + plan.orders.flatMap { skillNames($0.skills) })).sorted()
        guard allSkills.count < 10_000 else { throw RouteFailure.invalid("Слишком много свойств машин.") }
        let skillIDs = Dictionary(uniqueKeysWithValues: allSkills.enumerated().map { ($0.element, $0.offset + 1) })
        for (i, v) in plan.vehicles.enumerated() {
            do {
                guard !trim(v.name).isEmpty else { throw RouteFailure.invalid("Укажите название машины.") }
                try checkPlace(v.start, label: "\(v.name), старт")
                if !v.returnToStart && !v.openEnd { try checkPlace(v.end, label: "\(v.name), финиш") }
                guard !(v.returnToStart && v.openEnd) else { throw RouteFailure.invalid("\(v.name): выберите возврат на базу либо открытый финиш.") }
                let start = try RouteTime.parseWithFold(v.shiftStart, zone: v.start.timeZone, offset: v.foldOffset)
                let endZone = (!v.returnToStart && !v.openEnd) ? v.end.timeZone : v.start.timeZone
                let end = try RouteTime.parseWithFold(v.shiftEnd, zone: endZone, offset: v.foldOffset)
                let maximum = plan.mode == .city ? 86_400 : 7 * 86_400
                guard end > start, end - start <= maximum else { throw RouteFailure.invalid("\(v.name): интервал должен быть положительным, не более \(plan.mode == .city ? "24 часов" : "7 суток").") }
                let loading = try serviceSeconds(v.loadingMinutes, label: "\(v.name), загрузка базы")
                guard start + loading <= end else { throw RouteFailure.invalid("\(v.name): загрузка базы не помещается в смену.") }
                let kg = try amount(v.capacityKg, name: "\(v.name), грузоподъёмность", scale: 1000, positive: true)
                let volume = try amount(v.capacityM3, name: "\(v.name), объём", scale: 1000, positive: true)
                let pallet = try amount(v.palletCapacity.isEmpty && !palletsUsed ? "0" : v.palletCapacity, name: "\(v.name), палеты", maximum: 10_000)
                let tare = try amount(v.tareKg, name: "\(v.name), масса пустой машины", scale: 1000, positive: true)
                let gross = try amount(v.maxGrossKg, name: "\(v.name), разрешённая полная масса", scale: 1000, positive: true)
                guard gross > tare else { throw RouteFailure.invalid("\(v.name): полная масса должна быть больше массы пустой машины.") }
                for (text, name, maximum): (String, String, Decimal) in [(v.heightM,"высота",20),(v.widthM,"ширина",20),(v.lengthM,"длина",100)] {
                    _ = try amount(text, name: "\(v.name), \(name)", scale: 1000, positive: true, maximum: maximum)
                }
                _ = try amount(v.axleKg, name: "\(v.name), нагрузка на ось", scale: 1000, positive: true)
                guard let axles = RouteNumbers.integer(v.axleCount, maximum: 20), axles >= 2 else { throw RouteFailure.invalid("\(v.name): укажите целое число осей от 2 до 20.") }
                guard v.breaks.count <= 20, Set(v.breaks.map(\.id)).count == v.breaks.count else { throw RouteFailure.invalid("\(v.name): проверьте число и идентификаторы перерывов.") }
                for pause in v.breaks {
                    let duration = try serviceSeconds(pause.minutes, label: "\(v.name), \(pause.name)")
                    guard duration > 0 else { throw RouteFailure.invalid("\(v.name): длительность перерыва должна быть больше нуля.") }
                    let place = pause.hasPlace ? pause.place : v.start
                    if pause.hasPlace { try checkPlace(place, label: "\(v.name), \(pause.name)") }
                    let w = try window(pause.slot, place: place, service: duration, label: pause.name)
                    guard w.0 >= start, w.1 + duration <= end else { throw RouteFailure.invalid("\(v.name): перерыв должен помещаться в интервал работы.") }
                }
                if v.trailer { warnings.append("\(v.name): отдельные ограничения для прицепа не подтверждены выбранным дорожным профилем.") }
                if !trim(v.permits).isEmpty { warnings.append("\(v.name): пропуска не подтверждены выбранным дорожным профилем.") }
                vehicles.append(PreparedVehicle(solverID: i + 1, vehicle: v, startSeconds: start, endSeconds: end, capacities: [min(kg,gross-tare),volume,pallet], skills: skillNames(v.skills).compactMap { skillIDs[$0] } + [100_001+i]))
            } catch { errors.append(error.localizedDescription) }
        }
        var nextID = 1001
        for order in plan.orders {
            do {
                guard !trim(order.cargo).isEmpty, (0...100).contains(order.priority) else { throw RouteFailure.invalid("Заказ \(order.number): укажите груз и приоритет от 0 до 100.") }
                let load = [try amount(order.kg, name: "\(order.number), масса", scale:1000), try amount(order.m3,name:"\(order.number), объём",scale:1000), try amount(order.pallets.isEmpty ? "0" : order.pallets,name:"\(order.number), палеты",maximum:10_000)]
                guard load.contains(where: { $0 > 0 }) else { throw RouteFailure.invalid("Заказ \(order.number): укажите ненулевую массу, объём или число палет.") }
                let kinds: [VisitKind] = order.mode == .shipment ? [.pickup,.delivery] : [.delivery]
                for kind in kinds {
                    let place = kind == .pickup ? order.pickup : order.delivery
                    let slot = kind == .pickup ? order.pickupWindow : order.deliveryWindow
                    let service = try serviceSeconds(kind == .pickup ? order.pickupMinutes : order.deliveryMinutes,label:"\(order.number), время обслуживания")
                    try checkPlace(place,label:"Заказ \(order.number)")
                    let w = try window(slot,place:place,service:service,label:"Заказ \(order.number)")
                    var visit = PreparedVisit(solverID:nextID,orderID:order.id,vehicleID:nil,kind:kind,title:"\(order.number) · \(order.cargo)",place:place,earliest:w.0,latestStart:w.1,service:service,amounts:load,skills:skillNames(order.skills).compactMap { skillIDs[$0] },priority:order.priority)
                    visit.sourceToken = order.id.uuidString + "#" + kind.rawValue
                    visits.append(visit); nextID += 1
                }
            } catch { errors.append(error.localizedDescription) }
        }
        for v in vehicles {
            for pause in v.vehicle.breaks where pause.hasPlace {
                do {
                    let service = try serviceSeconds(pause.minutes,label:pause.name)
                    let w = try window(pause.slot,place:pause.place,service:service,label:pause.name)
                    var visit = PreparedVisit(solverID:nextID,orderID:nil,vehicleID:v.vehicle.id,kind:.rest,title:pause.name,place:pause.place,earliest:w.0,latestStart:w.1,service:service,amounts:[0,0,0],skills:[100_000+v.solverID],priority:100)
                    visit.sourceToken = pause.id.uuidString + "#rest"
                    visits.append(visit); nextID += 1
                } catch { errors.append(error.localizedDescription) }
            }
        }
        if !errors.isEmpty { throw RouteFailure.invalid(Array(Set(errors)).sorted().joined(separator:"\n")) }
        let origin = vehicles.map(\.startSeconds).min() ?? 0
        guard let end = vehicles.map(\.endSeconds).max(), end-origin <= 7*86_400 else { throw RouteFailure.invalid("Общий горизонт плана превышает 7 суток.") }
        return PreparedPlan(plan:plan,vehicles:vehicles,visits:visits,issues:warnings,originSeconds:origin)
    }

    static func validate(_ variant: PlanVariant, for plan: RoutePlan) -> [String] {
        let prepared: PreparedPlan
        do { prepared = try prepare(plan) } catch { return [error.localizedDescription] }
        var issues = prepared.issues
        if variant.revision != plan.revision { issues.append("Расчёт устарел после изменения плана.") }
        if !variant.verifiedRoads { issues.append("Дорожные участки ещё не подтверждены.") }
        if Set(variant.routes.map(\.vehicleID)).count != variant.routes.count { issues.append("Машина имеет несколько конфликтующих маршрутов.") }
        if Set(variant.unassigned).count != variant.unassigned.count { issues.append("Повторяются нераспределённые заказы.") }
        let orderByID = Dictionary(uniqueKeysWithValues:plan.orders.map { ($0.id,$0) })
        let vehicleByID = Dictionary(uniqueKeysWithValues:prepared.vehicles.map { ($0.vehicle.id,$0) })
        let visitByToken = Dictionary(uniqueKeysWithValues:prepared.visits.map { ($0.sourceToken,$0) })
        var operationCounts: [String:Int] = [:], orderRoutes: [UUID:Set<UUID>] = [:]
        for id in variant.unassigned where orderByID[id] == nil { issues.append("Неизвестный заказ в списке нераспределённых.") }
        for route in variant.routes {
            guard let pv = vehicleByID[route.vehicleID] else { issues.append("Маршрут ссылается на неизвестную машину."); continue }
            let v = pv.vehicle
            guard [route.departure,route.finish,route.meters,route.drivingSeconds].allSatisfy({ $0.isFinite && $0 >= 0 }), route.finish >= route.departure else { issues.append("\(v.name): некорректные числа маршрута."); continue }
            issues += route.issues
            if route.departure < Double(pv.startSeconds)-1 || route.finish > Double(pv.endSeconds)+1 { issues.append("\(v.name): маршрут выходит за интервал работы.") }
            guard route.steps.first?.kind == .start else { issues.append("\(v.name): отсутствует начало маршрута."); continue }
            if route.steps.filter({ $0.kind == .start }).count != 1 || route.steps.dropLast().contains(where: { $0.kind == .end }) { issues.append("\(v.name): нарушен порядок начала и окончания маршрута.") }
            if let first = route.steps.first, first.metersFromPrevious != 0 || first.drivingFromPrevious != 0 { issues.append("\(v.name): до начала маршрута указан неподтверждённый пробег.") }
            if !v.openEnd && route.steps.last?.kind != .end { issues.append("\(v.name): отсутствует конечная точка.") }
            if let first = route.steps.first, abs(first.arrival-route.departure) > 1 { issues.append("\(v.name): начало маршрута не совпадает с расписанием.") }
            if let last = route.steps.last, abs(last.departure-route.finish) > 1 { issues.append("\(v.name): окончание маршрута не совпадает с расписанием.") }
            let delivered = Set(route.steps.filter { $0.kind == .delivery }.compactMap(\.orderID))
            let depotLoads = prepared.visits.filter { $0.kind == .delivery && $0.orderID.map { delivered.contains($0) && orderByID[$0]?.mode == .depot } == true }
            var load = depotLoads.reduce([0,0,0]) { sum, visit in zip(sum,visit.amounts).map(+) }
            var picked: Set<UUID> = [], restCounts: [String:Int] = [:]
            var previous: PlannedStep?, meters=0.0, driving=0.0
            for step in route.steps {
                let fields=[step.arrival,step.waitingSeconds,step.serviceSeconds,step.departure,step.kgAfter,step.m3After,step.metersFromPrevious,step.drivingFromPrevious]
                guard fields.allSatisfy({ $0.isFinite && $0 >= 0 }), step.palletsAfter >= 0 else { issues.append("\(v.name): некорректные значения остановки."); continue }
                if abs(step.arrival+step.waitingSeconds+step.serviceSeconds-step.departure)>1 { issues.append("\(v.name): время остановки не сходится.") }
                if let previous, step.arrival+1 < previous.departure+step.drivingFromPrevious { issues.append("\(v.name): время движения не помещается между остановками.") }
                meters += step.metersFromPrevious; driving += step.drivingFromPrevious
                if let c=step.coordinate, !c.latitude.isFinite || !c.longitude.isFinite || !(-90...90).contains(c.latitude) || !(-180...180).contains(c.longitude) { issues.append("\(v.name): некорректная координата.") }
                if TimeZone(identifier:step.timeZone)==nil { issues.append("\(v.name): неизвестный часовой пояс остановки.") }
                if step.kind == .pickup || step.kind == .delivery {
                    guard let id=step.orderID, let order=orderByID[id] else { issues.append("\(v.name): неизвестный заказ остановки."); previous=step; continue }
                    let token=id.uuidString+"#"+step.kind.rawValue
                    guard let expected=visitByToken[token] else { issues.append("\(order.number): операция не предусмотрена заказом."); previous=step; continue }
                    operationCounts[token,default:0] += 1; orderRoutes[id,default:[]].insert(v.id)
                    if step.kind == .pickup { picked.insert(id); load=zip(load,expected.amounts).map(+) }
                    else {
                        if order.mode == .shipment && !picked.contains(id) { issues.append("\(order.number): выгрузка раньше погрузки.") }
                        load=zip(load,expected.amounts).map(-)
                    }
                    checkStep(step,expected:expected,vehicle:pv,issues:&issues)
                    if variant.unassigned.contains(id) { issues.append("\(order.number): заказ одновременно назначен и не распределён.") }
                } else if step.kind == .rest {
                    restCounts[step.sourceToken,default:0] += 1
                    guard let pause=v.breaks.first(where: { $0.id.uuidString+"#rest" == step.sourceToken }) else { issues.append("\(v.name): неизвестный или неподтверждённый перерыв."); previous=step; continue }
                    do {
                        let seconds=try serviceSeconds(pause.minutes,label:pause.name), place=pause.hasPlace ? pause.place : v.start
                        let w=try window(pause.slot,place:place,service:seconds,label:pause.name)
                        if abs(step.serviceSeconds-Double(seconds))>1 || step.arrival+step.waitingSeconds < Double(w.0)-1 || step.arrival+step.waitingSeconds > Double(w.1)+1 { issues.append("\(v.name): не соблюдены длительность или окно перерыва \(pause.name).") }
                        if pause.hasPlace && !same(step.coordinate,pause.place.coordinate) { issues.append("\(v.name): не подтверждено место перерыва.") }
                    } catch { issues.append(error.localizedDescription) }
                } else if step.kind == .start {
                    if previous != nil { issues.append("\(v.name): повторное начало маршрута.") }
                    let loading=(try? serviceSeconds(v.loadingMinutes,label:v.name)) ?? 0
                    if step.serviceSeconds+1<Double(loading) { issues.append("\(v.name): не учтена загрузка базы.") }
                    if !same(step.coordinate,v.start.coordinate) { issues.append("\(v.name): начало маршрута не совпадает с базой.") }
                } else if step.kind == .end {
                    let end=v.returnToStart ? v.start : v.end
                    if !v.openEnd && !same(step.coordinate,end.coordinate) { issues.append("\(v.name): конец маршрута не совпадает с заданной точкой.") }
                }
                if zip(load,pv.capacities).contains(where: { $0 < 0 || $0 > $1 }) { issues.append("\(v.name): груз выходит за вместимость на участке после \(step.title).") }
                if abs(step.kgAfter-Double(load[0])/1000)>0.001 || abs(step.m3After-Double(load[1])/1000)>0.001 || step.palletsAfter != load[2] { issues.append("\(v.name): остаток груза не совпадает с операциями.") }
                previous=step
            }
            if load.contains(where: { $0 != 0 }) { issues.append("\(v.name): в конце остался недоставленный груз.") }
            if abs(meters-route.meters)>max(1,route.meters*0.000001) || abs(driving-route.drivingSeconds)>1 { issues.append("\(v.name): итог пробега или движения не совпадает с участками.") }
            for pause in v.breaks {
                let token=pause.id.uuidString+"#rest"
                if restCounts[token,default:0]>1 { issues.append("\(v.name): перерыв повторяется.") }
                let place=pause.hasPlace ? pause.place : v.start
                if let earliest=try? RouteTime.parseWithFold(pause.slot.from,zone:place.timeZone,offset:pause.slot.foldOffset), route.finish>Double(earliest)+1 && restCounts[token,default:0]==0 { issues.append("\(v.name): отсутствует обязательный перерыв \(pause.name).") }
            }
        }
        for order in plan.orders {
            let delivery=operationCounts[order.id.uuidString+"#delivery",default:0]
            let pickup=operationCounts[order.id.uuidString+"#pickup",default:0]
            let complete=delivery==1 && (order.mode == .depot ? pickup==0 : pickup==1)
            if !complete && delivery == 0 && pickup == 0 && !variant.unassigned.contains(order.id) { issues.append("Заказ \(order.number) отсутствует и в маршруте, и в списке нераспределённых.") }
            if order.mandatory && !complete { issues.append("Обязательный заказ \(order.number) выполнен не полностью.") }
            if delivery>1 || pickup>1 { issues.append("Заказ \(order.number) повторяется в маршруте.") }
            if orderRoutes[order.id,default:[]].count>1 { issues.append("Заказ \(order.number) передан между машинами.") }
            if !complete && (delivery>0 || pickup>0) { issues.append("Заказ \(order.number): потеряна парная операция.") }
        }
        return Array(Set(issues)).sorted()
    }
    private static func same(_ a: GeoCoordinate?, _ b: GeoCoordinate?) -> Bool {
        guard let a,let b else { return false }; return abs(a.latitude-b.latitude)<0.000001 && abs(a.longitude-b.longitude)<0.000001
    }
    private static func checkStep(_ step: PlannedStep, expected: PreparedVisit, vehicle: PreparedVehicle, issues: inout [String]) {
        let start=step.arrival+step.waitingSeconds
        if start<Double(expected.earliest)-1 || start>Double(expected.latestStart)+1 || abs(step.serviceSeconds-Double(expected.service))>1 { issues.append("\(expected.title): нарушено окно или время обслуживания.") }
        if !Set(expected.skills).isSubset(of:Set(vehicle.skills)) { issues.append("\(expected.title): машина не соответствует требованиям.") }
        if !same(step.coordinate,expected.place.coordinate) { issues.append("\(expected.title): не совпадает подтверждённый адрес остановки.") }
    }
}

struct CostLine { var name: String; var amount: Decimal? }
struct EconomyResult {
    var knownTotal: Decimal
    var revenue: Decimal?
    var balance: Decimal?
    var margin: Decimal?
    var missing: [String]
    var lines: [CostLine]
}
enum Economy {
    static func calculate(plan: RoutePlan, variant: PlanVariant) -> EconomyResult {
        let costs=plan.costs
        var missing:[String]=[], lines:[CostLine]=[]
        func input(_ text:String,_ label:String)->Decimal? {
            guard let v=RouteNumbers.parse(text) else { missing.append(label); return nil }; return v
        }
        func decimal(_ d:Double)->Decimal? {
            guard d.isFinite,d>=0,d<=1_000_000_000 else { return nil }
            return Decimal(string:String(d),locale:Locale(identifier:"en_US_POSIX"))
        }
        func line(_ name:String,_ value:Decimal?) {
            guard let value,!value.isNaN,value>=0,value<=1_000_000_000_000_000 else { lines.append(CostLine(name:name,amount:nil)); if !missing.contains(name) { missing.append(name) }; return }
            lines.append(CostLine(name:name,amount:RouteNumbers.rounded(value)))
        }
        var loaded=0.0,empty=0.0,hours=0.0
        var validMetrics=true
        for route in variant.routes {
            var hasLoad=false
            for step in route.steps {
                guard step.metersFromPrevious.isFinite,step.metersFromPrevious>=0,step.drivingFromPrevious.isFinite,step.drivingFromPrevious>=0,step.waitingSeconds.isFinite,step.waitingSeconds>=0,step.serviceSeconds.isFinite,step.serviceSeconds>=0,step.kgAfter.isFinite,step.kgAfter>=0,step.m3After.isFinite,step.m3After>=0,step.palletsAfter>=0 else { validMetrics=false; continue }
                if hasLoad { loaded += step.metersFromPrevious/1000 } else { empty += step.metersFromPrevious/1000 }
                hours += step.drivingFromPrevious/3600
                if costs.payWaiting { hours += step.waitingSeconds/3600 }
                if step.kind == .rest { if costs.payRest { hours += step.serviceSeconds/3600 } }
                else if costs.payService { hours += step.serviceSeconds/3600 }
                hasLoad=step.kgAfter>0 || step.m3After>0 || step.palletsAfter>0
            }
        }
        if !validMetrics { missing.append("Корректный пробег и время") }
        let price=input(costs.fuelPrice,"Цена топлива")
        let loadedRate=loaded>0 ? input(costs.fuelLoadedL100,"Расход с грузом") : Decimal(0)
        let emptyRate=empty>0 ? input(costs.fuelEmptyL100,"Порожний расход") : Decimal(0)
        if validMetrics,let price,let lr=loadedRate,let er=emptyRate,let l=decimal(loaded),let e=decimal(empty) { line("Топливо",(l*lr+e*er)/100*price) } else { line("Топливо",nil) }
        if validMetrics,let rate=input(costs.vehiclePerKm,"Ставка автомобиля без топлива"),let km=decimal(loaded+empty) { line("Автомобиль за пробег",rate*km) } else { line("Автомобиль за пробег",nil) }
        let used=Decimal(Set(variant.routes.map(\.vehicleID)).count)
        line("Выход машин",input(costs.fixedPerVehicle,"Стоимость выхода машины").map { $0*used })
        let driver=input(costs.driverPay,"Оплата водителя")
        if costs.driverHourly { line("Водители",validMetrics ? driver.flatMap { rate in decimal(hours).map { $0*rate } } : nil) }
        else { line("Водители",driver.map { $0*used }) }
        for (name,value) in [("Платные дороги",costs.tolls),("Парковка",costs.parking),("Ночёвки",costs.overnight),("Прочие расходы",costs.other)] { line(name,input(value,name)) }
        let total=lines.compactMap(\.amount).reduce(Decimal(0),+)
        let revenue: Decimal?
        if costs.revenueByOrders {
            let delivered=Set(variant.routes.flatMap(\.steps).filter { $0.kind == .delivery }.compactMap(\.orderID))
            var totalRevenue=Decimal(0), complete=true
            for order in plan.orders where delivered.contains(order.id) {
                if let n=input(order.revenue,"Выручка заказа \(order.number)") { totalRevenue += n } else { complete=false }
            }
            revenue=complete ? RouteNumbers.rounded(totalRevenue) : nil
        } else { revenue=input(costs.revenue,"Выручка") }
        let expenseMissing=lines.contains { $0.amount==nil }
        let balance=expenseMissing ? nil : revenue.map { RouteNumbers.rounded($0-total) }
        let margin=(revenue ?? 0)>0 ? balance.map { RouteNumbers.rounded($0/revenue!*100) } : nil
        return EconomyResult(knownTotal:total,revenue:revenue,balance:balance,margin:margin,missing:Array(Set(missing)).sorted(),lines:lines)
    }
}
