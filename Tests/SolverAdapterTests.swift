import Foundation

func place(_ name:String,_ x:Double)->RoutePlace {
    RoutePlace(address:name,originalAddress:name,latitude:"55.7",longitude:String(x),timeZone:"Europe/Moscow",confirmed:true,source:"Explicit matrix verification")
}
func makePlan()->RoutePlan {
    var v=FleetVehicle();v.name="Проверочная машина";v.start=place("База",37.6)
    v.shiftStart="2026-11-06 08:00";v.shiftEnd="2026-11-06 18:00";v.loadingMinutes="10"
    v.capacityKg="1000";v.capacityM3="10";v.palletCapacity="10";v.tareKg="1500";v.maxGrossKg="3500"
    v.heightM="2";v.widthM="2";v.lengthM="4";v.axleKg="1800"
    var pause=DriverBreak();pause.name="Обед";pause.minutes="15";pause.slot=TimeSlot(from:"2026-11-06 08:15",until:"2026-11-06 09:00")
    v.breaks=[pause]
    var a=DeliveryOrder();a.number="База-1";a.cargo="Груз с базы";a.kg="100";a.m3="2";a.pallets="1"
    a.delivery=place("Получатель 1",37.7);a.deliveryMinutes="5"
    // Window starts before the shift, which must be supported.
    a.deliveryWindow=TimeSlot(from:"2026-11-06 07:00",until:"2026-11-06 17:00")
    var b=DeliveryOrder();b.number="Перевозка-2";b.cargo="Парная перевозка";b.mode = .shipment
    b.kg="200";b.m3="3";b.pallets="2";b.pickup=place("Отправитель",37.8);b.delivery=place("Получатель 2",37.9)
    b.pickupMinutes="5";b.deliveryMinutes="5";b.pickupWindow=TimeSlot(from:"2026-11-06 08:00",until:"2026-11-06 17:00");b.deliveryWindow=b.pickupWindow
    var p=RoutePlan();p.vehicles=[v];p.orders=[a,b];return p
}
func run(_ plan:RoutePlan,executable:URL,customDurations:[[Double?]]?=nil,customDistances:[[Double?]]?=nil) async throws -> PlanVariant {
    let prepared=try PlanChecks.prepare(plan)
    var nodes=[GeoCoordinate]()
    for v in prepared.vehicles {nodes.append(v.vehicle.start.coordinate!)}
    for v in prepared.visits {if !nodes.contains(v.place.coordinate!) {nodes.append(v.place.coordinate!)}}
    let n=nodes.count
    let durations=customDurations ?? (0..<n).map { i in (0..<n).map { j -> Double? in i==j ? 0:120 } }
    let distances=customDistances ?? (0..<n).map { i in (0..<n).map { j -> Double? in i==j ? 0:1000 } }
    let matrix=MatrixSnapshot(provider:"Explicit controlled matrix; no road API",profileKey:"truck-check",nodes:nodes,durations:durations,distances:distances)
    return try await SolverAdapter.optimize(prepared:prepared,matrices:["truck-check":matrix],profileKeys:Dictionary(uniqueKeysWithValues:prepared.vehicles.map{($0.vehicle.id,"truck-check")}),nodes:nodes,executable:executable)
}
@main struct SolverAdapterTests {
    static var passed:[String]=[]
    static func check(_ name:String,_ value:Bool) throws {guard value else {throw RouteFailure.invalid("FAILED: "+name)};passed.append(name)}
    static func main() async throws {
        let name=URL(fileURLWithPath:CommandLine.arguments[0]).lastPathComponent
        if name=="adapter-slow-solver" {
            _=FileHandle.standardInput.readDataToEndOfFile()
            try await Task.sleep(nanoseconds:10_000_000_000);return
        }
        if name=="adapter-error-solver" {
            _=FileHandle.standardInput.readDataToEndOfFile()
            FileHandle.standardError.write(Data(repeating:120,count:60_000))
            FileHandle.standardOutput.write(Data("{\"code\":2,\"error\":\"controlled error\"}".utf8));exit(2)
        }
        let executable=URL(fileURLWithPath:CommandLine.arguments.count>1 ? CommandLine.arguments[1]:"Vendor/bin/vroom")
        let p=makePlan()
        var result=try await run(p,executable:executable)
        try check("mixed depot and pickup/delivery assigned",result.routes.count==1 && result.unassigned.isEmpty)
        try check("start includes loading before departure",result.routes[0].steps.first!.serviceSeconds==600)
        try check("unlocated break has source token and no invented point",result.routes[0].steps.contains{$0.kind == .rest && $0.coordinate == nil && !$0.sourceToken.isEmpty})
        result.verifiedRoads=true // Only bypass road-proof gate to check constraints independently.
        try check("independent capacity, windows, pairing, loading and schedule validation",PlanChecks.validate(result,for:p).isEmpty)
        var open=p;open.vehicles[0].returnToStart=false;open.vehicles[0].openEnd=true
        let o=try await run(open,executable:executable)
        try check("open end at last geographical stop",o.routes[0].steps.last!.kind == .end && o.routes[0].steps.last!.coordinate != nil)
        var over=p;over.vehicles[0].capacityKg="50"
        let u=try await run(over,executable:executable)
        try check("infeasible capacity retained as unassigned orders",u.unassigned.count==2)
        var located=p;located.vehicles[0].breaks[0].hasPlace=true;located.vehicles[0].breaks[0].place=place("Стоянка",38)
        var l=try await run(located,executable:executable);l.verifiedRoads=true
        try check("located break constrained to matching vehicle",PlanChecks.validate(l,for:located).isEmpty)
        // Opposing asymmetric matrices prove distance costs do not replace actual time.
        var goal=p;goal.vehicles[0].breaks=[];goal.orders=[]
        for i in 1...3 {var order=p.orders[0];order.id=UUID();order.number=String(i);order.delivery=place("Точка \(i)",37.6+Double(i)/10);goal.orders.append(order)}
        var times=Array(repeating:Array<Double?>(repeating:100,count:4),count:4)
        var meters=Array(repeating:Array<Double?>(repeating:10000,count:4),count:4)
        for i in 0..<4 {times[i][i]=0;meters[i][i]=0}
        for (a,b) in [(0,1),(1,2),(2,3),(3,0)] {times[a][b]=10}
        for (a,b) in [(0,3),(3,2),(2,1),(1,0)] {meters[a][b]=100}
        let timeResult=try await run(goal,executable:executable,customDurations:times,customDistances:meters)
        goal.goal = .distance
        let distanceResult=try await run(goal,executable:executable,customDurations:times,customDistances:meters)
        let timeIDs=timeResult.routes[0].steps.filter{$0.kind == .delivery}.compactMap(\.orderID)
        let distanceIDs=distanceResult.routes[0].steps.filter{$0.kind == .delivery}.compactMap(\.orderID)
        try check("time objective uses fastest asymmetric order",timeIDs==goal.orders.map(\.id))
        try check("distance objective uses shortest asymmetric order",distanceIDs==Array(goal.orders.map(\.id).reversed()))
        try check("distance objective retains actual durations",distanceResult.totalDrivingSeconds==400 && distanceResult.totalMeters==400)
        let scratch=FileManager.default.temporaryDirectory.appendingPathComponent("freight-adapter-check-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:scratch,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:scratch)}
        let own=URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let slow=scratch.appendingPathComponent("adapter-slow-solver"),error=scratch.appendingPathComponent("adapter-error-solver")
        try FileManager.default.createSymbolicLink(at:slow,withDestinationURL:own)
        try FileManager.default.createSymbolicLink(at:error,withDestinationURL:own)
        let task=Task {try await run(p,executable:slow)}
        try await Task.sleep(nanoseconds:200_000_000);let cancelledAt=Date();task.cancel()
        do {_=try await task.value;throw RouteFailure.invalid("Cancellation ignored")} catch is CancellationError {try check("cancellation terminates owned child promptly",Date().timeIntervalSince(cancelledAt)<3)}
        do {_=try await run(p,executable:error);throw RouteFailure.invalid("Process error ignored")} catch {try check("stderr drained while structured failure propagated",error.localizedDescription.contains("controlled error"))}
        #if arch(arm64)
        let architecture="arm64"
        #else
        let architecture="x86_64"
        #endif
        let report:[String:Any]=["checksPassed":passed.count,"checks":passed,"failures":[],"scope":"Bundled VROOM through Swift adapter on explicit asymmetric matrices; no network, road API or installed GUI proof","solver":"VROOM 1.15.0","runtimeArchitecture":architecture,"inputScale":"grams, litres, pallet counts; UTC epochs converted to relative solver seconds","cancellation":"only owned Process receives SIGTERM"]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);FileHandle.standardOutput.write(data);print()
    }
}
