import SwiftUI
import AppKit
import MapKit

struct PlaceCandidate: Identifiable {
    var id:String
    var title:String
    var coordinate:GeoCoordinate
}

enum WorkspaceDisk {
    static var url:URL {
        FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("ANODHAS Freight Planner",isDirectory:true).appendingPathComponent("workspace-v1.json")
    }
    static func load() throws -> RouteWorkspace {
        guard FileManager.default.fileExists(atPath:url.path) else{return RouteWorkspace()}
        let size=(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size<=32_000_000 else{throw RouteFailure.invalid("Файл планов слишком велик. Сохранённые данные не изменены.")}
        let value=try JSONDecoder().decode(RouteWorkspace.self,from:Data(contentsOf:url))
        guard value.version==1,value.plans.count<=100,Set(value.plans.map(\.id)).count==value.plans.count else{throw RouteFailure.invalid("Неизвестная версия или повреждённый список планов. Исходный файл сохранён.")}
        return value
    }
    static func save(_ value:RouteWorkspace) throws {
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let bytes=try encoder.encode(value)
        guard bytes.count<=32_000_000 else{throw RouteFailure.invalid("Хранилище превысило 32 МБ. Экспортируйте старые планы перед добавлением новых.")}
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try bytes.write(to:url,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
    }
}

@MainActor final class RouteStore:ObservableObject {
    @Published private(set) var data=RouteWorkspace()
    @Published var busy=false
    @Published var progress=""
    @Published var error=""
    @Published var saved=""
    @Published var showImport=false
    private var task:Task<Void,Never>?
    private var loadFailed=false
    private var panel:NSOpenPanel?
    private var savePanel:NSSavePanel?
    var current:RoutePlan? {data.plans.first{$0.id==data.selected}}
    var shownVariant:PlanVariant? {current?.selected ?? current?.variants.last}
    init() {
        do {data=try WorkspaceDisk.load();if data.selected==nil {data.selected=data.plans.first?.id}}
        catch {self.error="Не удалось открыть сохранённые планы: \(error.localizedDescription). Исходный файл не перезаписывается.";loadFailed=true}
    }
    private func commit(_ value:RouteWorkspace) {
        guard !loadFailed else{error="Сначала восстановите исходный файл планов. Он сохранён без изменений.";return}
        do {try WorkspaceDisk.save(value);data=value;saved="Сохранено на этом Mac"}
        catch {self.error="Не удалось сохранить изменения: \(error.localizedDescription)"}
    }
    func createPlan() {
        guard !busy else{return}
        guard data.plans.count<100 else{error="Не более 100 планов. Экспортируйте и удалите ненужные.";return}
        var d=data;var plan=RoutePlan();plan.name="Новый план \(d.plans.count+1)";d.plans.append(plan);d.selected=plan.id;commit(d)
    }
    func selectPlan(_ id:UUID) {guard !busy,data.plans.contains(where:{$0.id==id}) else{return};var d=data;d.selected=id;commit(d)}
    func updatePlan(affectsRoute:Bool=true,_ edit:(inout RoutePlan)->Void) {
        guard !busy,let i=data.plans.firstIndex(where:{$0.id==data.selected}) else{return}
        var d=data;let old=d.plans[i];edit(&d.plans[i])
        guard old != d.plans[i] else{return}
        if affectsRoute {d.plans[i].revision+=1}
        commit(d)
    }
    func addVehicle() {guard (current?.vehicles.count ?? 0)<5 else{error="В одном плане не более 5 машин.";return};updatePlan{$0.vehicles.append(FleetVehicle())}}
    func addOrder() {guard (current?.operationCount ?? 0)<50 else{error="В одном плане не более 50 операций.";return};updatePlan{var o=DeliveryOrder();o.number=String($0.orders.count+1);$0.orders.append(o)}}
    func removeVehicle(_ id:UUID) {updatePlan{$0.vehicles.removeAll{$0.id==id};$0.manualOrder=[]}}
    func removeOrder(_ id:UUID) {updatePlan{$0.orders.removeAll{$0.id==id};$0.manualOrder=[]}}
    func deleteCurrent() {guard !busy,let id=data.selected else{return};var d=data;d.plans.removeAll{$0.id==id};d.selected=d.plans.first?.id;commit(d);if !data.plans.contains(where:{$0.id==id}){UserDefaults.standard.removeObject(forKey:"yandex.points."+id.uuidString)}}
    func updateSettings(_ edit:(inout ProviderSettings)->Void) {
        guard !busy else{return};var d=data;let old=d.settings;edit(&d.settings)
        if old.endpoint != d.settings.endpoint || old.avoidTolls != d.settings.avoidTolls || old.avoidUnpaved != d.settings.avoidUnpaved {
            for i in d.plans.indices {d.plans[i].revision+=1}
        }
        commit(d)
    }
    func calculate() {start(manual:false)}
    func calculateManual() {start(manual:true)}
    private func start(manual:Bool) {
        guard !busy,let plan=current else{return}
        do {_=try PlanChecks.prepare(plan)} catch {self.error=error.localizedDescription;return}
        let settings=data.settings
        if settings.provider == .community && !settings.publicNoticeAccepted {error="Откройте «Подключение» и подтвердите передачу координат открытому сервису.";return}
        let executable=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/vroom")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else{error="В установке отсутствует решатель маршрутов. Переустановите программу из полного образа.";return}
        busy=true;error="";progress="Проверяю план"
        let pipeline=RoutePipeline(settings:settings,executable:executable,progress:{[weak self] text in Task{@MainActor in self?.progress=text}})
        task=Task {
            do {
                let variant=try await pipeline.run(plan:plan,manual:manual)
                try Task.checkCancellation()
                guard let i=data.plans.firstIndex(where:{$0.id==plan.id}),data.plans[i].revision==plan.revision else{throw RouteFailure.invalid("План изменился; поздний ответ не применён.")}
                var d=data
                d.plans[i].variants.append(variant)
                if d.plans[i].variants.count>20 {
                    let selected=d.plans[i].selectedVariant
                    if let drop=d.plans[i].variants.firstIndex(where:{$0.id != selected && $0.id != variant.id}) {d.plans[i].variants.remove(at:drop)}
                }
                if d.plans[i].selectedVariant==nil {d.plans[i].selectedVariant=variant.id}
                commit(d)
                progress="Расчёт завершён"
            } catch is CancellationError {progress="Расчёт отменён; план сохранён"}
            catch {self.error=error.localizedDescription;progress="Расчёт не завершён; план сохранён"}
            busy=false;task=nil
        }
    }
    func cancel() {task?.cancel()}
    func acceptVariant(_ id:UUID) {
        guard current?.variants.contains(where:{$0.id==id}) == true else{return}
        updatePlan(affectsRoute:false){$0.selectedVariant=id}
    }
    func moveVisit(vehicleID:UUID,stepID:UUID,delta:Int) {
        guard let variant=shownVariant,let route=variant.routes.first(where:{$0.vehicleID==vehicleID}) else{return}
        var tokens=route.steps.filter{!$0.sourceToken.isEmpty && $0.kind != .start && $0.kind != .end}
        guard let i=tokens.firstIndex(where:{$0.id==stepID}),tokens.indices.contains(i+delta) else{return}
        tokens.swapAt(i,i+delta)
        var order:[String]=[]
        for r in variant.routes {let steps=r.vehicleID==vehicleID ? tokens : r.steps.filter{!$0.sourceToken.isEmpty && $0.kind != .start && $0.kind != .end};order += steps.map{r.vehicleID.uuidString+"|"+$0.sourceToken}}
        updatePlan{$0.manualOrder=order}
        saved="Порядок изменён. Нажмите «Пересчитать заданный порядок»."
    }
    func openPlan() {
        guard !busy else{return}
        let p=NSOpenPanel();p.allowsMultipleSelection=false;p.canChooseDirectories=false;p.allowedContentTypes=[.json];panel=p
        show(p) {[weak self] response in
            guard let self else{return};defer{self.panel=nil}
            guard response == .OK,let url=p.url else{return}
            let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
            do {
                let size=(try FileManager.default.attributesOfItem(atPath:url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size<=10_000_000,self.data.plans.count<100 else{throw RouteFailure.invalid("Файл больше 10 МБ или достигнут предел в 100 планов.")}
                let plan=try Transfer.decodePlan(Data(contentsOf:url));var d=self.data;d.plans.append(plan);d.selected=plan.id;self.commit(d)
            } catch {self.error="Не удалось открыть план: \(error.localizedDescription)"}
        }
    }
    func export(_ kind:ExportKind) {
        guard !busy,let plan=current else{return}
        let payload:Data,ext:String
        do {
            switch kind {
            case .projectJSON:payload=try Transfer.json(plan:plan);ext="json"
            case .summaryCSV:guard let v=shownVariant else{throw RouteFailure.invalid("Сначала рассчитайте маршрут.")};payload=try Transfer.csv(plan:plan,variant:v);ext="csv"
            case .itineraryPDF:guard let v=shownVariant else{throw RouteFailure.invalid("Сначала рассчитайте маршрут.")};payload=try Transfer.pdf(plan:plan,variant:v);ext="pdf"
            }
        } catch {self.error=error.localizedDescription;return}
        let p=NSSavePanel();p.nameFieldStringValue="Маршрут."+ext;p.canCreateDirectories=true;savePanel=p
        show(p){[weak self] response in
            guard let self else{return};defer{self.savePanel=nil}
            guard response == .OK,let url=p.url else{return}
            let access=url.startAccessingSecurityScopedResource();defer{if access{url.stopAccessingSecurityScopedResource()}}
            do {try payload.write(to:url,options:.atomic);self.saved="Экспорт сохранён: "+url.lastPathComponent}
            catch {self.error="Не удалось сохранить экспорт: \(error.localizedDescription)"}
        }
    }
    private func show(_ p:NSSavePanel,completion:@escaping(NSApplication.ModalResponse)->Void) {
        if let window=NSApp.keyWindow ?? NSApp.mainWindow {p.beginSheetModal(for:window,completionHandler:completion)} else{p.begin(completionHandler:completion)}
    }
    func geocode(query:String) async throws -> [PlaceCandidate] {
        let q=query.trimmingCharacters(in:.whitespacesAndNewlines)
        guard q.count>=3,q.count<=300 else{throw RouteFailure.invalid("Введите адрес от 3 до 300 символов.")}
        let request=MKLocalSearch.Request();request.naturalLanguageQuery=q
        let search=MKLocalSearch(request:request)
        let response=try await withTaskCancellationHandler(operation:{try await search.start()},onCancel:{search.cancel()})
        return response.mapItems.prefix(8).map { item in
            let c=item.placemark.coordinate
            return PlaceCandidate(id:"\(c.latitude),\(c.longitude)",title:item.placemark.title ?? item.name ?? q,coordinate:GeoCoordinate(latitude:c.latitude,longitude:c.longitude))
        }
    }
}
