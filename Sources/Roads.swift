import Foundation
import CryptoKit

struct RoadLeg {
    var seconds: Double
    var meters: Double
    var shape: [GeoCoordinate]
    var issues: [String]
}
actor RoadThrottle {
    static let shared = RoadThrottle()
    private var next = Date.distantPast
    func acquire() async throws {
        let reservation = max(Date(),next)
        next = reservation.addingTimeInterval(1.15)
        let wait = reservation.timeIntervalSinceNow
        if wait > 0 { try await Task.sleep(nanoseconds:UInt64(wait * 1_000_000_000)) }
        try Task.checkCancellation()
    }
}
actor RoadClient {
    let settings: ProviderSettings
    private let session: URLSession
    private var legCache: [String:RoadLeg] = [:]
    init(settings: ProviderSettings) {
        self.settings = settings
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 35; c.timeoutIntervalForResource = 90
        c.httpCookieStorage = nil; c.urlCredentialStorage = nil; c.urlCache = nil
        session = URLSession(configuration:c)
    }
    static func value(_ s:String) -> Double { RouteNumbers.parse(s).map(RouteNumbers.double) ?? 0 }
    static func decodePolyline6(_ encoded:String) throws -> [GeoCoordinate] {
        let bytes=Array(encoded.utf8)
        var index=0,lat:Int64=0,lon:Int64=0,result:[GeoCoordinate]=[]
        func delta() throws -> Int64 {
            var value:Int64=0,shift:Int64=0
            while index<bytes.count {
                let byte=bytes[index];index+=1
                guard (63...126).contains(byte),shift<=55 else{throw RouteFailure.invalid("Повреждённая дорожная геометрия.")}
                let part=Int64(byte-63);value |= (part&31)<<shift
                if part<32 {return value&1 == 1 ? ~(value>>1) : value>>1}
                shift+=5
            }
            throw RouteFailure.invalid("Неполная дорожная геометрия.")
        }
        while index<bytes.count {
            let a=try delta(),b=try delta()
            let (nextLat,overLat)=lat.addingReportingOverflow(a), (nextLon,overLon)=lon.addingReportingOverflow(b)
            guard !overLat,!overLon,abs(nextLat)<=90_000_000,abs(nextLon)<=180_000_000,result.count<200_000 else{throw RouteFailure.invalid("Недопустимые координаты дорожной геометрии.")}
            lat=nextLat;lon=nextLon;result.append(GeoCoordinate(latitude:Double(lat)/1_000_000,longitude:Double(lon)/1_000_000))
        }
        return result
    }
    static func profile(_ v:FleetVehicle, grossKg:Double, settings:ProviderSettings) -> [String:Any] {
        var p:[String:Any] = ["height":value(v.heightM.replacingOccurrences(of:",",with:".")),"width":value(v.widthM.replacingOccurrences(of:",",with:".")),"length":value(v.lengthM.replacingOccurrences(of:",",with:".")),"weight":grossKg/1000,"axle_load":value(v.axleKg.replacingOccurrences(of:",",with:"."))/1000,"axle_count":Int(v.axleCount) ?? 2,"hazmat":false,"ignore_restrictions":false,"ignore_access":false,"ignore_oneways":false,"hgv_no_access_penalty":43200]
        if settings.avoidTolls { p["use_tolls"] = 0 }
        if settings.avoidUnpaved { p["exclude_unpaved"] = true }
        return p
    }
    static func fingerprint(_ v:FleetVehicle,grossKg:Double,settings:ProviderSettings) -> String {
        let p:[String:Any] = ["profile":profile(v,grossKg:grossKg,settings:settings),"endpoint":settings.endpoint,"shiftStart":v.shiftStart,"timeZone":v.start.timeZone]
        let d = (try? JSONSerialization.data(withJSONObject:p,options:.sortedKeys)) ?? Data()
        return SHA256.hash(data:d).map{String(format:"%02x",$0)}.joined()
    }
    private func request(_ path:String,_ payload:[String:Any]) async throws -> [String:Any] {
        guard let base=URL(string:settings.endpoint), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else { throw RouteFailure.invalid("Укажите адрес HTTPS-сервиса Valhalla без пароля и параметров в строке.") }
        let url=base.appendingPathComponent(path)
        let body=try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys)
        guard body.count <= 500_000 else { throw RouteFailure.invalid("Слишком большой дорожный запрос.") }
        for attempt in 0..<2 {
            try Task.checkCancellation(); try await RoadThrottle.shared.acquire()
            var req=URLRequest(url:url); req.httpMethod="POST";req.httpBody=body
            req.setValue("application/json",forHTTPHeaderField:"Content-Type")
            req.setValue("ANODHAS-FreightPlanner/1.0",forHTTPHeaderField:"User-Agent")
            req.setValue("ai.anodhas.freight-planner.local",forHTTPHeaderField:"X-Client-Id")
            do {
                let (data,response)=try await session.data(for:req)
                try Task.checkCancellation()
                guard let http=response as? HTTPURLResponse, data.count <= 8_000_000 else { throw RouteFailure.invalid("Дорожный сервис вернул слишком большой или неизвестный ответ.") }
                if [502,503,504].contains(http.statusCode), attempt == 0 { try await Task.sleep(nanoseconds:2_000_000_000);continue }
                if http.statusCode == 429 { throw RouteFailure.invalid("Лимит дорожного сервиса. Повторите расчёт позже; введённый план сохранён.") }
                let obj=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
                if !(200...299).contains(http.statusCode) || obj?["error"] != nil {
                    let message=obj?["error"] as? String ?? "Код ответа \(http.statusCode)"
                    if message.lowercased().contains("max distance") { throw RouteFailure.invalid("Дорожная матрица этого сервиса ограничена расстоянием 150 км. Для небольшого межгорода можно получить матрицу отдельными грузовыми маршрутами; для большого плана нужен свой сервис.") }
                    throw RouteFailure.invalid("Сервис не смог построить грузовой маршрут: \(String(message.prefix(180)))")
                }
                guard let obj else { throw RouteFailure.invalid("Дорожный сервис вернул неизвестный формат.") }
                return obj
            } catch let e as RouteFailure { throw e }
            catch is CancellationError { throw CancellationError() }
            catch {
                if Task.isCancelled { throw CancellationError() }
                if attempt == 0 { try await Task.sleep(nanoseconds:2_000_000_000);continue }
                throw RouteFailure.invalid("Нет ответа дорожного сервиса. Проверьте интернет и адрес подключения; план сохранён.")
            }
        }
        throw RouteFailure.invalid("Дорожный расчёт не завершён.")
    }
    func matrix(nodes:[GeoCoordinate], vehicle:FleetVehicle,grossKg:Double, progress:@escaping @Sendable (String)->Void) async throws -> MatrixSnapshot {
        let n=nodes.count
        guard n > 0, n <= 70 else { throw RouteFailure.invalid("Слишком много дорожных точек.") }
        var durations=Array(repeating:Array<Double?>(repeating:nil,count:n),count:n)
        var distances=durations
        let profile=Self.profile(vehicle,grossKg:grossKg,settings:settings)
        do {
            for a in stride(from:0,to:n,by:20) { for b in stride(from:0,to:n,by:20) {
                progress("Дорожная матрица · \(vehicle.name) · \(a+1)…\(min(n,a+20)) / \(b+1)…\(min(n,b+20))")
                let sources=Array(nodes[a..<min(n,a+20)]), targets=Array(nodes[b..<min(n,b+20)])
                let obj=try await request("sources_to_targets",["sources":sources.map{["lat":$0.latitude,"lon":$0.longitude]},"targets":targets.map{["lat":$0.latitude,"lon":$0.longitude]},"costing":"truck","costing_options":["truck":profile],"units":"kilometers"])
                guard obj["units"] as? String == "kilometers", let rows=obj["sources_to_targets"] as? [[[String:Any]]], rows.count == sources.count else { throw RouteFailure.invalid("Неизвестные единицы или размер дорожной матрицы.") }
                for i in rows.indices {
                    guard rows[i].count == targets.count else { throw RouteFailure.invalid("Неполная дорожная матрица.") }
                    for j in rows[i].indices {
                        let cell=rows[i][j]
                        if let sec=cell["time"] as? Double,let km=cell["distance"] as? Double, sec.isFinite,km.isFinite,sec>=0,km>=0 {durations[a+i][b+j]=sec;distances[a+i][b+j]=km*1000}
                    }
                }
            }}
        } catch {
            guard settings.provider == .community,n <= 8,error.localizedDescription.contains("150 км") else { throw error }
            for i in 0..<n {for j in 0..<n {
                try Task.checkCancellation()
                if i == j {durations[i][j]=0;distances[i][j]=0;continue}
                progress("Межгород: дорожная пара \(i+1) → \(j+1) из \(n) точек")
                let leg=try await route(from:nodes[i],to:nodes[j],vehicle:vehicle,grossKg:grossKg,departure:nil,timeZone:vehicle.start.timeZone)
                durations[i][j]=leg.seconds;distances[i][j]=leg.meters
            }}
        }
        guard durations.allSatisfy({$0.allSatisfy{$0 != nil}}), distances.allSatisfy({$0.allSatisfy{$0 != nil}}) else { throw RouteFailure.invalid("Для части точек нет грузового дорожного проезда. Уточните въезды и параметры машины.") }
        return MatrixSnapshot(provider:settings.endpoint,profileKey:Self.fingerprint(vehicle,grossKg:grossKg,settings:settings),nodes:nodes,durations:durations,distances:distances)
    }
    func route(from:GeoCoordinate,to:GeoCoordinate,vehicle:FleetVehicle,grossKg:Double,departure:Double?,timeZone:String) async throws -> RoadLeg {
        if from == to { return RoadLeg(seconds:0,meters:0,shape:[from],issues:[]) }
        let profile=Self.profile(vehicle,grossKg:grossKg,settings:settings)
        var payload:[String:Any] = ["locations":[["lat":from.latitude,"lon":from.longitude],["lat":to.latitude,"lon":to.longitude]],"costing":"truck","costing_options":["truck":profile],"units":"kilometers","directions_options":["language":"ru-RU"]]
        if let departure {
            let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(identifier:timeZone);f.dateFormat="yyyy-MM-dd'T'HH:mm"
            payload["date_time"]=["type":1,"value":f.string(from:Date(timeIntervalSince1970:departure))]
        }
        let key=String(data:try JSONSerialization.data(withJSONObject:payload,options:.sortedKeys),encoding:.utf8)!
        if let cached=legCache[key] {return cached}
        let obj=try await request("route",payload)
        guard let trip=obj["trip"] as? [String:Any],trip["units"] as? String == "kilometers", let status=trip["status"] as? Int,status==0, let summary=trip["summary"] as? [String:Any], let sec=summary["time"] as? Double,let km=summary["length"] as? Double,sec.isFinite,km.isFinite,sec>=0,km>=0,let legs=trip["legs"] as? [[String:Any]] else {throw RouteFailure.invalid("Нет подтверждённого грузового дорожного результата.")}
        var shape:[GeoCoordinate]=[]
        for leg in legs {
            if let encoded=leg["shape"] as? String {shape += try Self.decodePolyline6(encoded)}
            else if let geo=leg["shape"] as? [String:Any],let coords=geo["coordinates"] as? [[Double]] {
                shape += coords.compactMap { p in guard p.count>=2,p[0].isFinite,p[1].isFinite,(-180...180).contains(p[0]),(-90...90).contains(p[1]) else{return nil};return GeoCoordinate(latitude:p[1],longitude:p[0]) }
            }
        }
        guard shape.count>=2 else {throw RouteFailure.invalid("Дорожная геометрия отсутствует; прямая линия не подставляется.")}
        var issues:[String]=[]
        if settings.avoidTolls,summary["has_toll"] as? Bool == true {issues.append("В маршруте есть платные участки при выбранном запрете.")}
        if let warnings=obj["warnings"] as? [[String:Any]],!warnings.isEmpty {issues.append("Дорожный сервис вернул предупреждения; нужна проверка параметров.")}
        let result=RoadLeg(seconds:sec,meters:km*1000,shape:shape,issues:issues)
        legCache[key]=result;return result
    }
}
