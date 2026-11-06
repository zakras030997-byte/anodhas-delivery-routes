import SwiftUI
import AppKit

enum FreightSection: String, CaseIterable {
    case orders = "Заказы", vehicles = "Машины", routes = "Маршруты", costs = "Расходы", connection = "Подключение"
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

struct FreightContentView: View {
    @StateObject private var store = RouteStore()
    @State private var section: FreightSection = .orders
    @State private var deletePlan = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !store.error.isEmpty {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(store.error).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Button("Закрыть сообщение") { store.error = "" }.buttonStyle(.plain)
                }.padding(12).background(Color.orange.opacity(0.10))
                Divider()
            }
            HSplitView {
                sidebar.frame(minWidth: 210, idealWidth: 230, maxWidth: 320)
                if let plan = store.current {
                    planBody(plan).frame(minWidth: 820).id(plan.id)
                } else {
                    emptyState.frame(minWidth: 820, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            Divider()
            HStack {
                Text(store.saved.isEmpty ? "Данные хранятся на этом Mac" : store.saved)
                Spacer()
                Text("ANODHAS AI · 1.0.0")
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(minWidth: 1100, minHeight: 750)
        .sheet(isPresented: $store.showImport) { FreightImportView(store: store) }
        .confirmationDialog("Удалить выбранный план?", isPresented: $deletePlan, titleVisibility: .visible) {
            Button("Удалить план", role: .destructive) { store.deleteCurrent() }
            Button("Отменить", role: .cancel) { }
        } message: { Text("План и его сохранённые варианты будут удалены с этого Mac.") }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "truck.box.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Маршруты доставки").font(.title2.weight(.semibold))
                Text("Городская развозка и междугородние рейсы").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Новый план") { store.createPlan(); section = .orders }
                .buttonStyle(.borderedProminent).disabled(store.busy)
            Button("Открыть план…") { store.openPlan() }.disabled(store.busy)
            if store.busy {
                ProgressView().controlSize(.small)
                Text(store.progress).font(.callout).frame(maxWidth: 250, alignment: .leading)
                Button("Отменить расчёт") { store.cancel() }
            }
        }.padding(16)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Планы · \(store.data.plans.count)").font(.headline).padding(.horizontal, 12).padding(.top, 14)
            List(selection: Binding<UUID?>(get: { store.data.selected }, set: { if let id = $0 { store.selectPlan(id) } })) {
                ForEach(store.data.plans) { plan in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(plan.name).fontWeight(.medium).lineLimit(2)
                        Text("\(plan.orders.count) заказов · \(plan.vehicles.count) машин").font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(plan.id)
                }
            }.disabled(store.busy)
            Button("Удалить план…") { deletePlan = true }
                .disabled(store.current == nil || store.busy).padding(12)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "map").font(.system(size: 48)).foregroundStyle(.secondary)
            Text("Спланируйте первый рейс").font(.title2.weight(.semibold))
            Text("Добавьте машину и заказы. Программа поможет проверить загрузку,\nвремя доставки и затраты на поездку.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Создать план") { store.createPlan() }.buttonStyle(.borderedProminent)
        }.padding(32)
    }

    private func planBody(_ plan: RoutePlan) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                TextField("Название плана", text: planString(\.name, routing: false)).font(.title3.weight(.semibold))
                    .textFieldStyle(.plain).accessibilityLabel("Название плана")
                Picker("Режим", selection: Binding(get: { plan.mode }, set: { value in store.updatePlan { $0.mode = value } })) {
                    ForEach(PlanMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 260)
            }
            HStack {
                Picker("Раздел", selection: $section) {
                    ForEach(FreightSection.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                stateLabel(plan)
            }
            switch section {
            case .orders: OrdersPane(store: store)
            case .vehicles: VehiclesPane(store: store)
            case .routes: RoutesPane(store: store)
            case .costs: CostsPane(store: store)
            case .connection: ConnectionPane(store: store)
            }
        }.padding(16)
    }

    private func planString(_ key: WritableKeyPath<RoutePlan, String>, routing: Bool = true) -> Binding<String> {
        Binding(get: { store.current?[keyPath: key] ?? "" }, set: { value in
            store.updatePlan(affectsRoute: routing) { $0[keyPath: key] = value }
        })
    }

    private func stateLabel(_ plan: RoutePlan) -> some View {
        let variant = store.shownVariant
        let state: String = {
            if store.busy { return "Расчёт выполняется" }
            guard let variant else { return "Черновик" }
            if variant.revision != plan.revision { return "Расчёт устарел" }
            if !variant.verifiedRoads || !variant.issues.isEmpty || !variant.unassigned.isEmpty { return "Требует проверки" }
            return "Маршрут проверен"
        }()
        return Text(state).font(.caption.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.secondary.opacity(0.10), in: Capsule()).fixedSize()
    }
}

struct OrdersPane: View {
    @ObservedObject var store: RouteStore
    @State private var selected: UUID?
    @State private var remove = false
    private var orders: [DeliveryOrder] { store.current?.orders ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(orders.count) заказов · \(store.current?.operationCount ?? 0) операций").foregroundStyle(.secondary)
                Spacer()
                Button("Вставить или открыть таблицу…") { store.showImport = true }
                Button("Добавить заказ") { store.addOrder(); selected = store.current?.orders.last?.id }.buttonStyle(.borderedProminent)
            }.disabled(store.busy)
            if orders.isEmpty {
                FreightEmpty(title: "Добавьте заказы", detail: "Введите адреса погрузки и доставки или перенесите таблицу из Excel.")
            } else {
                HSplitView {
                    List(selection: $selected) {
                        ForEach(orders) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.number.isEmpty ? "Без номера" : item.number).fontWeight(.medium)
                                Text(item.cargo.isEmpty ? item.mode.rawValue : item.cargo).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }.padding(.vertical, 4).tag(item.id)
                        }
                    }.frame(minWidth: 170, idealWidth: 200, maxWidth: 260)
                    if let id = selected ?? orders.first?.id {
                        ScrollView { OrderEditor(value: orderBinding(id), store: store).id(id).padding(.horizontal, 12) }
                            .frame(minWidth: 500).disabled(store.busy)
                    }
                }
                HStack {
                    Text("Неизвестные значения оставляйте пустыми. Нулевые расходы и длительность вводите явно.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Удалить заказ…") { remove = true }.disabled(store.busy)
                }
            }
        }.confirmationDialog("Удалить заказ?", isPresented: $remove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { if let id = selected ?? orders.first?.id { store.removeOrder(id); selected = nil } }
            Button("Отменить", role: .cancel) { }
        }
    }
    private func orderBinding(_ id: UUID) -> Binding<DeliveryOrder> {
        Binding(get: { store.current?.orders.first { $0.id == id } ?? DeliveryOrder() }, set: { value in
            guard let previous = store.current?.orders.first(where: { $0.id == id }) else { return }
            var routingComparison = value
            routingComparison.revenue = previous.revenue
            routingComparison.contact = previous.contact
            routingComparison.phone = previous.phone
            routingComparison.note = previous.note
            store.updatePlan(affectsRoute: routingComparison != previous) { p in
                if let i = p.orders.firstIndex(where: { $0.id == id }) { p.orders[i] = value }
            }
        })
    }
}

struct VehiclesPane: View {
    @ObservedObject var store: RouteStore
    @State private var selected: UUID?
    @State private var remove = false
    private var vehicles: [FleetVehicle] { store.current?.vehicles ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Машины и условия рейса").font(.headline)
                Spacer()
                Button("Добавить машину") { store.addVehicle(); selected = store.current?.vehicles.last?.id }
                    .buttonStyle(.borderedProminent).disabled(store.busy || vehicles.count >= 5)
            }
            if vehicles.isEmpty {
                FreightEmpty(title: "Какая машина поедет?", detail: "Добавьте вместимость, габариты, начало смены и точку старта.")
            } else {
                HSplitView {
                    List(selection: $selected) {
                        ForEach(vehicles) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name).fontWeight(.medium)
                                Text(item.plate.isEmpty ? "Параметры машины" : item.plate).font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 4).tag(item.id)
                        }
                    }.frame(minWidth: 170, idealWidth: 200, maxWidth: 260)
                    if let id = selected ?? vehicles.first?.id {
                        ScrollView { VehicleEditor(value: vehicleBinding(id), store: store).id(id).padding(.horizontal, 12) }
                            .frame(minWidth: 500).disabled(store.busy)
                    }
                }
                Button("Удалить машину…") { remove = true }.disabled(store.busy)
            }
        }.confirmationDialog("Удалить машину?", isPresented: $remove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { if let id = selected ?? vehicles.first?.id { store.removeVehicle(id); selected = nil } }
            Button("Отменить", role: .cancel) { }
        }
    }
    private func vehicleBinding(_ id: UUID) -> Binding<FleetVehicle> {
        Binding(get: { store.current?.vehicles.first { $0.id == id } ?? FleetVehicle() }, set: { value in
            store.updatePlan { p in if let i = p.vehicles.firstIndex(where: { $0.id == id }) { p.vehicles[i] = value } }
        })
    }
}

struct RoutesPane: View {
    @ObservedObject var store: RouteStore
    @State private var previewID: UUID?
    @State private var routeID: UUID?
    private var plan: RoutePlan? { store.current }
    private var variant: PlanVariant? { plan?.variants.first { $0.id == previewID } ?? store.shownVariant }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            routeActions
            if let p = plan, let v = variant {
                variantHeader(p, v)
                if !v.issues.isEmpty {
                    Text(v.issues.joined(separator: "\n")).foregroundStyle(.orange).font(.callout).textSelection(.enabled)
                }
                if !v.unassigned.isEmpty { unassigned(v, p) }
                if let route = v.routes.first(where: { $0.id == routeID }) ?? v.routes.first {
                    routeBody(route, v)
                } else {
                    FreightEmpty(title: "Нет выполнимых маршрутов", detail: "Проверьте заказы, машины и причины в результате расчёта.")
                }
            } else {
                FreightEmpty(title: "Маршрут появится после расчёта", detail: "Сначала заполните машину, заказы и проверьте подключение. Расчёт использует грузовой профиль.")
            }
        }.onChange(of: plan?.variants.count) { _ in previewID = plan?.variants.last?.id; routeID = nil }
    }
    private var routeActions: some View {
        HStack(spacing: 10) {
            Picker("Улучшить", selection: Binding(get: { plan?.goal ?? .time }, set: { value in store.updatePlan { $0.goal = value } })) {
                ForEach(SearchGoal.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }.frame(width: 250)
            Button("Предложить маршруты") { store.calculate() }.buttonStyle(.borderedProminent)
            Button("Сохранить мой порядок") { store.calculateManual() }
            Spacer()
            Button("CSV…") { store.export(.summaryCSV) }.disabled(variant == nil)
            Button("Маршрутный лист PDF…") { store.export(.itineraryPDF) }.disabled(variant == nil)
            Button("План JSON…") { store.export(.projectJSON) }
        }.disabled(store.busy)
    }
    private func variantHeader(_ p: RoutePlan, _ v: PlanVariant) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("Вариант", selection: Binding<UUID?>(get: { v.id }, set: { previewID = $0; routeID = nil })) {
                    ForEach(p.variants) { item in
                        Text(item.name + (p.selectedVariant == item.id ? " · выбран" : "")).tag(Optional(item.id))
                    }
                }.frame(maxWidth: 400)
                if p.selectedVariant != v.id {
                    Button("Выбрать этот вариант") { store.acceptVariant(v.id) }.disabled(store.busy || v.revision != p.revision)
                } else { Label("Выбран для выдачи", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                Spacer()
                Text(v.provider).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                metric("Пробег", FreightFormat.km(v.totalMeters))
                metric("В дороге", FreightFormat.duration(v.totalDrivingSeconds))
                metric("Полное время", FreightFormat.duration(v.totalSeconds))
                metric("Машин в плане", String(v.routes.count))
                Spacer()
                if v.revision != p.revision { Label("Входные данные изменились. Пересчитайте план.", systemImage: "clock.arrow.circlepath").foregroundStyle(.orange).font(.callout) }
            }
            Text("Документы и перестановка остановок относятся к выбранному варианту. Чтобы использовать просматриваемый вариант, сначала выберите его.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline).monospacedDigit() }
    }
    private func unassigned(_ v: PlanVariant, _ p: RoutePlan) -> some View {
        DisclosureGroup("Не включено заказов: \(v.unassigned.count)") {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(v.unassigned, id: \.self) { id in
                    Text(p.orders.first(where: { $0.id == id }).map { "\($0.number) · \($0.cargo)" } ?? id.uuidString)
                }
                Text("Проверьте ограничения и список причин. Отсутствие заказа в найденном варианте не доказывает, что выполнить его невозможно.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 5)
        }.foregroundStyle(.orange)
    }
    private func routeBody(_ route: PlannedRoute, _ v: PlanVariant) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Машина", selection: Binding<UUID?>(get: { route.id }, set: { routeID = $0 })) {
                ForEach(v.routes) { item in Text(item.vehicleName).tag(Optional(item.id)) }
            }.frame(maxWidth: 400)
            FreightRouteMap(route: route).frame(minHeight: 180, idealHeight: 220, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("\(FreightFormat.km(route.meters)) · в дороге \(FreightFormat.duration(route.drivingSeconds))").font(.callout)
                Spacer()
                Text("© OpenStreetMap contributors · Valhalla").font(.caption).foregroundStyle(.secondary)
            }
            if !route.issues.isEmpty { Text(route.issues.joined(separator: "\n")).foregroundStyle(.orange).font(.callout) }
            schedule(route)
        }
    }
    private func schedule(_ route: PlannedRoute) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(route.steps.enumerated()), id: \.element.id) { index, step in
                    HStack(alignment: .top, spacing: 12) {
                        Text(String(index + 1)).font(.callout.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(step.title).fontWeight(.medium)
                            Text(step.address).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("\(RouteTime.local(step.arrival, zone: step.timeZone)) → \(RouteTime.local(step.departure, zone: step.timeZone))")
                                .font(.caption).monospacedDigit()
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("Груз: \(FreightFormat.number(step.kgAfter)) кг · \(FreightFormat.number(step.m3After, digits: 3)) м³ · \(step.palletsAfter) пал.")
                            Text("Ожидание \(FreightFormat.duration(step.waitingSeconds)) · работа \(FreightFormat.duration(step.serviceSeconds))")
                                .foregroundStyle(.secondary)
                        }.font(.caption)
                        if step.kind == .pickup || step.kind == .delivery {
                            VStack(spacing: 4) {
                                Button { store.moveVisit(vehicleID: route.vehicleID, stepID: step.id, delta: -1) } label: { Image(systemName: "arrow.up") }
                                    .help("Поднять остановку").accessibilityLabel("Поднять остановку \(step.title)")
                                Button { store.moveVisit(vehicleID: route.vehicleID, stepID: step.id, delta: 1) } label: { Image(systemName: "arrow.down") }
                                    .help("Опустить остановку").accessibilityLabel("Опустить остановку \(step.title)")
                            }.disabled(store.busy || plan?.selectedVariant != variant?.id)
                        }
                    }.padding(.vertical, 10)
                    Divider()
                }
            }.padding(.horizontal, 4)
        }.frame(minHeight: 170)
    }
}

struct CostsPane: View {
    @ObservedObject var store: RouteStore
    private var plan: RoutePlan? { store.current }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Плановые затраты и выручка").font(.headline)
                HStack {
                    FreightField("Валюта", text: Binding(get: { plan?.currency ?? "RUB" }, set: { value in store.updatePlan(affectsRoute: false) { $0.currency = value.uppercased() } }), placeholder: "RUB")
                    Spacer()
                }.frame(maxWidth: 260)
                if let p = plan {
                    CostsEditor(value: Binding(get: { store.current?.costs ?? TripCosts() }, set: { value in store.updatePlan(affectsRoute: false) { $0.costs = value } }))
                    if let variant = store.shownVariant {
                        costResult(p, variant)
                    } else { Text("Итог появится, когда будет рассчитан маршрут. Расходы можно заполнить заранее.").foregroundStyle(.secondary) }
                }
            }.padding(.trailing, 8)
        }.disabled(store.busy)
    }
    private func costResult(_ p: RoutePlan, _ v: PlanVariant) -> some View {
        let result = Economy.calculate(plan: p, variant: v)
        return GroupBox("Расчёт по варианту «\(v.name)»") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(result.lines.enumerated()), id: \.offset) { _, line in
                    HStack { Text(line.name); Spacer(); Text(FreightFormat.money(line.amount, currency: p.currency)).monospacedDigit() }
                }
                Divider()
                HStack { Text(result.missing.isEmpty ? "Затраты" : "Известные затраты").fontWeight(.semibold); Spacer(); Text(FreightFormat.money(result.knownTotal, currency: p.currency)).fontWeight(.semibold) }
                HStack { Text("Выручка"); Spacer(); Text(FreightFormat.money(result.revenue, currency: p.currency)) }
                HStack { Text("Расчётный остаток"); Spacer(); Text(FreightFormat.money(result.balance, currency: p.currency)).font(.headline) }
                if let margin = result.margin { Text("Доля остатка в выручке: \(FreightFormat.money(margin, currency: "%"))").foregroundStyle(.secondary) }
                if !result.missing.isEmpty {
                    Text("Затраты заполнены не полностью: " + result.missing.joined(separator: ", ")).foregroundStyle(.orange)
                }
                if v.revision != p.revision { Text("Маршрут устарел. Перед выдачей пересчитайте его по новым данным.").foregroundStyle(.orange) }
                Text("Это план по введённым расходам. Сверяйте тарифы и условия оплаты перед поездкой.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}

struct ConnectionPane: View {
    @ObservedObject var store: RouteStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Дорожный расчёт").font(.headline)
                Picker("Подключение", selection: setting(\.provider)) {
                    ForEach(RoadProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(maxWidth: 500)
                if store.data.settings.provider == .community {
                    GroupBox("Открытый сервис Valhalla / FOSSGIS") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Без ключа, не чаще одного запроса в секунду. Матрицы расстояний — до 150 км. Оптимизация дальних планов — до 8 точек; заданный порядок можно считать по отдельным участкам.")
                            Text("Нет живых пробок. Сервис сообщества не гарантирует доступность и полноту грузовых ограничений; тарифы платных дорог не подтверждаются. Для больших дальних планов подключите свой Valhalla.").foregroundStyle(.secondary)
                            Toggle("Понимаю ограничения открытого сервиса", isOn: setting(\.publicNoticeAccepted))
                            Link("Условия использования сервиса", destination: URL(string: "https://openstreetmap.de/nutzen/dienste-osm-de/")!)
                        }.padding(8)
                    }
                } else {
                    FreightField("Адрес сервера", text: setting(\.ownEndpoint), placeholder: "https://routing.example.com")
                    Text("Укажите совместимый Valhalla API с грузовым профилем и матрицами. Программа не устанавливает сервер и не меняет сеть Mac.").font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("Параметры расчёта") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("Время локального поиска: \(store.data.settings.timeoutSeconds) с", value: setting(\.timeoutSeconds), in: 1...60)
                        Toggle("Избегать платных дорог", isOn: setting(\.avoidTolls))
                        Toggle("Избегать грунтовых дорог", isOn: setting(\.avoidUnpaved))
                    }.padding(8)
                }
                Text("В сервис отправляются координаты, параметры машины и время поездки. Контакты, цены и примечания к заказам остаются на Mac.").font(.callout).foregroundStyle(.secondary)
                Text("Перед распространением приложения с публичным сервисом нужно согласовать нагрузку с его оператором. Данные карты: © OpenStreetMap contributors.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 20)
            }.frame(maxWidth: 760, alignment: .leading)
        }.disabled(store.busy)
    }
    private func setting<T>(_ key: WritableKeyPath<ProviderSettings, T>) -> Binding<T> {
        Binding(get: { store.data.settings[keyPath: key] }, set: { value in store.updateSettings { $0[keyPath: key] = value } })
    }
}

struct FreightEmpty: View {
    var title: String
    var detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 480)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

final class FreightAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main struct FreightPlannerApp: App {
    @NSApplicationDelegateAdaptor(FreightAppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Маршруты доставки") { FreightContentView().tint(.orange) }
            .defaultSize(width: 1320, height: 900)
    }
}
