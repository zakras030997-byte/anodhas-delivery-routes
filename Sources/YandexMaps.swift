import SwiftUI
import WebKit
import AppKit
import OSLog

struct YandexStop:Identifiable {var id=UUID();var text:String}

@MainActor final class YandexMapController:NSObject,ObservableObject,WKNavigationDelegate,WKUIDelegate {
    @Published var loading=false
    @Published var problem=""
    @Published var isEditor=false
    @Published var currentPoints:[String]=[]
    let webView:WKWebView
    private var observation:NSKeyValueObservation?
    override init() {
        let configuration=WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView=WKWebView(frame:.zero,configuration:configuration)
        super.init()
        webView.navigationDelegate=self;webView.uiDelegate=self
        webView.allowsBackForwardNavigationGestures=false
        observation=webView.observe(\.url,options:[.new]){[weak self] view,_ in
            Task{@MainActor in
                guard let self,let url=view.url else{return}
                self.isEditor=url.path.hasPrefix("/maps")
                if let points=YandexRoute.routePoints(url) {self.currentPoints=points}
            }
        }
    }
    func load(points:[String],widget:Bool) throws {
        Logger(subsystem:"ai.anodhas.freight-planner",category:"Yandex").notice("Open route widget=\(widget)")
        let url=try YandexRoute.url(points:points,widget:widget)
        currentPoints=try YandexRoute.clean(points);isEditor = !widget;problem="";loading=true
        webView.stopLoading()
        webView.load(URLRequest(url:url))
    }
    func retry() {problem="";loading=true;webView.reload()}
    func webView(_ webView:WKWebView,didStartProvisionalNavigation navigation:WKNavigation!) {loading=true;problem=""}
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {loading=false}
    func webView(_ webView:WKWebView,didFail navigation:WKNavigation!,withError error:Error) {failure(error)}
    func webView(_ webView:WKWebView,didFailProvisionalNavigation navigation:WKNavigation!,withError error:Error) {failure(error)}
    private func failure(_ error:Error) {
        let e=error as NSError
        if e.code==NSURLErrorCancelled || (e.domain=="WebKitErrorDomain" && e.code==102){return}
        Logger(subsystem:"ai.anodhas.freight-planner",category:"Yandex").error("Navigation failed domain=\(e.domain,privacy:.public) code=\(e.code)")
        loading=false;problem="Яндекс.Карты не загрузились. Проверьте интернет и повторите открытие. Введённые точки сохранены."
    }
    func webViewWebContentProcessDidTerminate(_ webView:WKWebView) {loading=false;problem="Окно карты было закрыто системой. Нажмите «Повторить»."}
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        // Keep the provider's own embedded content, notices and ads intact.
        // The host restriction applies to the main browsing surface, not its subframes.
        if navigationAction.targetFrame?.isMainFrame==false {decisionHandler(.allow);return}
        guard let url=navigationAction.request.url else{decisionHandler(.cancel);return}
        if url.absoluteString=="about:blank" {decisionHandler(.allow);return}
        guard YandexRoute.allowed(url) else{decisionHandler(.cancel);return}
        if url.path.hasPrefix("/maps"),navigationAction.navigationType == .linkActivated {
            NSWorkspace.shared.open(url);decisionHandler(.cancel);return
        }
        Logger(subsystem:"ai.anodhas.freight-planner",category:"Yandex").notice("Allowed main navigation widget=\(url.path.hasPrefix("/map-widget")) newWindow=\(navigationAction.targetFrame==nil)")
        // Popup requests are handled once by WKUIDelegate. Starting another load
        // and cancelling this policy callback can cancel the replacement navigation.
        decisionHandler(.allow)
    }
    func webView(_ webView:WKWebView,createWebViewWith configuration:WKWebViewConfiguration,for navigationAction:WKNavigationAction,windowFeatures:WKWindowFeatures)->WKWebView? {
        if let url=navigationAction.request.url,YandexRoute.allowed(url){NSWorkspace.shared.open(url)}
        return nil
    }
}
struct YandexWebView:NSViewRepresentable {
    let controller:YandexMapController
    func makeNSView(context:Context)->WKWebView {controller.webView}
    func updateNSView(_ nsView:WKWebView,context:Context) {}
    static func dismantleNSView(_ nsView:WKWebView,coordinator:()) {nsView.stopLoading()}
}

struct YandexMapsPane:View {
    @ObservedObject var store:RouteStore
    @StateObject private var map=YandexMapController()
    @State private var stops:[YandexStop]
    @State private var opened=false
    @State private var problem=""
    @State private var sourceVehicle:UUID?
    private let planID:UUID
    init(store:RouteStore,planID:UUID) {
        self.store=store;self.planID=planID
        let values=UserDefaults.standard.stringArray(forKey:"yandex.points."+planID.uuidString) ?? ["",""]
        _stops=State(initialValue:((2...10).contains(values.count) ? values : ["",""]).map{YandexStop(text:$0)})
    }
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("Маршрут в Яндекс.Картах").font(.headline)
                Spacer()
                if let routes=store.shownVariant?.routes,!routes.isEmpty {
                    Picker("Рейс плана",selection:$sourceVehicle){ForEach(routes){r in Text(r.vehicleName).tag(Optional(r.vehicleID))}}
                        .frame(maxWidth:260)
                }
                Button("Взять точки из плана"){fromPlan()}
            }
            ScrollView {
                VStack(spacing:7) {
                    ForEach(Array(stops.enumerated()),id:\.element.id){i,stop in
                        HStack(spacing:8) {
                            Text(i==0 ? "Откуда" : (i==stops.count-1 ? "Куда" : "Заехать \(i)")).frame(width:72,alignment:.leading)
                            TextField("Адрес с городом или широта,долгота",text:Binding(get:{stops.first{$0.id==stop.id}?.text ?? ""},set:{text in if let j=stops.firstIndex(where:{$0.id==stop.id}){stops[j].text=text;saveDraft()}}))
                                .textFieldStyle(.roundedBorder).accessibilityLabel(i==0 ? "Откуда в Яндексе" : (i==stops.count-1 ? "Куда в Яндексе" : "Промежуточная точка \(i)"))
                            if i>0 && i<stops.count-1 {Button{stops.removeAll{$0.id==stop.id};saveDraft()}label:{Image(systemName:"minus.circle")}.help("Убрать остановку")}
                        }
                    }
                }
            }.frame(maxHeight:min(200,CGFloat(stops.count)*36))
            HStack {
                Button("Добавить остановку"){stops.insert(YandexStop(text:""),at:stops.count-1);saveDraft()}.disabled(stops.count>=YandexRoute.maximumStops)
                Button("Поменять направление"){stops.reverse();saveDraft()}
                Button("Построить маршрут"){build(widget:true)}.buttonStyle(.borderedProminent)
                if map.loading {ProgressView().controlSize(.small);Text("Загружаю Яндекс…").font(.caption)}
            }
            if opened {
                HStack {
                    Button("Открыть в Яндекс.Картах"){if let u=try? YandexRoute.url(points:map.currentPoints,widget:false){NSWorkspace.shared.open(u)}}
                }
            }
            if !problem.isEmpty {Text(problem).foregroundStyle(.orange).textSelection(.enabled)}
            if !map.problem.isEmpty {HStack{Text(map.problem).foregroundStyle(.orange);Button("Повторить"){map.retry()}}}
            if opened {YandexWebView(controller:map).frame(minHeight:280).clipShape(RoundedRectangle(cornerRadius:8))}
            else {
                VStack(spacing:12) {
                    Image(systemName:"map").font(.system(size:40)).foregroundStyle(.secondary)
                    Text("Укажите адреса и нажмите «Построить маршрут»").font(.title3)
                    Text("Яндекс покажет дорогу, расстояние, время и пробки. Можно добавить до 8 промежуточных остановок.").foregroundStyle(.secondary)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            Text("Адреса отправляются в Яндекс после нажатия кнопки. Виджет показывает автомобильный маршрут. Дополнительные и грузовые параметры доступны на сайте Яндекс.Карт в браузере. Километры и время виджета пока не переносятся в расчёт расходов.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func saveDraft(){UserDefaults.standard.set(stops.map(\.text),forKey:"yandex.points."+planID.uuidString)}
    private func build(widget:Bool) {
        do {try map.load(points:stops.map(\.text),widget:widget);opened=true;problem="";saveDraft()}
        catch {problem=error.localizedDescription}
    }
    private func fromPlan() {
        guard let p=store.current else{return}
        var points:[String]=[]
        if let routes=store.shownVariant?.routes,let route=routes.first(where:{$0.vehicleID==sourceVehicle}) ?? routes.first {
            for step in route.steps where step.coordinate != nil {
                let c=step.coordinate!;let text="\(c.latitude),\(c.longitude)"
                if points.last != text {points.append(text)}
            }
        } else {
            if let v=p.vehicles.first {points.append(YandexRoute.place(v.start))}
            for order in p.orders {
                if order.mode == .shipment {points.append(YandexRoute.place(order.pickup))}
                points.append(YandexRoute.place(order.delivery))
            }
            if let v=p.vehicles.first,!v.openEnd {points.append(YandexRoute.place(v.returnToStart ? v.start : v.end))}
        }
        do {let clean=try YandexRoute.clean(points);stops=clean.map{YandexStop(text:$0)};saveDraft();problem=""}
        catch {problem="Не удалось взять точки: \(error.localizedDescription) Можно заполнить маршрут вручную."}
    }
}
