import Foundation

@main struct CoreTests {
    static var passed: [String] = []
    static var failed: [String] = []
    static func check(_ name: String, _ value: @autoclosure () throws -> Bool) { do { if try value() { passed.append(name) } else { failed.append(name) } } catch { failed.append(name + ": " + error.localizedDescription) } }
    static func rejects(_ name: String, _ body: () throws -> Void) { do { try body(); failed.append(name) } catch { passed.append(name) } }
    static func time(_ s: String) -> Double { Double(try! RouteTime.parse(s,zone:"Europe/Moscow")) }
    static func place(_ name:String,_ lat:Double=59.9,_ lon:Double=30.3) -> RoutePlace {
        var p=RoutePlace(); p.address=name; p.latitude=String(lat); p.longitude=String(lon); p.confirmed=true; return p
    }
    static func fixture(shipment:Bool=false) -> RoutePlan {
        var p=RoutePlan(); p.name="Контрольный рейс"
        var v=FleetVehicle(); v.name="Фургон"; v.start=place("База"); v.shiftStart="2026-11-07 08:00"; v.shiftEnd="2026-11-07 20:00"; v.capacityKg="1000"; v.capacityM3="10"; v.palletCapacity="8"; v.tareKg="2000"; v.maxGrossKg="3500"; v.heightM="2,5"; v.widthM="2"; v.lengthM="6"; v.axleKg="1800"; v.skills="Гидроборт, тент"; p.vehicles=[v]
        var o=DeliveryOrder(); o.number="З-1"; o.cargo="Комплектующие"; o.kg="100"; o.m3="0,5"; o.pallets="1"; o.delivery=place("Склад",59.92,30.35); o.deliveryWindow.from=shipment ? "2026-11-07 10:00" : "2026-11-07 09:00"; o.deliveryWindow.until="2026-11-07 12:00"; o.deliveryMinutes="20"; o.skills="гидроборт"; o.revenue="1000"
        if shipment { o.mode = .shipment; o.pickup=place("Погрузка",59.91,30.32); o.pickupWindow.from="2026-11-07 09:00"; o.pickupWindow.until="2026-11-07 10:00"; o.pickupMinutes="10" }
        p.orders=[o]
        var c=TripCosts(); c.fuelLoadedL100="10"; c.fuelEmptyL100="8"; c.fuelPrice="60"; c.vehiclePerKm="2"; c.fixedPerVehicle="100"; c.driverPay="500"; c.tolls="0"; c.parking="0"; c.overnight="0"; c.other="0"; c.revenue="1000"; p.costs=c
        return p
    }
    static func step(_ kind:VisitKind,_ title:String,_ p:RoutePlace?,_ arrival:Double,_ wait:Double,_ service:Double,_ kg:Double,_ volume:Double,_ pallets:Int,_ distance:Double=0,_ driving:Double=0,_ order:UUID?=nil)->PlannedStep {
        var s=PlannedStep(orderID:order,kind:kind,title:title,address:p?.address ?? "",coordinate:p?.coordinate,timeZone:p?.timeZone ?? "Europe/Moscow",arrival:arrival,waitingSeconds:wait,serviceSeconds:service,departure:arrival+wait+service,kgAfter:kg,m3After:volume,palletsAfter:pallets,metersFromPrevious:distance,drivingFromPrevious:driving)
        if let order { s.sourceToken=order.uuidString+"#"+kind.rawValue }; return s
    }
    static func variant(_ p:RoutePlan)->PlanVariant {
        let v=p.vehicles[0],o=p.orders[0]; let start=time("2026-11-07 08:00")
        let steps:[PlannedStep]
        if o.mode == .depot {
            steps=[step(.start,"База",v.start,start,0,0,100,0.5,1),step(.delivery,"З-1",o.delivery,start+600,3000,1200,0,0,0,10000,600,o.id),step(.end,"База",v.start,start+5400,0,0,0,0,0,10000,600)]
        } else {
            steps=[step(.start,"База",v.start,start,0,0,0,0,0),step(.pickup,"З-1",o.pickup,start+600,3000,600,100,0.5,1,10000,600,o.id),step(.delivery,"З-1",o.delivery,start+4800,2400,1200,0,0,0,10000,600,o.id),step(.end,"База",v.start,start+9000,0,0,0,0,0,10000,600)]
        }
        let r=PlannedRoute(vehicleID:v.id,vehicleName:v.name,departure:start,finish:steps.last!.departure,steps:steps,meters:Double(steps.count-1)*10000,drivingSeconds:Double(steps.count-1)*600)
        return PlanVariant(name:"Расчёт",revision:p.revision,provider:"Контрольная матрица",goal:p.goal,routes:[r],verifiedRoads:true)
    }
    static func issues(_ p:RoutePlan,_ v:PlanVariant)->[String] { PlanChecks.validate(v,for:p) }
    static func main() throws {
        for (s,n) in [("1 234,50",Decimal(string:"1234.5")!),("1\u{00a0}234.50",Decimal(string:"1234.5")!),("0",Decimal(0)),(" 12,345678 ",Decimal(string:"12.345678")!)] { check("number \(s)",RouteNumbers.parse(s)==n) }
        for s in ["","-1","+1","NaN","inf","1e3","12 34","1,234.5","1.0000001","1000000001","3%"] { check("reject number \(s)",RouteNumbers.parse(s)==nil) }
        check("positive constraint",RouteNumbers.parse("0",allowZero:false)==nil)
        check("half-up decimal rounding",RouteNumbers.rounded(Decimal(string:"1.005")!)==Decimal(string:"1.01")!)
        check("negative balance rounding",RouteNumbers.rounded(Decimal(string:"-1.005")!)==Decimal(string:"-1.01")!)
        check("UTC conversion",try RouteTime.parse("2026-11-07 08:00",zone:"Europe/Moscow")==Int(ISO8601DateFormatter().date(from:"2026-11-07T05:00:00Z")!.timeIntervalSince1970))
        check("T format",try RouteTime.parse("2026-11-07T08:00",zone:"Europe/Moscow")==Int(time("2026-11-07 08:00")))
        rejects("impossible date") { _=try RouteTime.parse("2026-02-31 12:00",zone:"Europe/Moscow") }
        rejects("strict time shape") { _=try RouteTime.parse("7.11.2026 8:00",zone:"Europe/Moscow") }
        rejects("invalid zone") { _=try RouteTime.parse("2026-11-07 08:00",zone:"Unknown/Nowhere") }
        rejects("DST gap") { _=try RouteTime.parse("2026-03-08 02:30",zone:"America/New_York") }
        rejects("DST overlap needs offset") { _=try RouteTime.parse("2026-11-01 01:30",zone:"America/New_York") }
        let early=try RouteTime.parse("2026-11-01 01:30",zone:"America/New_York",offset:"-04:00"),late=try RouteTime.parse("2026-11-01 01:30",zone:"America/New_York",offset:"UTC-05:00")
        check("DST overlap choices differ one hour",late-early==3600)
        rejects("wrong offset rejected") { _=try RouteTime.parse("2026-11-01 03:30",zone:"America/New_York",offset:"-04:00") }
        check("fold choice not a fixed zone override",try RouteTime.parseWithFold("2026-11-01 03:30",zone:"America/New_York",offset:"-04:00")==RouteTime.parse("2026-11-01 03:30",zone:"America/New_York"))
        check("nonfinite display guarded",RouteTime.local(.infinity,zone:"Europe/Moscow")=="Некорректное время")
        let p=fixture(),base=variant(p),prep=try PlanChecks.prepare(p)
        check("valid depot variant",issues(p,base).isEmpty)
        check("grams litres and pallets",prep.visits[0].amounts==[100000,500,1])
        check("finish window converted",prep.visits[0].latestStart==Int(time("2026-11-07 11:40")))
        check("absolute shift unchanged by loader",prep.vehicles[0].startSeconds==Int(time("2026-11-07 08:00")))
        check("origin is absolute earliest shift",prep.originSeconds==prep.vehicles[0].startSeconds)
        check("skills normalized",Set(prep.visits[0].skills).isSubset(of:Set(prep.vehicles[0].skills)))
        var q=p; q.orders[0].deliveryWindow.rule = .start
        check("start window retains closing instant",try PlanChecks.prepare(q).visits[0].latestStart==Int(time("2026-11-07 12:00")))
        q=p; q.orders[0].deliveryWindow.from="2026-11-07 11:50"
        rejects("service must fit finish window") { _=try PlanChecks.prepare(q) }
        q=p; q.vehicles[0].start.confirmed=false
        rejects("unconfirmed place") { _=try PlanChecks.prepare(q) }
        q=p; q.vehicles[0].start.latitude="NaN"
        rejects("nonfinite coordinate") { _=try PlanChecks.prepare(q) }
        q=p; q.orders[0].deliveryMinutes=""
        rejects("unknown service is not zero") { _=try PlanChecks.prepare(q) }
        q=p; q.orders[0].deliveryMinutes="0"
        check("explicit zero service allowed",try PlanChecks.prepare(q).visits[0].service==0)
        q=p; q.orders[0].kg="-1"
        rejects("negative cargo") { _=try PlanChecks.prepare(q) }
        q=p; q.orders[0].m3="0.0005"
        rejects("volume below litre precision") { _=try PlanChecks.prepare(q) }
        q=p; q.orders[0].pallets="1.5"
        rejects("fractional pallets") { _=try PlanChecks.prepare(q) }
        q=p; q.vehicles[0].maxGrossKg="2000"
        rejects("gross mass must exceed tare") { _=try PlanChecks.prepare(q) }
        q=p; q.vehicles[0].capacityKg="2000"
        check("effective payload constrained by gross mass",try PlanChecks.prepare(q).vehicles[0].capacities[0]==1500000)
        q=p; q.vehicles[0].heightM="0"
        rejects("unknown dimensions not zero") { _=try PlanChecks.prepare(q) }
        q=p; q.vehicles[0].shiftEnd="2026-11-08 09:00"
        rejects("city at most twenty four hours") { _=try PlanChecks.prepare(q) }
        q=p; q.mode = .intercity; q.vehicles[0].shiftEnd="2026-11-15 08:00"
        rejects("intercity at most seven days") { _=try PlanChecks.prepare(q) }
        q=p; q.mode = .intercity; var other=q.vehicles[0]; other.id=UUID();q.vehicles.append(other)
        rejects("intercity one vehicle") { _=try PlanChecks.prepare(q) }
        q=p; q.vehicles.append(q.vehicles[0])
        rejects("duplicate vehicle ID") { _=try PlanChecks.prepare(q) }
        q=p; var duplicate=q.orders[0]; duplicate.id=UUID();duplicate.number="з-1";q.orders.append(duplicate)
        rejects("duplicate external number casefold") { _=try PlanChecks.prepare(q) }
        q=p; q.vehicles[0].trailer=true
        check("unsupported trailer blocks readiness",!(try PlanChecks.prepare(q)).issues.isEmpty)
        q=p; q.vehicles[0].permits="Пропуск"
        check("unsupported permit blocks readiness",!issues(q,base).isEmpty)
        var b=base; b.revision=99
        check("stale variant detected",issues(p,b).contains { $0.contains("устарел") })
        b=base; b.verifiedRoads=false
        check("unverified roads detected",issues(p,b).contains { $0.contains("Дорожные") })
        b=base; b.routes[0].steps[0].kgAfter=0
        check("preloaded depot cargo checked",issues(p,b).contains { $0.contains("остаток") })
        b=base; b.routes[0].steps[1].arrival=time("2026-11-07 11:50"); b.routes[0].steps[1].waitingSeconds=0; b.routes[0].steps[1].departure=time("2026-11-07 12:10")
        check("finish before close independently checked",issues(p,b).contains { $0.contains("окно") })
        b=base; b.routes[0].steps[1].coordinate=GeoCoordinate(latitude:50,longitude:30)
        check("confirmed stop coordinate checked",issues(p,b).contains { $0.contains("адрес") })
        b=base; b.routes[0].meters = .nan
        check("NaN route rejected",!issues(p,b).isEmpty)
        b=base; b.routes[0].steps[1].waitingSeconds = -1
        check("negative stop fields rejected",!issues(p,b).isEmpty)
        b=base; b.routes[0].meters=1
        check("route metres reconciled",issues(p,b).contains { $0.contains("итог пробега") })
        b=base; b.routes[0].steps.remove(at:1)
        check("mandatory delivery coverage checked",issues(p,b).contains { $0.contains("Обязательный") })
        b=base; b.unassigned=[p.orders[0].id]
        check("assigned unassigned conflict checked",issues(p,b).contains { $0.contains("одновременно") })
        b=base; b.routes[0].steps.insert(b.routes[0].steps[1],at:2)
        check("duplicate operation checked",issues(p,b).contains { $0.contains("повторяется") })
        q=p; q.vehicles[0].capacityKg="50"
        check("preload capacity checked",issues(q,base).contains { $0.contains("вместимость") })
        q=p; q.vehicles[0].skills="тент"
        check("vehicle skills checked",issues(q,base).contains { $0.contains("требованиям") })
        let shipment=fixture(shipment:true),shipmentVariant=variant(shipment)
        check("valid paired shipment",issues(shipment,shipmentVariant).isEmpty)
        check("shipment two visits",try PlanChecks.prepare(shipment).visits.count==2)
        b=shipmentVariant; b.routes[0].steps.swapAt(1,2)
        check("delivery before pickup checked",issues(shipment,b).contains { $0.contains("раньше погрузки") })
        var pause=DriverBreak(); pause.name="Отдых"; pause.minutes="10"; pause.slot.from="2026-11-07 09:00"; pause.slot.until="2026-11-07 10:00"
        q=p; q.vehicles[0].breaks=[pause]
        b=base
        var rest=step(.rest,pause.name,nil,time("2026-11-07 09:20"),0,600,0,0,0); rest.sourceToken=pause.id.uuidString+"#rest"
        b.routes[0].steps.insert(rest,at:2); b.routes[0].steps[3].arrival+=600;b.routes[0].steps[3].departure+=600;b.routes[0].finish+=600
        check("unlocated break preserved",issues(q,b).isEmpty)
        check("missing applicable break detected",issues(q,base).contains { $0.contains("обязательный перерыв") })
        var future=pause; future.slot.from="2026-11-07 14:00";future.slot.until="2026-11-07 15:00";q.vehicles[0].breaks=[future]
        check("ended route need not wait for later break",issues(q,base).isEmpty)
        let economy=Economy.calculate(plan:p,variant:base)
        check("cargo state selects fuel rate",economy.lines.first { $0.name=="Топливо" }?.amount==108)
        check("known total costs",economy.knownTotal==748)
        check("balance decimal",economy.balance==252)
        check("margin percent",economy.margin==Decimal(string:"25.20"))
        check("complete costs no missing",economy.missing.isEmpty)
        q=p;q.costs.driverHourly=true;q.costs.driverPay="200"
        check("hourly movement waiting service",Economy.calculate(plan:q,variant:base).knownTotal==548)
        q.costs.payWaiting=false
        check("hourly excludes optional wait",Economy.calculate(plan:q,variant:base).knownTotal==Decimal(string:"381.33"))
        q=p;q.costs.other=""
        let partial=Economy.calculate(plan:q,variant:base)
        check("unknown cost not zero",partial.lines.first { $0.name=="Прочие расходы" }?.amount==nil)
        check("partial costs suppress final balance",partial.balance==nil)
        q=p;q.costs.revenue="0"
        check("zero revenue has no division",Economy.calculate(plan:q,variant:base).margin==nil)
        q=p;q.costs.revenue="100"
        check("negative balance allowed",Economy.calculate(plan:q,variant:base).balance == -648)
        q=p;q.costs.revenueByOrders=true;q.costs.revenue="999999"
        check("order revenue ignores plan revenue",Economy.calculate(plan:q,variant:base).revenue==1000)
        q.orders[0].revenue=""
        check("unknown order revenue not guessed",Economy.calculate(plan:q,variant:base).revenue==nil)
        q=p;q.costs.fuelEmptyL100="";var oneWay=base;oneWay.routes[0].steps.removeLast();oneWay.routes[0].meters=10000;oneWay.routes[0].drivingSeconds=600;oneWay.routes[0].finish=oneWay.routes[0].steps.last!.departure
        check("unused empty fuel rate irrelevant",Economy.calculate(plan:q,variant:oneWay).lines.first { $0.name=="Топливо" }?.amount==60)
        q=p; q.vehicles[0].breaks=[pause];var second=q.vehicles[0];second.id=UUID();q.vehicles.append(second)
        rejects("break IDs unique across vehicles") { _=try PlanChecks.prepare(q) }
        q=p; q.orders[0].mandatory=false;b=base;b.routes=[]
        check("omitted optional order remains visible",issues(q,b).contains { $0.contains("списке нераспределённых") })
        b.unassigned=[q.orders[0].id]
        check("optional unassigned order legitimate",issues(q,b).isEmpty)
        b=base;b.routes[0].steps[0].metersFromPrevious=100
        check("no unexplained travel before start",issues(p,b).contains { $0.contains("до начала") })
        b=base;b.routes[0].steps[0].kgAfter = .nan
        check("NaN cargo blocks economy",Economy.calculate(plan:p,variant:b).balance==nil)
        q=p; q.orders=[]
        for i in 0..<51 {var o=p.orders[0];o.id=UUID();o.number=String(i);q.orders.append(o)}
        rejects("maximum fifty operations") { _=try PlanChecks.prepare(q) }
        q=p; q.vehicles=[]
        for i in 0..<6 {var v=p.vehicles[0];v.id=UUID();v.name=String(i);q.vehicles.append(v)}
        rejects("maximum five vehicles") { _=try PlanChecks.prepare(q) }
        let record:[String:Any]=["checksPassed":passed.count,"checks":passed,"failures":failed,"scope":"Own model, times, independent schedule validation and Decimal economy; no live API or installed UI check"]
        let bytes=try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]); FileHandle.standardOutput.write(bytes); print()
        if !failed.isEmpty { exit(1) }
    }
}
