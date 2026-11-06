import Foundation

protocol PipelineRoads: Sendable {
    func matrix(nodes:[GeoCoordinate], vehicle:FleetVehicle, grossKg:Double, progress:@escaping @Sendable (String)->Void) async throws -> MatrixSnapshot
    func route(from:GeoCoordinate, to:GeoCoordinate, vehicle:FleetVehicle, grossKg:Double, departure:Double?, timeZone:String) async throws -> RoadLeg
}
extension RoadClient: PipelineRoads {}

struct RoutePipeline {
    let settings: ProviderSettings
    let executable: URL
    let progress: @Sendable (String) -> Void
    var roadsOverride: (any PipelineRoads)? = nil

    func run(plan:RoutePlan, manual:Bool) async throws -> PlanVariant {
        let prepared=try PlanChecks.prepare(plan)
        if settings.provider == .community && !settings.publicNoticeAccepted { throw RouteFailure.invalid("В разделе «Подключение» подтвердите передачу координат и параметров машины открытому дорожному сервису.") }
        let roads: any PipelineRoads = roadsOverride ?? RoadClient(settings:settings)
        var variant:PlanVariant
        if manual {
            variant=manualSkeleton(prepared)
        } else {
            var nodes:[GeoCoordinate]=[]
            func add(_ c:GeoCoordinate?) { if let c,!nodes.contains(c) {nodes.append(c)} }
            for pv in prepared.vehicles {add(pv.vehicle.start.coordinate);if !pv.vehicle.openEnd {add((pv.vehicle.returnToStart ? pv.vehicle.start : pv.vehicle.end).coordinate)} }
            for visit in prepared.visits {add(visit.place.coordinate)}
            var matrices:[String:MatrixSnapshot]=[:], keys:[UUID:String]=[:]
            let totalKg=prepared.plan.orders.reduce(0.0){$0+RouteNumbers.double(RouteNumbers.parse($1.kg) ?? 0)}
            for pv in prepared.vehicles {
                let gross=RouteNumbers.double(RouteNumbers.parse(pv.vehicle.tareKg) ?? 0)+min(Double(pv.capacities[0])/1000,totalKg)
                let key=RoadClient.fingerprint(pv.vehicle,grossKg:gross,settings:settings)
                keys[pv.vehicle.id]=key
                if matrices[key] == nil { matrices[key]=try await roads.matrix(nodes:nodes,vehicle:pv.vehicle,grossKg:gross,progress:progress) }
            }
            progress("Подбираю машины и порядок остановок")
            variant=try await SolverAdapter.optimize(prepared:prepared,matrices:matrices,profileKeys:keys,nodes:nodes,executable:executable,timeoutSeconds:settings.timeoutSeconds)
            variant.matrices=matrices
        }
        variant.provider=settings.endpoint
        variant.name=manual ? "Заданный порядок" : "Подобранный маршрут"
        variant.issues=Array(Set(variant.issues+prepared.issues)).sorted()
        var checked:[PlannedRoute]=[]
        for route in variant.routes {
            guard let pv=prepared.vehicles.first(where:{$0.vehicle.id == route.vehicleID}) else {throw RouteFailure.invalid("Неизвестная машина в результате расчёта.")}
            checked.append(try await reflow(route,vehicle:pv,prepared:prepared,roads:roads))
        }
        variant.routes=checked;variant.verifiedRoads=true
        variant.issues=Array(Set(variant.issues+PlanChecks.validate(variant,for:plan))).sorted()
        return variant
    }

    private func manualSkeleton(_ p:PreparedPlan)->PlanVariant {
        let old=p.plan.selected ?? p.plan.variants.last
        var groups:[UUID:[PreparedVisit]]=[:]
        if !p.plan.manualOrder.isEmpty {
            for entry in p.plan.manualOrder {
                let parts=entry.split(separator:"|",maxSplits:1).map(String.init)
                if parts.count==2,let id=UUID(uuidString:parts[0]),p.vehicles.contains(where:{$0.vehicle.id==id}),let visit=p.visits.first(where:{$0.sourceToken==parts[1]}) {groups[id,default:[]].append(visit)}
            }
        } else if let old,old.revision == p.plan.revision {
            for route in old.routes {groups[route.vehicleID]=route.steps.compactMap{s in p.visits.first{$0.sourceToken==s.sourceToken}}}
        }
        let assigned=Set(groups.values.flatMap{$0}.map(\.sourceToken))
        if let first=p.vehicles.first {
            for visit in p.visits where !assigned.contains(visit.sourceToken) {
                let id=visit.vehicleID ?? first.vehicle.id
                if visit.kind == .rest {
                    let insertion=groups[id,default:[]].firstIndex { $0.earliest >= visit.earliest || $0.earliest + $0.service > visit.latestStart } ?? groups[id,default:[]].endIndex
                    groups[id,default:[]].insert(visit,at:insertion)
                } else { groups[id,default:[]].append(visit) }
            }
        }
        var routes:[PlannedRoute]=[]
        for pv in p.vehicles {
            let v=pv.vehicle,visits=groups[v.id] ?? []
            guard visits.contains(where:{$0.orderID != nil}) else {continue}
            var steps:[PlannedStep]=[step(kind:.start,title:v.name+" · старт",place:v.start)]
            for visit in visits {var s=step(kind:visit.kind,title:visit.title,place:visit.place);s.sourceToken=visit.sourceToken;s.orderID=visit.orderID;steps.append(s)}
            if !v.openEnd {steps.append(step(kind:.end,title:"Финиш",place:v.returnToStart ? v.start : v.end))}
            routes.append(PlannedRoute(vehicleID:v.id,vehicleName:v.name,departure:Double(pv.startSeconds),finish:Double(pv.startSeconds),steps:steps,meters:0,drivingSeconds:0))
        }
        return PlanVariant(name:"Заданный порядок",revision:p.plan.revision,provider:settings.endpoint,engine:"Заданный порядок · дорожный расчёт",goal:p.plan.goal,routes:routes)
    }
    private func step(kind:VisitKind,title:String,place:RoutePlace)->PlannedStep {
        PlannedStep(kind:kind,title:title,address:place.address,coordinate:place.coordinate,timeZone:place.timeZone,arrival:0,waitingSeconds:0,serviceSeconds:0,departure:0,kgAfter:0,m3After:0,palletsAfter:0,metersFromPrevious:0,drivingFromPrevious:0)
    }

    // Rebuild the timetable from roads for the actual loaded mass and departure.
    // Unlocated breaks are placed at a known stop before continuing; no invented road point
    // or proportionally interpolated road timing is presented as a confirmed route.
    private func reflow(_ raw:PlannedRoute,vehicle pv:PreparedVehicle,prepared p:PreparedPlan,roads:any PipelineRoads) async throws -> PlannedRoute {
        let v=pv.vehicle
        let byToken=Dictionary(uniqueKeysWithValues:p.visits.map{($0.sourceToken,$0)})
        let orders=Dictionary(uniqueKeysWithValues:p.plan.orders.map{($0.id,$0)})
        var load=raw.steps.filter{$0.kind == .delivery && $0.orderID.flatMap{orders[$0]?.mode} == .depot}.reduce([0,0,0]) {sum,s in
            guard let visit=byToken[s.sourceToken] else{return sum};return zip(sum,visit.amounts).map(+)
        }
        let loading=try PlanChecks.serviceSeconds(v.loadingMinutes,label:"Загрузка базы")
        guard raw.departure.isFinite, raw.departure >= 0, raw.departure <= Double(pv.endSeconds) else { throw RouteFailure.invalid("Некорректное начало дорожного маршрута.") }
        var current=max(Double(pv.startSeconds),raw.departure)
        var start=step(kind:.start,title:v.name+" · загрузка базы",place:v.start)
        start.arrival=current;start.serviceSeconds=Double(loading);current+=Double(loading);start.departure=current
        start.kgAfter=Double(load[0])/1000;start.m3After=Double(load[1])/1000;start.palletsAfter=load[2]
        var result=[start],shape:[GeoCoordinate]=[],issues=raw.issues
        var previous=v.start.coordinate!, previousZone=v.start.timeZone
        struct Pause { var source:DriverBreak; var earliest:Double; var latest:Double; var seconds:Double }
        var pending:[Pause]=[]
        for pause in v.breaks where !pause.hasPlace {
            let seconds=try PlanChecks.serviceSeconds(pause.minutes,label:pause.name)
            let w=try PlanChecks.window(pause.slot,place:v.start,service:seconds,label:pause.name)
            pending.append(Pause(source:pause,earliest:Double(w.0),latest:Double(w.1),seconds:Double(seconds)))
        }
        pending.sort { a,b in a.latest == b.latest ? a.earliest < b.earliest : a.latest < b.latest }
        func takeBreak(_ pause:Pause, meters:Double=0, driving:Double=0) {
            let wait=max(0,pause.earliest-current)
            let rest=PlannedStep(sourceToken:pause.source.id.uuidString+"#rest",kind:.rest,title:pause.source.name,address:"Остановка для отдыха",coordinate:nil,timeZone:previousZone,arrival:current,waitingSeconds:wait,serviceSeconds:pause.seconds,departure:current+wait+pause.seconds,kgAfter:Double(load[0])/1000,m3After:Double(load[1])/1000,palletsAfter:load[2],metersFromPrevious:meters,drivingFromPrevious:driving)
            result.append(rest);current=rest.departure
        }
        let targets=raw.steps.filter{$0.kind != .start && $0.coordinate != nil}
        for (index,target) in targets.enumerated() {
            try Task.checkCancellation()
            progress("Проверяю дорожный участок · \(v.name) · \(index+1) из \(targets.count)")
            guard let coordinate=target.coordinate else{continue}
            while let i=pending.firstIndex(where: { $0.earliest <= current }) {
                takeBreak(pending.remove(at:i))
            }
            let tare=RouteNumbers.double(RouteNumbers.parse(v.tareKg) ?? 0)
            var leg:RoadLeg
            while true {
                leg=try await roads.route(from:previous,to:coordinate,vehicle:v,grossKg:tare+max(0,Double(load[0])/1000),departure:current,timeZone:previousZone)
                guard leg.seconds.isFinite,leg.seconds>=0,leg.meters.isFinite,leg.meters>=0 else { throw RouteFailure.invalid("Дорожный сервис вернул некорректный пробег или время.") }
                // If reaching the next known stop would miss a break, rest before leaving
                // and obtain a fresh road ETA for the new departure, rather than add time to an old ETA.
                if let i=pending.firstIndex(where: { current+leg.seconds > $0.latest }) {
                    takeBreak(pending.remove(at:i));continue
                }
                break
            }
            shape += leg.shape;issues += leg.issues
            current += leg.seconds
            var meters=leg.meters, driving=leg.seconds
            let visit=byToken[target.sourceToken]
            if visit == nil && target.kind != .end { throw RouteFailure.invalid("Неизвестная остановка в дорожном результате.") }
            let earliest=Double(visit?.earliest ?? 0),service=Double(visit?.service ?? 0)
            while let i=pending.firstIndex(where: { $0.earliest <= max(current,earliest) || max(current,earliest)+service > $0.latest }) {
                takeBreak(pending.remove(at:i),meters:meters,driving:driving);meters=0;driving=0
            }
            var s=target;s.arrival=current;s.metersFromPrevious=meters;s.drivingFromPrevious=driving
            s.waitingSeconds=max(0,earliest-current);s.serviceSeconds=service
            if let visit {
                if s.kind == .pickup {load=zip(load,visit.amounts).map(+)}
                else if s.kind == .delivery {load=zip(load,visit.amounts).map(-)}
            }
            s.departure=s.arrival+s.waitingSeconds+s.serviceSeconds
            s.kgAfter=Double(load[0])/1000;s.m3After=Double(load[1])/1000;s.palletsAfter=load[2]
            result.append(s);current=s.departure;previous=coordinate;previousZone=s.timeZone
        }
        // Open routes have no final road leg on which to insert a break that became due
        // during the last service. Ended routes do not wait for a later, inapplicable break.
        if v.openEnd {
            while let i=pending.firstIndex(where: { $0.earliest < current }) {
                takeBreak(pending.remove(at:i))
            }
        }
        var route=raw;route.steps=result;route.departure=start.arrival;route.finish=current
        route.meters=result.reduce(0){$0+$1.metersFromPrevious};route.drivingSeconds=result.reduce(0){$0+$1.drivingFromPrevious}
        route.polyline=shape;route.issues=Array(Set(issues)).sorted()
        return route
    }
}
