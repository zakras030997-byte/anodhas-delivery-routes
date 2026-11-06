import Foundation

#if PIPELINE_TEST_STUB
enum SolverAdapter {
    static func optimize(prepared:PreparedPlan,matrices:[String:MatrixSnapshot],profileKeys:[UUID:String],nodes:[GeoCoordinate],executable:URL,timeoutSeconds:Int=15) async throws -> PlanVariant { throw RouteFailure.invalid("Manual path unexpectedly invoked solver") }
}
#endif
actor StubRoads: PipelineRoads {
    struct Call {var from:GeoCoordinate;var to:GeoCoordinate;var gross:Double;var departure:Double?;var zone:String}
    var calls:[Call]=[]
    let seconds:Double
    let fails:Bool
    let warning:Bool
    init(seconds:Double=600,fails:Bool=false,warning:Bool=false) {self.seconds=seconds;self.fails=fails;self.warning=warning}
    func route(from:GeoCoordinate,to:GeoCoordinate,vehicle:FleetVehicle,grossKg:Double,departure:Double?,timeZone:String) async throws -> RoadLeg {
        calls.append(Call(from:from,to:to,gross:grossKg,departure:departure,zone:timeZone))
        if fails {throw RouteFailure.invalid("Controlled road failure")}
        return RoadLeg(seconds:from==to ? 0 : seconds,meters:from==to ? 0 : 10000,shape:[from,to],issues:warning ? ["Controlled road warning"] : [])
    }
    func matrix(nodes:[GeoCoordinate],vehicle:FleetVehicle,grossKg:Double,progress:@escaping @Sendable(String)->Void) async throws -> MatrixSnapshot {throw RouteFailure.invalid("Manual path unexpectedly requested matrix")}
    func records()->[Call] {calls}
}
@main struct PipelineTests {
    static var passed:[String]=[],failed:[String]=[]
    static func check(_ name:String,_ value:@autoclosure()->Bool) {if value(){passed.append(name)}else{failed.append(name)}}
    static func time(_ s:String)->Double {Double(try! RouteTime.parse(s,zone:"Europe/Moscow"))}
    static func place(_ name:String,_ lat:Double=59.9,_ lon:Double=30.3)->RoutePlace {var p=RoutePlace();p.address=name;p.latitude=String(lat);p.longitude=String(lon);p.confirmed=true;return p}
    static func fixture()->RoutePlan {
        var p=RoutePlan();p.name="Проверка расписания"
        var v=FleetVehicle();v.name="Машина";v.start=place("База");v.shiftStart="2026-11-07 08:00";v.shiftEnd="2026-11-07 20:00";v.capacityKg="1000";v.capacityM3="10";v.palletCapacity="8";v.tareKg="2000";v.maxGrossKg="3500";v.heightM="2.5";v.widthM="2";v.lengthM="6";v.axleKg="1800";p.vehicles=[v]
        var o=DeliveryOrder();o.number="1";o.cargo="Груз";o.kg="100";o.m3="0.5";o.pallets="1";o.delivery=place("Получатель",59.92,30.35);o.deliveryWindow.from="2026-11-07 09:00";o.deliveryWindow.until="2026-11-07 13:00";o.deliveryMinutes="20";p.orders=[o];return p
    }
    static func pause(_ from:String="09:00",_ until:String="10:00",_ minutes:String="10",located:Bool=false)->DriverBreak {var b=DriverBreak();b.name="Отдых";b.slot.from="2026-11-07 "+from;b.slot.until="2026-11-07 "+until;b.minutes=minutes;b.hasPlace=located;b.place=place("Стоянка",59.91,30.32);return b}
    static func pipeline(_ roads:StubRoads,accepted:Bool=true)->RoutePipeline {var s=ProviderSettings();s.publicNoticeAccepted=accepted;return RoutePipeline(settings:s,executable:URL(fileURLWithPath:"/nonexistent/solver"),progress:{_ in},roadsOverride:roads)}
    static func main() async throws {
        let p=fixture();var roads=StubRoads();var result=try await pipeline(roads).run(plan:p,manual:true)
        check("manual route avoids matrix and solver",result.routes.count==1)
        check("manual route independently valid",result.issues.isEmpty)
        check("road distance reconciled",result.totalMeters==20000)
        check("arrival waits for customer window",result.routes[0].steps[1].waitingSeconds==3000)
        var calls=await roads.records()
        check("actual loaded and empty gross weights",calls.map(\.gross)==[2100,2000])
        check("first leg departure exact",calls[0].departure==time("2026-11-07 08:00"))
        check("return leg begins after service",calls[1].departure==time("2026-11-07 09:20"))
        var q=p;q.vehicles[0].loadingMinutes="30";roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true);calls=await roads.records()
        check("loading appears once",result.routes[0].steps[0].serviceSeconds==1800)
        check("road ETA starts after loading",calls[0].departure==time("2026-11-07 08:30"))
        check("loading schedule independently valid",result.issues.isEmpty)
        q=p;q.orders[0].mode = .shipment;q.orders[0].pickup=place("Отправитель",59.91,30.32);q.orders[0].pickupWindow.from="2026-11-07 08:00";q.orders[0].pickupWindow.until="2026-11-07 09:00";q.orders[0].pickupMinutes="10";roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true);calls=await roads.records()
        check("shipment has paired visits",result.routes[0].steps.filter{$0.orderID != nil}.map(\.kind)==[.pickup,.delivery])
        check("shipment dynamic gross weights",calls.map(\.gross)==[2000,2100,2000])
        check("shipment independently valid",result.issues.isEmpty)
        q=p;q.vehicles[0].breaks=[pause()];roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true)
        let rests=result.routes[0].steps.filter{$0.kind == .rest}
        check("rest fits existing wait",rests.count==1 && rests[0].arrival+rests[0].waitingSeconds==time("2026-11-07 09:00"))
        check("rest has no invented map point",rests.first?.coordinate==nil)
        check("rest preserves all road distance",result.totalMeters==20000)
        check("waiting rest independently valid",result.issues.isEmpty)
        q=p;q.vehicles[0].returnToStart=false;q.vehicles[0].openEnd=true;q.vehicles[0].breaks=[pause("09:05","10:00")];roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true)
        check("open route includes rest due during last service",result.routes[0].steps.last?.kind == .rest)
        check("open route after service rest valid",result.issues.isEmpty)
        q=p;q.vehicles[0].breaks=[pause("08:30","08:50")];q.orders[0].deliveryWindow.from="2026-11-07 10:00";roads=StubRoads(seconds:6000);result=try await pipeline(roads).run(plan:q,manual:true);calls=await roads.records()
        check("crossed rest window handled before driving",result.routes[0].steps[1].kind == .rest)
        check("fresh ETA requested after changed departure",calls.count==3 && calls[0].departure==time("2026-11-07 08:00") && calls[1].departure==time("2026-11-07 08:40"))
        check("long leg rest retains full driving time",result.totalDrivingSeconds==12000)
        check("long leg rest schedule valid",result.issues.isEmpty)
        q=p;q.orders[0].deliveryWindow.from="2026-11-07 10:00";q.vehicles[0].breaks=[pause("09:00","09:30",located:true)];roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true)
        check("default located rest before later order",result.routes[0].steps.map(\.kind)==[.start,.rest,.delivery,.end])
        check("located rest place maintained",result.routes[0].steps[1].coordinate==q.vehicles[0].breaks[0].place.coordinate)
        check("located rest schedule valid",result.issues.isEmpty)
        q=p;q.vehicles[0].breaks=[pause("14:00","15:00")];roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true)
        check("early finished route does not wait for future rest",result.routes[0].steps.allSatisfy{$0.kind != .rest} && result.issues.isEmpty)
        q=p;q.vehicles[0].breaks=[pause("12:00","13:00"),pause("09:00","14:00")];roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true)
        check("later tight break does not hide earlier due break",result.routes[0].steps.filter{$0.kind == .rest}.count==1 && result.issues.isEmpty)
        q=p;q.orders[0].deliveryWindow.until="2026-11-07 09:30";roads=StubRoads(seconds:7200);result=try await pipeline(roads).run(plan:q,manual:true)
        check("road ETA recheck catches missed customer window",result.issues.contains{$0.contains("окно")})
        roads=StubRoads(warning:true);result=try await pipeline(roads).run(plan:p,manual:true)
        check("road warnings survive pipeline",result.issues.contains("Controlled road warning"))
        roads=StubRoads(seconds:.nan)
        do {_=try await pipeline(roads).run(plan:p,manual:true);failed.append("nonfinite road response rejected")}catch{passed.append("nonfinite road response rejected")}
        roads=StubRoads(fails:true)
        do {_=try await pipeline(roads).run(plan:p,manual:true);failed.append("road failure propagated")}catch{check("road failure propagated",error.localizedDescription=="Controlled road failure")}
        roads=StubRoads()
        do {_=try await pipeline(roads,accepted:false).run(plan:p,manual:true);failed.append("public transmission consent enforced")}catch{passed.append("public transmission consent enforced")}
        calls=await roads.records();check("no road call before consent",calls.isEmpty)
        q=p;var second=q.vehicles[0];second.id=UUID();second.name="Вторая";q.vehicles.append(second);var o=q.orders[0];o.id=UUID();o.number="2";q.orders.append(o)
        q.manualOrder=[q.vehicles[0].id.uuidString+"|"+q.orders[0].id.uuidString+"#delivery",second.id.uuidString+"|"+o.id.uuidString+"#delivery"]
        roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true)
        check("manual assignment preserves two vehicles",result.routes.count==2 && result.issues.isEmpty)
        q.manualOrder.append(q.manualOrder[0]);roads=StubRoads();result=try await pipeline(roads).run(plan:q,manual:true)
        check("duplicate manual visit not silently accepted",result.issues.contains{$0.contains("повторяется")})
        let report:[String:Any]=["checksPassed":passed.count,"checks":passed,"failures":failed,"scope":"Manual pipeline with injected road actor, independent validation; no network, real solver or installed UI"]
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);FileHandle.standardOutput.write(data);print();if !failed.isEmpty{exit(1)}
    }
}
