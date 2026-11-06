import SwiftUI

struct FreightField: View {
    var title: String
    @Binding var text: String
    var placeholder = ""
    init(_ title: String, text: Binding<String>, placeholder: String = "") {
        self.title = title; self._text = text; self.placeholder = placeholder
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).accessibilityLabel(title)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PlaceEditor: View {
    var title: String
    @Binding var value: RoutePlace
    @ObservedObject var store: RouteStore
    @State private var candidates: [PlaceCandidate] = []
    @State private var searching = false
    @State private var searchProblem = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            HStack(alignment: .bottom, spacing: 10) {
                FreightField("Адрес и въезд", text: placeText(\.address), placeholder: "Город, улица, дом, ворота")
                Button(searching ? "Ищу…" : "Найти адрес") { search() }.disabled(searching || value.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !searchProblem.isEmpty { Text(searchProblem).font(.caption).foregroundStyle(.orange) }
            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Выберите подходящее место").font(.caption).foregroundStyle(.secondary)
                    ForEach(candidates, id: \.id) { item in
                        Button { apply(item) } label: {
                            HStack(alignment: .top) { Image(systemName: "mappin"); Text(item.title).multilineTextAlignment(.leading); Spacer() }
                        }.buttonStyle(.bordered)
                    }
                    Button("Закрыть варианты") { candidates = [] }.buttonStyle(.plain).font(.caption)
                }.padding(8).background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 12) {
                FreightField("Широта", text: placeText(\.latitude), placeholder: "59.9386")
                FreightField("Долгота", text: placeText(\.longitude), placeholder: "30.3141")
                FreightField("Часовой пояс", text: $value.timeZone, placeholder: "Europe/Moscow")
            }
            HStack {
                Toggle("Адрес и координаты проверены", isOn: $value.confirmed).disabled(value.coordinate == nil)
                Spacer()
                if value.confirmed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
            }
            Text("Можно ввести координаты въезда вручную. Часовой пояс проверьте отдельно.").font(.caption).foregroundStyle(.secondary)
        }.onChange(of: value.address) { _ in candidates = []; searchProblem = "" }
    }
    private func placeText(_ key: WritableKeyPath<RoutePlace, String>) -> Binding<String> {
        Binding(get: { value[keyPath: key] }, set: { text in
            value[keyPath: key] = text; value.confirmed = false; value.source = "Ручной ввод"
        })
    }
    private func search() {
        searching = true; searchProblem = ""; candidates = []
        let query = value.address
        Task { @MainActor in
            defer { searching = false }
            do {
                let found = try await store.geocode(query: query)
                guard value.address == query else { return }
                candidates = found
                if found.isEmpty { searchProblem = "Адрес не найден. Уточните город или укажите координаты въезда." }
            } catch { searchProblem = "Поиск недоступен. Можно ввести координаты вручную. " + error.localizedDescription }
        }
    }
    private func apply(_ item: PlaceCandidate) {
        value.originalAddress = value.address
        value.address = item.title
        value.latitude = String(item.coordinate.latitude)
        value.longitude = String(item.coordinate.longitude)
        value.confirmed = true
        value.source = "Apple MapKit · выбран пользователем"
        candidates = []; searchProblem = ""
    }
}

struct TimeSlotEditor: View {
    @Binding var value: TimeSlot
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FreightField("Принимают с", text: $value.from, placeholder: "2026-11-10 09:00")
                FreightField("Принимают до", text: $value.until, placeholder: "2026-11-10 18:00")
            }
            Picker("Условие окна", selection: $value.rule) {
                ForEach(WindowRule.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            Text("Укажите дату и время по часовому поясу адреса. Разгрузка должна целиком помещаться в окно, если выбрано завершение до закрытия.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Если время неоднозначно из-за перевода часов") {
                FreightField("Смещение от UTC", text: $value.foldOffset, placeholder: "+03:00")
            }.font(.caption)
        }
    }
}

struct OrderEditor: View {
    @Binding var value: DeliveryOrder
    @ObservedObject var store: RouteStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Заказ") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        FreightField("Номер заказа", text: $value.number, placeholder: "Заказ 001")
                        FreightField("Что везём", text: $value.cargo, placeholder: "Название груза")
                    }
                    Picker("Перевозка", selection: $value.mode) {
                        ForEach(OrderMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    HStack(spacing: 12) {
                        FreightField("Масса, кг", text: $value.kg, placeholder: "100")
                        FreightField("Объём, м³", text: $value.m3, placeholder: "1,2")
                        FreightField("Палеты, если учитываются", text: $value.pallets, placeholder: "Не учитывать")
                    }
                    Toggle("Заказ обязателен к выполнению", isOn: $value.mandatory)
                    Stepper("Приоритет: \(value.priority)", value: $value.priority, in: 0...100)
                }.padding(8)
            }
            if value.mode == .shipment {
                GroupBox("Погрузка") {
                    VStack(alignment: .leading, spacing: 14) {
                        PlaceEditor(title: "Где забрать груз", value: $value.pickup, store: store)
                        Divider()
                        TimeSlotEditor(value: $value.pickupWindow)
                        FreightField("Время погрузки, мин", text: $value.pickupMinutes, placeholder: "Введите длительность или 0")
                    }.padding(8)
                }
            } else {
                Text("Груз этого заказа загружается на базе до развозки. Начальная загрузка и время работы на базе учитываются у выбранной машины.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            GroupBox("Доставка") {
                VStack(alignment: .leading, spacing: 14) {
                    PlaceEditor(title: "Куда доставить", value: $value.delivery, store: store)
                    Divider()
                    TimeSlotEditor(value: $value.deliveryWindow)
                    FreightField("Время разгрузки, мин", text: $value.deliveryMinutes, placeholder: "Введите длительность или 0")
                }.padding(8)
            }
            GroupBox("Дополнительные условия") {
                VStack(alignment: .leading, spacing: 12) {
                    FreightField("Требования к машине", text: $value.skills, placeholder: "Гидроборт, тент — через запятую")
                    HStack(spacing: 12) {
                        FreightField("Контакт для водителя", text: $value.contact)
                        FreightField("Телефон", text: $value.phone)
                    }
                    FreightField("Выручка по заказу", text: $value.revenue, placeholder: "Если выбран расчёт по заказам")
                    FreightField("Примечание", text: $value.note, placeholder: "Въезд, документы, особенности груза")
                    Text("Контакты, примечания и стоимость заказа не передаются дорожному сервису.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
        }.padding(.vertical, 6)
    }
}

struct VehicleEditor: View {
    @Binding var value: FleetVehicle
    @ObservedObject var store: RouteStore
    @State private var removeBreak: UUID?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            identity
            GroupBox("Начало и конец рейса") {
                VStack(alignment: .leading, spacing: 14) {
                    PlaceEditor(title: "Старт и база загрузки", value: $value.start, store: store)
                    Divider()
                    Toggle("Открытый маршрут без заданного финиша", isOn: $value.openEnd)
                    if !value.openEnd {
                        Toggle("Вернуться в точку старта", isOn: $value.returnToStart)
                        if !value.returnToStart { PlaceEditor(title: "Где закончить рейс", value: $value.end, store: store) }
                    }
                    HStack(spacing: 12) {
                        FreightField("Начало работы", text: $value.shiftStart, placeholder: "2026-11-10 09:00")
                        FreightField("Окончание работы", text: $value.shiftEnd, placeholder: "2026-11-10 18:00")
                    }
                    Text("Дата и время работы задаются в часовом поясе точки старта.").font(.caption).foregroundStyle(.secondary)
                    FreightField("Загрузка на базе, мин", text: $value.loadingMinutes, placeholder: "Введите длительность или 0")
                    DisclosureGroup("Смещение UTC при повторе часа") { FreightField("Смещение UTC для времени работы", text: $value.foldOffset, placeholder: "+03:00") }.font(.caption)
                }.padding(8)
            }
            truck
            rests
        }.padding(.vertical, 6)
        .confirmationDialog("Удалить перерыв?", isPresented: Binding(get: { removeBreak != nil }, set: { if !$0 { removeBreak = nil } }), titleVisibility: .visible) {
            Button("Удалить перерыв", role: .destructive) { if let id = removeBreak { value.breaks.removeAll { $0.id == id } }; removeBreak = nil }
            Button("Отменить", role: .cancel) { removeBreak = nil }
        }
    }
    private var identity: some View {
        GroupBox("Машина и вместимость") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    FreightField("Название машины", text: $value.name, placeholder: "Фургон 1")
                    FreightField("Госномер", text: $value.plate)
                    FreightField("Водитель", text: $value.driver)
                }
                HStack(spacing: 12) {
                    FreightField("Грузоподъёмность, кг", text: $value.capacityKg)
                    FreightField("Полезный объём, м³", text: $value.capacityM3)
                    FreightField("Палеты, если учитываются", text: $value.palletCapacity, placeholder: "Не учитывать")
                }
                FreightField("Возможности машины", text: $value.skills, placeholder: "Гидроборт, тент — через запятую")
            }.padding(8)
        }
    }
    private var truck: some View {
        GroupBox("Грузовой дорожный профиль") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    FreightField("Масса пустой машины, кг", text: $value.tareKg)
                    FreightField("Разрешённая полная масса, кг", text: $value.maxGrossKg)
                }
                HStack(spacing: 12) {
                    FreightField("Высота, м", text: $value.heightM)
                    FreightField("Ширина, м", text: $value.widthM)
                    FreightField("Длина, м", text: $value.lengthM)
                }
                HStack(spacing: 12) {
                    FreightField("Нагрузка на ось, кг", text: $value.axleKg)
                    FreightField("Число осей", text: $value.axleCount)
                }
                Toggle("Есть прицеп", isOn: $value.trailer)
                FreightField("Необходимые пропуска", text: $value.permits, placeholder: "Если нужны для рейса")
                if value.trailer || !value.permits.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Label("Проверьте поддержку прицепа и пропусков выбранным подключением. Эти ограничения нельзя считать учтёнными автоматически.", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text("Укажите наружные габариты машины. Полная масса, полезная нагрузка и нагрузка на ось — разные величины.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
    private var rests: some View {
        GroupBox("Перерывы и отдых") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach($value.breaks) { $item in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            FreightField("Название перерыва", text: $item.name, placeholder: "Отдых")
                            Button("Удалить…") { removeBreak = item.id }
                        }
                        TimeSlotEditor(value: $item.slot)
                        FreightField("Продолжительность, мин", text: $item.minutes)
                        Toggle("Есть конкретная остановка", isOn: $item.hasPlace)
                        if item.hasPlace { PlaceEditor(title: "Место отдыха", value: $item.place, store: store) }
                        else { Text("Время в часовом поясе старта. Перерыв без адреса не подтверждает наличие подходящей стоянки.").font(.caption).foregroundStyle(.secondary) }
                        Divider()
                    }
                }
                Button("Добавить перерыв") { value.breaks.append(DriverBreak()) }
                Text("Расписание учитывает введённые перерывы. Полная нормативная проверка труда и отдыха водителя в эту версию не входит.").font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}

struct CostsEditor: View {
    @Binding var value: TripCosts
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Топливо и автомобиль") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        FreightField("Расход с грузом, л/100 км", text: $value.fuelLoadedL100)
                        FreightField("Расход порожняком, л/100 км", text: $value.fuelEmptyL100)
                        FreightField("Цена топлива за литр", text: $value.fuelPrice)
                    }
                    HStack(spacing: 12) {
                        FreightField("Автомобиль за км без топлива", text: $value.vehiclePerKm)
                        FreightField("Фиксированная стоимость выхода машины", text: $value.fixedPerVehicle)
                    }
                }.padding(8)
            }
            GroupBox("Оплата водителя") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Почасовая оплата", isOn: $value.driverHourly)
                    FreightField(value.driverHourly ? "Ставка за час" : "Водитель за машину, фиксированно", text: $value.driverPay)
                    if value.driverHourly {
                        HStack(spacing: 18) {
                            Toggle("Оплачивать ожидание", isOn: $value.payWaiting)
                            Toggle("Погрузку и разгрузку", isOn: $value.payService)
                            Toggle("Перерывы", isOn: $value.payRest)
                        }
                    }
                }.padding(8)
            }
            GroupBox("Дополнительные расходы") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        FreightField("Платные дороги", text: $value.tolls)
                        FreightField("Парковки", text: $value.parking)
                    }
                    HStack(spacing: 12) {
                        FreightField("Ночёвки", text: $value.overnight)
                        FreightField("Прочие затраты", text: $value.other)
                    }
                    Text("Укажите итоговые суммы по рейсу. Если расходов нет, введите 0. Неизвестная сумма остаётся пустой.").font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            GroupBox("Выручка") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Выручка по заказам", isOn: $value.revenueByOrders)
                    if value.revenueByOrders { Text("Заполните стоимость в карточках заказов. Общая сумма за рейс повторно не прибавляется.").foregroundStyle(.secondary) }
                    else { FreightField("Общая выручка за рейс", text: $value.revenue) }
                }.padding(8)
            }
        }
    }
}
