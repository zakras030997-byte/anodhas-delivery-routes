import Foundation

enum PlanMode: String, Codable, CaseIterable { case city = "Городская доставка", intercity = "Междугородний рейс" }
enum OrderMode: String, Codable, CaseIterable { case depot = "Доставка с базы", shipment = "Забрать и доставить" }
enum WindowRule: String, Codable, CaseIterable { case finish = "Завершить до закрытия", start = "Начать в интервале" }
enum SearchGoal: String, Codable, CaseIterable { case time = "Дорожное время", distance = "Пробег" }
enum VisitKind: String, Codable { case start, pickup, delivery, rest, end }
enum RoadProvider: String, Codable, CaseIterable { case community = "Открытый сервис Valhalla", own = "Свой сервер Valhalla" }

struct RoutePlace: Codable, Equatable {
    var address = ""
    var originalAddress = ""
    var latitude = ""
    var longitude = ""
    var timeZone = "Europe/Moscow"
    var confirmed = false
    var source = "Ручной ввод"
    var coordinate: GeoCoordinate? {
        guard let lat = Double(latitude.replacingOccurrences(of:",",with:".")), let lon = Double(longitude.replacingOccurrences(of:",",with:".")), lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return GeoCoordinate(latitude:lat,longitude:lon)
    }
}
struct GeoCoordinate: Codable, Equatable { var latitude: Double; var longitude: Double }
struct TimeSlot: Codable, Equatable {
    var from = ""
    var until = ""
    var foldOffset = ""
    var rule: WindowRule = .finish
}
struct DriverBreak: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Перерыв"
    var slot = TimeSlot()
    var minutes = ""
    var hasPlace = false
    var place = RoutePlace()
}
struct FleetVehicle: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Новая машина"
    var plate = ""
    var driver = ""
    var start = RoutePlace()
    var end = RoutePlace()
    var returnToStart = true
    var openEnd = false
    var shiftStart = ""
    var shiftEnd = ""
    var foldOffset = ""
    var loadingMinutes = "0"
    var capacityKg = ""
    var capacityM3 = ""
    var palletCapacity = ""
    var tareKg = ""
    var maxGrossKg = ""
    var heightM = ""
    var widthM = ""
    var lengthM = ""
    var axleKg = ""
    var axleCount = "2"
    var trailer = false
    var permits = ""
    var skills = ""
    var breaks: [DriverBreak] = []
}
struct DeliveryOrder: Codable, Equatable, Identifiable {
    var id = UUID()
    var number = ""
    var cargo = ""
    var mode: OrderMode = .depot
    var kg = ""
    var m3 = ""
    var pallets = ""
    var pickup = RoutePlace()
    var delivery = RoutePlace()
    var pickupWindow = TimeSlot()
    var deliveryWindow = TimeSlot()
    var pickupMinutes = ""
    var deliveryMinutes = ""
    var mandatory = true
    var priority = 50
    var skills = ""
    var contact = ""
    var phone = ""
    var revenue = ""
    var note = ""
}
struct TripCosts: Codable, Equatable {
    var revenueByOrders = false
    var fuelLoadedL100 = ""
    var fuelEmptyL100 = ""
    var fuelPrice = ""
    var vehiclePerKm = ""
    var fixedPerVehicle = ""
    var driverHourly = false
    var driverPay = ""
    var payWaiting = true
    var payService = true
    var payRest = false
    var tolls = ""
    var parking = ""
    var overnight = ""
    var other = ""
    var revenue = ""
}
struct RoutePlan: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = "Новый план"
    var mode: PlanMode = .city
    var goal: SearchGoal = .time
    var currency = "RUB"
    var createdAt = Date()
    var revision = 0
    var vehicles: [FleetVehicle] = []
    var orders: [DeliveryOrder] = []
    var costs = TripCosts()
    var manualOrder: [String] = []
    var variants: [PlanVariant] = []
    var selectedVariant: UUID?
    var operationCount: Int { orders.reduce(0) { $0 + ($1.mode == .shipment ? 2 : 1) } }
    var selected: PlanVariant? { variants.first { $0.id == selectedVariant } }
}
struct ProviderSettings: Codable, Equatable {
    var provider: RoadProvider = .community
    var ownEndpoint = ""
    var timeoutSeconds = 15
    var avoidTolls = false
    var avoidUnpaved = false
    var publicNoticeAccepted = false
    var endpoint: String { provider == .community ? "https://valhalla1.openstreetmap.de" : ownEndpoint.trimmingCharacters(in:.whitespacesAndNewlines) }
    var attribution: String { "© OpenStreetMap contributors · Valhalla" }
}
struct RouteWorkspace: Codable, Equatable {
    var version = 1
    var plans: [RoutePlan] = []
    var selected: UUID?
    var settings = ProviderSettings()
}
struct PlanVariant: Codable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var calculatedAt = Date()
    var revision: Int
    var provider: String
    var engine = "VROOM 1.15.0"
    var goal: SearchGoal
    var routes: [PlannedRoute]
    var unassigned: [UUID] = []
    var issues: [String] = []
    var matrixSnapshot: MatrixSnapshot?
    var matrices: [String: MatrixSnapshot] = [:]
    var verifiedRoads = false
    var totalMeters: Double { routes.reduce(0) { $0 + $1.meters } }
    var totalDrivingSeconds: Double { routes.reduce(0) { $0 + $1.drivingSeconds } }
    var totalSeconds: Double { routes.reduce(0) { $0 + max(0,$1.finish-$1.departure) } }
}
struct MatrixSnapshot: Codable, Equatable {
    var date = Date()
    var provider: String
    var profileKey: String
    var nodes: [GeoCoordinate]
    var durations: [[Double?]]
    var distances: [[Double?]]
}
struct PlannedRoute: Codable, Equatable, Identifiable {
    var id = UUID()
    var vehicleID: UUID
    var vehicleName: String
    var departure: Double
    var finish: Double
    var steps: [PlannedStep]
    var meters: Double
    var drivingSeconds: Double
    var polyline: [GeoCoordinate] = []
    var issues: [String] = []
}
struct PlannedStep: Codable, Equatable, Identifiable {
    var id = UUID()
    var sourceToken = ""
    var orderID: UUID?
    var kind: VisitKind
    var title: String
    var address: String
    var coordinate: GeoCoordinate?
    var timeZone: String
    var arrival: Double
    var waitingSeconds: Double
    var serviceSeconds: Double
    var departure: Double
    var kgAfter: Double
    var m3After: Double
    var palletsAfter: Int
    var metersFromPrevious: Double
    var drivingFromPrevious: Double
}
struct PreparedVisit {
    var sourceToken = ""
    var solverID: Int
    var orderID: UUID?
    var vehicleID: UUID?
    var kind: VisitKind
    var title: String
    var place: RoutePlace
    var earliest: Int
    var latestStart: Int
    var service: Int
    var amounts: [Int]
    var skills: [Int]
    var priority: Int
}
struct PreparedVehicle {
    var solverID: Int
    var vehicle: FleetVehicle
    var startSeconds: Int
    var endSeconds: Int
    var capacities: [Int]
    var skills: [Int]
}
struct PreparedPlan {
    var plan: RoutePlan
    var vehicles: [PreparedVehicle]
    var visits: [PreparedVisit]
    var issues: [String]
    var originSeconds: Int
}

enum RouteFailure: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let s) = self { return s }; return nil }
}
