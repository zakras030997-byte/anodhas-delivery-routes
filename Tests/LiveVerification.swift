import Foundation

enum LiveFixtures {
    static func place(_ address:String,_ lat:Double,_ lon:Double)->RoutePlace {
        var p=RoutePlace();p.address=address;p.latitude=String(lat);p.longitude=String(lon);p.confirmed=true;p.source="Контрольные публичные координаты";return p
    }
    static func city()->RoutePlan {
        var p=RoutePlan();p.name="Проверка · Санкт-Петербург"
        var v=FleetVehicle();v.name="Фургон";v.start=place("Санкт-Петербург, Дворцовая площадь",59.9386,30.3141)
        v.shiftStart="2026-11-07 09:00";v.shiftEnd="2026-11-07 18:00";v.loadingMinutes="15"
        v.capacityKg="1000";v.capacityM3="8";v.palletCapacity="4";v.tareKg="2000";v.maxGrossKg="3500";v.heightM="2.4";v.widthM="2.1";v.lengthM="6";v.axleKg="2000"
        p.vehicles=[v]
        var o=DeliveryOrder();o.number="К-001";o.cargo="Коробки";o.kg="100";o.m3="1";o.pallets="1"
        o.delivery=place("Санкт-Петербург, Лиговский проспект",59.9253,30.3593)
        o.deliveryWindow.from="2026-11-07 09:00";o.deliveryWindow.until="2026-11-07 17:00";o.deliveryMinutes="15";o.revenue="5000";p.orders=[o]
        p.costs.fuelLoadedL100="12";p.costs.fuelEmptyL100="10";p.costs.fuelPrice="65";p.costs.vehiclePerKm="8";p.costs.fixedPerVehicle="300";p.costs.driverPay="1000";p.costs.tolls="0";p.costs.parking="0";p.costs.overnight="0";p.costs.other="0";p.costs.revenueByOrders=true
        return p
    }
    static func intercity()->RoutePlan {
        var p=city();p.id=UUID();p.name="Проверка · Петербург — Москва";p.mode = .intercity
        p.vehicles[0].openEnd=true;p.vehicles[0].returnToStart=false;p.vehicles[0].shiftEnd="2026-11-08 18:00"
        p.orders[0].delivery=place("Москва, центр",55.7558,37.6173);p.orders[0].deliveryWindow.until="2026-11-08 17:00";p.orders[0].revenue="40000"
        return p
    }
}

@main struct LiveVerification {
    struct Document:Codable {var version=1;var plan:RoutePlan}
    static func main() async throws {
        let directory=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Verification")
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let city=LiveFixtures.city()
        try encoder.encode(Document(plan:city)).write(to:directory.appendingPathComponent("city-input.json"))
        try encoder.encode(Document(plan:LiveFixtures.intercity())).write(to:directory.appendingPathComponent("intercity-input.json"))
        guard CommandLine.arguments.contains("--network") else{print("Input fixtures written; no network calls.");return}
        var settings=ProviderSettings();settings.publicNoticeAccepted=true
        let solver=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("Vendor/bin/vroom")
        let pipeline=RoutePipeline(settings:settings,executable:solver,progress:{_ in})
        let optimized=try await pipeline.run(plan:city,manual:false)
        guard optimized.verifiedRoads,optimized.issues.isEmpty,optimized.unassigned.isEmpty,optimized.routes.count==1,optimized.routes[0].polyline.count>2,optimized.totalMeters>0 else{throw RouteFailure.invalid("City path failed: \(optimized.issues)")}
        try encoder.encode(optimized).write(to:directory.appendingPathComponent("live-city-result.json"))
        let long=LiveFixtures.intercity()
        let manual=try await pipeline.run(plan:long,manual:true)
        guard manual.verifiedRoads,manual.issues.isEmpty,manual.totalMeters>500000,manual.routes[0].polyline.count>2 else{throw RouteFailure.invalid("Intercity path failed: \(manual.issues)")}
        try encoder.encode(manual).write(to:directory.appendingPathComponent("live-intercity-result.json"))
        let report:[String:Any]=["cityMeters":optimized.totalMeters,"citySeconds":optimized.totalSeconds,"cityVertices":optimized.routes[0].polyline.count,"cityMatrixProfiles":optimized.matrices.count,"intercityMeters":manual.totalMeters,"intercitySeconds":manual.totalSeconds,"intercityVertices":manual.routes[0].polyline.count,"issues":[],"scope":"Actual public Valhalla truck roads + real bundled VROOM for city; manual intercity. Installed UI is a separate check."]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("live-path-checks.json"))
        print(String(data:try JSONSerialization.data(withJSONObject:report,options:.sortedKeys),encoding:.utf8)!)
    }
}
