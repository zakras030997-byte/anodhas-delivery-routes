import Foundation

/// VROOM consumes only supplied road matrices. This adapter never queries a router.
struct SolverAdapter {
    static func optimize(prepared original: PreparedPlan, matrices: [String: MatrixSnapshot], profileKeys: [UUID: String], nodes: [GeoCoordinate], executable: URL, timeoutSeconds: Int = 15) async throws -> PlanVariant {
        try Task.checkCancellation()
        // Customer windows may open before the first driver's shift. Keep their
        // actual bounds, including already impossible deadlines, without UInt underflow.
        var p = original
        p.originSeconds = min(p.originSeconds, p.visits.map(\.earliest).min() ?? p.originSeconds)
        let input = try payload(prepared: p, matrices: matrices, profileKeys: profileKeys, nodes: nodes)
        let data = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let result = try await SolverSubprocess.run(executable: executable, input: data, timeoutSeconds: min(60, max(1, timeoutSeconds)))
        try Task.checkCancellation()
        return try decode(result, prepared: p, matrices: matrices, nodes: nodes)
    }

    private static func relative(_ seconds: Int, _ p: PreparedPlan) throws -> Int {
        let (n, overflow) = seconds.subtractingReportingOverflow(p.originSeconds)
        guard !overflow, n >= 0, n <= Int(UInt32.max) else { throw RouteFailure.invalid("Временной интервал выходит за границы расчёта.") }
        return n
    }
    private static func index(_ place: RoutePlace, nodes: [GeoCoordinate]) throws -> Int {
        guard let coordinate = place.coordinate, let index = nodes.firstIndex(of: coordinate) else { throw RouteFailure.invalid("В дорожной матрице отсутствует точка «\(place.address)».") }
        return index
    }
    private static func roundedMatrix(_ rows: [[Double?]], count: Int) throws -> [[Int]] {
        guard rows.count == count else { throw RouteFailure.invalid("Размер дорожной матрицы не совпадает с числом точек.") }
        return try rows.map { row in
            guard row.count == count else { throw RouteFailure.invalid("Дорожная матрица имеет неполную строку.") }
            return try row.map { value in
                guard let value, value.isFinite, value >= 0, value <= Double(UInt32.max) else { throw RouteFailure.invalid("Между точками нет подтверждённого дорожного пути или матрица некорректна.") }
                return Int(ceil(value))
            }
        }
    }
    private static func visitFields(_ v: PreparedVisit, _ p: PreparedPlan, _ nodes: [GeoCoordinate]) throws -> [String: Any] {
        guard !v.sourceToken.isEmpty, v.solverID >= 1001, v.service >= 0, v.latestStart >= v.earliest else { throw RouteFailure.invalid("Некорректная операция в задании расчёта.") }
        return ["id": v.solverID, "location_index": try index(v.place, nodes: nodes), "service": v.service,
                "time_windows": [[try relative(v.earliest, p), try relative(v.latestStart, p)]]]
    }
    private static func breakID(vehicle: PreparedVehicle, index: Int) -> Int { 1_000_000 + vehicle.solverID * 100 + index }

    private static func payload(prepared p: PreparedPlan, matrices: [String: MatrixSnapshot], profileKeys: [UUID: String], nodes: [GeoCoordinate]) throws -> [String: Any] {
        guard !p.vehicles.isEmpty, !nodes.isEmpty, nodes.count <= 100,
              Set(p.visits.map(\.solverID)).count == p.visits.count,
              Set(p.visits.map(\.sourceToken)).count == p.visits.count,
              Set(p.vehicles.map(\.solverID)).count == p.vehicles.count else { throw RouteFailure.invalid("Повторяются идентификаторы или отсутствуют точки расчёта.") }
        var matrixJSON: [String: Any] = [:]
        var vehicles: [[String: Any]] = []
        for pv in p.vehicles {
            guard let key = profileKeys[pv.vehicle.id], let matrix = matrices[key], matrix.nodes == nodes, matrix.profileKey == key else { throw RouteFailure.invalid("Для машины «\(pv.vehicle.name)» нет подходящей дорожной матрицы.") }
            if matrixJSON[key] == nil {
                let durations = try roundedMatrix(matrix.durations, count: nodes.count)
                let distances = try roundedMatrix(matrix.distances, count: nodes.count)
                var values: [String: Any] = ["durations": durations, "distances": distances]
                if p.plan.goal == .distance { values["costs"] = distances }
                matrixJSON[key] = values
            }
            let loading = try PlanChecks.serviceSeconds(pv.vehicle.loadingMinutes, label: "Загрузка базы")
            var vehicle: [String: Any] = ["id": pv.solverID, "profile": key, "start_index": try index(pv.vehicle.start, nodes: nodes),
                                          "capacity": pv.capacities, "skills": pv.skills,
                                          "time_window": [try relative(pv.startSeconds + loading, p), try relative(pv.endSeconds, p)]]
            if !pv.vehicle.openEnd { vehicle["end_index"] = try index(pv.vehicle.returnToStart ? pv.vehicle.start : pv.vehicle.end, nodes: nodes) }
            var breaks: [[String: Any]] = []
            for (i, pause) in pv.vehicle.breaks.enumerated() where !pause.hasPlace {
                let service = try PlanChecks.serviceSeconds(pause.minutes, label: pause.name)
                let window = try PlanChecks.window(pause.slot, place: pv.vehicle.start, service: service, label: pause.name)
                breaks.append(["id": breakID(vehicle: pv, index: i), "service": service,
                               "time_windows": [[try relative(window.0, p), try relative(window.1, p)]]])
            }
            if !breaks.isEmpty { vehicle["breaks"] = breaks }
            vehicles.append(vehicle)
        }
        var jobs: [[String: Any]] = [], shipments: [[String: Any]] = []
        let orderByID = Dictionary(uniqueKeysWithValues: p.plan.orders.map { ($0.id, $0) })
        for visit in p.visits {
            if let id = visit.orderID, let order = orderByID[id], order.mode == .shipment {
                guard visit.kind == .pickup else { continue }
                guard let delivery = p.visits.first(where: { $0.orderID == id && $0.kind == .delivery }), delivery.amounts == visit.amounts, delivery.skills == visit.skills else { throw RouteFailure.invalid("Заказ «\(visit.title)» не имеет согласованной пары погрузки и доставки.") }
                shipments.append(["amount": visit.amounts, "skills": visit.skills, "priority": visit.priority,
                                  "pickup": try visitFields(visit, p, nodes), "delivery": try visitFields(delivery, p, nodes)])
            } else {
                guard visit.kind == .delivery || visit.kind == .rest else { throw RouteFailure.invalid("Неизвестный тип отдельной операции.") }
                var job = try visitFields(visit, p, nodes)
                job["skills"] = visit.skills; job["priority"] = visit.priority
                if visit.kind == .delivery { job["delivery"] = visit.amounts }
                jobs.append(job)
            }
        }
        var root: [String: Any] = ["vehicles": vehicles, "matrices": matrixJSON]
        if !jobs.isEmpty { root["jobs"] = jobs }
        if !shipments.isEmpty { root["shipments"] = shipments }
        return root
    }

    private static func number(_ value: Any?, field: String) throws -> Double {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, n.doubleValue >= 0 else { throw RouteFailure.invalid("Расчётный модуль вернул некорректное поле \(field).") }
        return n.doubleValue
    }
    private static func integer(_ value: Any?, field: String) throws -> Int {
        let n = try number(value, field: field)
        guard n <= Double(Int32.max), n.rounded(.down) == n else { throw RouteFailure.invalid("Расчётный модуль вернул некорректный идентификатор или счётчик \(field).") }
        return Int(n)
    }
    private static func decode(_ data: Data, prepared p: PreparedPlan, matrices: [String: MatrixSnapshot], nodes: [GeoCoordinate]) throws -> PlanVariant {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RouteFailure.invalid("Расчётный модуль не вернул структурированный результат.") }
        guard try integer(root["code"], field: "code") == 0 else { throw RouteFailure.invalid("Расчёт не выполнен: \((root["error"] as? String ?? "неизвестная ошибка").prefix(500))") }
        guard let rawRoutes = root["routes"] as? [[String: Any]], let rawUnassigned = root["unassigned"] as? [[String: Any]] else { throw RouteFailure.invalid("Неполный результат расчётного модуля.") }
        let visits = Dictionary(uniqueKeysWithValues: p.visits.map { ($0.solverID, $0) })
        let vehicles = Dictionary(uniqueKeysWithValues: p.vehicles.map { ($0.solverID, $0) })
        var variant = PlanVariant(name: "Подобранный маршрут", revision: p.plan.revision,
                                  provider: Array(Set(matrices.values.map(\.provider))).sorted().joined(separator: ", "), goal: p.plan.goal, routes: [])
        variant.matrices = matrices; variant.matrixSnapshot = matrices.sorted(by: { $0.key < $1.key }).first?.value
        variant.issues = p.issues
        var unassigned: Set<UUID> = [], assignedVisits: Set<Int> = [], usedVehicles: Set<Int> = []
        for item in rawUnassigned {
            let id = try integer(item["id"], field: "unassigned.id")
            guard let visit = visits[id] else { throw RouteFailure.invalid("Неизвестная нераспределённая операция.") }
            if let orderID = visit.orderID { unassigned.insert(orderID) }
            else { variant.issues.append("Не удалось назначить обязательный перерыв «\(visit.title)».") }
        }
        variant.unassigned = p.plan.orders.map(\.id).filter { unassigned.contains($0) }
        for raw in rawRoutes {
            let vehicleID = try integer(raw["vehicle"], field: "vehicle")
            guard let pv = vehicles[vehicleID], usedVehicles.insert(vehicleID).inserted,
                  let rawSteps = raw["steps"] as? [[String: Any]], rawSteps.count >= 2 else { throw RouteFailure.invalid("Некорректная машина или остановки маршрута.") }
            let v = pv.vehicle
            let loading = try PlanChecks.serviceSeconds(v.loadingMinutes, label: "Загрузка базы")
            var breaks: [Int: DriverBreak] = [:]
            for (i, pause) in v.breaks.enumerated() where !pause.hasPlace { breaks[breakID(vehicle: pv, index: i)] = pause }
            var steps: [PlannedStep] = [], previousDuration = 0.0, previousDistance = 0.0
            for (stepIndex, item) in rawSteps.enumerated() {
                guard let type = item["type"] as? String else { throw RouteFailure.invalid("Нет типа остановки в результате.") }
                let relativeArrival = try number(item["arrival"], field: "arrival")
                guard relativeArrival <= Double(UInt32.max) else { throw RouteFailure.invalid("Некорректное время остановки.") }
                var arrival = Double(p.originSeconds) + relativeArrival
                let waiting = try number(item["waiting_time"], field: "waiting_time")
                var service = try number(item["service"], field: "service")
                let duration = try number(item["duration"], field: "duration")
                let distance = try number(item["distance"], field: "distance")
                guard duration >= previousDuration, distance >= previousDistance,
                      let rawLoad = item["load"] as? [Any], rawLoad.count == 3 else { throw RouteFailure.invalid("Некорректный остаток груза или накопленный пробег.") }
                let load = try rawLoad.map { try integer($0, field: "load") }
                var kind: VisitKind, token: String, title: String, place: RoutePlace, coordinate: GeoCoordinate?, orderID: UUID?
                switch type {
                case "start":
                    guard stepIndex == 0 else { throw RouteFailure.invalid("Повторное начало маршрута.") }
                    kind = .start; token = v.id.uuidString + "#start"; title = v.name + " · загрузка базы"; place = v.start; coordinate = place.coordinate
                    arrival -= Double(loading); service += Double(loading)
                case "end":
                    guard stepIndex == rawSteps.count - 1 else { throw RouteFailure.invalid("Финиш до окончания маршрута.") }
                    kind = .end; token = v.id.uuidString + "#end"; title = "Финиш"
                    place = v.openEnd ? v.start : (v.returnToStart ? v.start : v.end)
                    if v.openEnd, let last = steps.last(where: { $0.coordinate != nil }) {
                        place.address = last.address; place.timeZone = last.timeZone; coordinate = last.coordinate
                    } else { coordinate = place.coordinate }
                case "break":
                    let id = try integer(item["id"], field: "break.id")
                    guard let pause = breaks.removeValue(forKey: id) else { throw RouteFailure.invalid("Неизвестный или повторный перерыв.") }
                    kind = .rest; token = pause.id.uuidString + "#rest"; title = pause.name; place = v.start; place.address = "Место остановки не задано"; coordinate = nil
                case "job", "pickup", "delivery":
                    let id = try integer(item["id"], field: "step.id")
                    guard let visit = visits[id], assignedVisits.insert(id).inserted,
                          visit.vehicleID == nil || visit.vehicleID == v.id,
                          (type != "pickup" || visit.kind == .pickup), (type != "delivery" || visit.kind == .delivery) else { throw RouteFailure.invalid("Неизвестная, повторная или чужая операция маршрута.") }
                    kind = visit.kind; token = visit.sourceToken; title = visit.title; place = visit.place; coordinate = place.coordinate; orderID = visit.orderID
                    let actualIndex = try integer(item["location_index"], field: "location_index")
                    guard actualIndex < nodes.count, nodes[actualIndex] == coordinate else { throw RouteFailure.invalid("Операция рассчитана для другой точки.") }
                default: throw RouteFailure.invalid("Неизвестная остановка «\(type)».")
                }
                if let violations = item["violations"] as? [Any], !violations.isEmpty { variant.issues.append("\(v.name): модуль сообщил о нарушении ограничения на остановке «\(title)».") }
                let step = PlannedStep(sourceToken: token, orderID: orderID, kind: kind, title: title, address: place.address, coordinate: coordinate, timeZone: place.timeZone,
                                       arrival: arrival, waitingSeconds: waiting, serviceSeconds: service, departure: arrival + waiting + service,
                                       kgAfter: Double(load[0])/1000, m3After: Double(load[1])/1000, palletsAfter: load[2],
                                       metersFromPrevious: distance-previousDistance, drivingFromPrevious: duration-previousDuration)
                steps.append(step); previousDuration = duration; previousDistance = distance
            }
            guard steps.first?.kind == .start, steps.last?.kind == .end else { throw RouteFailure.invalid("Отсутствует начало или окончание маршрута.") }
            var route = PlannedRoute(vehicleID: v.id, vehicleName: v.name, departure: steps[0].arrival, finish: steps[steps.count-1].departure,
                                     steps: steps, meters: try number(raw["distance"], field: "route.distance"), drivingSeconds: try number(raw["duration"], field: "route.duration"))
            if let violations = raw["violations"] as? [Any], !violations.isEmpty { route.issues.append("\(v.name): расчётный модуль сообщил о нарушениях ограничений.") }
            guard abs(route.meters-previousDistance) <= 1, abs(route.drivingSeconds-previousDuration) <= 1 else { throw RouteFailure.invalid("Итоги маршрута не совпадают с остановками.") }
            variant.routes.append(route)
        }
        variant.issues = Array(Set(variant.issues)).sorted()
        return variant
    }
}

/// Only the specific owned process is terminated on cancellation or deadline.
private final class SolverSubprocess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false
    private var excessiveOutput = false

    static func run(executable: URL, input: Data, timeoutSeconds: Int) async throws -> Data {
        let runner = SolverSubprocess()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { continuation.resume(returning: try runner.execute(executable: executable, input: input, timeoutSeconds: timeoutSeconds)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { runner.stop(cancel: true) })
    }
    private func stop(cancel: Bool = false, timeout: Bool = false, output: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        cancelled = cancelled || cancel; timedOut = timedOut || timeout; excessiveOutput = excessiveOutput || output
        if let process, process.isRunning { process.terminate() }
    }
    private func execute(executable: URL, input: Data, timeoutSeconds: Int) throws -> Data {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path), input.count <= 8_000_000 else { throw RouteFailure.invalid("Расчётный модуль отсутствует или входные данные слишком велики.") }
        let task = Process(), stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.executableURL = executable; task.arguments = ["-l", String(timeoutSeconds), "-t", "2", "-x", "3"]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        // No shell, inherited app secrets, router settings, or child processes are needed.
        task.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = task
        do { try task.run(); lock.unlock() }
        catch { process = nil; lock.unlock(); throw RouteFailure.invalid("Не удалось запустить расчётный модуль: \(error.localizedDescription)") }
        let deadline = DispatchWorkItem { [weak self] in self?.stop(timeout: true) }
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(timeoutSeconds + 15), execute: deadline)
        let output = SolverOutputBuffer(), errors = SolverOutputBuffer(), group = DispatchGroup()
        for (handle, buffer, limit) in [(stdout.fileHandleForReading, output, 16_000_000), (stderr.fileHandleForReading, errors, 64_000)] {
            group.enter()
            DispatchQueue.global().async { [self] in
                defer { try? handle.close(); group.leave() }
                do {
                    while let chunk = try handle.read(upToCount: 64_000), !chunk.isEmpty {
                        if !buffer.append(chunk, limit: limit) { stop(output: true) }
                    }
                } catch { buffer.setReadError() }
            }
        }
        var writeError: Error?
        do { try stdin.fileHandleForWriting.write(contentsOf: input) } catch { writeError = error }
        try? stdin.fileHandleForWriting.close()
        task.waitUntilExit(); group.wait(); deadline.cancel()
        lock.lock()
        process = nil
        let wasCancelled = cancelled, wasTimedOut = timedOut, wasExcessive = excessiveOutput
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if wasTimedOut { throw RouteFailure.invalid("Расчёт превысил допустимое время и остановлен. Уменьшите число операций или пересмотрите ограничения.") }
        if wasExcessive { throw RouteFailure.invalid("Расчётный модуль вернул слишком большой ответ.") }
        guard !output.readError, !errors.readError, writeError == nil else { throw RouteFailure.invalid("Не удалось обменяться данными с расчётным модулем.") }
        guard task.terminationReason == .exit, task.terminationStatus == 0 else {
            let message = String(data: errors.data, encoding: .utf8) ?? ""
            // VROOM writes its structured error on stdout even for a nonzero exit.
            if let root = try? JSONSerialization.jsonObject(with: output.data) as? [String: Any], let explanation = root["error"] as? String { throw RouteFailure.invalid("Расчёт не выполнен: \(explanation.prefix(500))") }
            throw RouteFailure.invalid("Расчётный модуль завершился с ошибкой \(task.terminationStatus). \(message.prefix(300))")
        }
        return output.data
    }
}

private final class SolverOutputBuffer: @unchecked Sendable {
    // Each buffer is written by exactly one reader, consumed after DispatchGroup.wait().
    private(set) var data = Data()
    private(set) var readError = false
    func append(_ chunk: Data, limit: Int) -> Bool {
        guard data.count + chunk.count <= limit else { return false }
        data.append(chunk); return true
    }
    func setReadError() { readError = true }
}
