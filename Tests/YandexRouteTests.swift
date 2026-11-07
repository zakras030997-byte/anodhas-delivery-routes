import Foundation
@main struct YandexRouteTests {
    static func main() throws {
        var passed=0
        func check(_ condition:Bool){passed+=1; if !condition {FileHandle.standardError.write(Data("Failed check \(passed)\n".utf8));exit(1)}}
        let points=["Санкт-Петербург, Дворцовая площадь","Санкт-Петербург, Лиговский проспект, 50"]
        let widget=try YandexRoute.url(points:points,widget:true)
        check(widget.host=="yandex.ru" && URLComponents(url:widget,resolvingAgainstBaseURL:false)?.path=="/map-widget/v1/")
        check(YandexRoute.routePoints(widget)==points)
        let route=try YandexRoute.url(points:["59.9386,30.3141","59.9253,30.3593"],widget:false)
        check(URLComponents(url:route,resolvingAgainstBaseURL:false)?.path=="/maps/" && YandexRoute.routePoints(route)?.first=="59.9386,30.3141")
        let escaped=try YandexRoute.url(points:["Адрес &rtt=mt?foo#bar","Другой адрес"],widget:true)
        check(URLComponents(url:escaped,resolvingAgainstBaseURL:false)?.queryItems?.filter{$0.name=="rtt"}.map(\.value)==["auto"])
        check(YandexRoute.routePoints(escaped)?.first=="Адрес &rtt=mt?foo#bar")
        for bad in [["","Москва"],["Одна"],Array(repeating:"Москва",count:11),["Москва~Казань","Тверь"],["Точка\nВторая","Москва"]] {
            do{_=try YandexRoute.url(points:bad,widget:true);preconditionFailure("Accepted invalid route")}catch is RouteFailure{passed+=1}
        }
        for bad in ["http://yandex.ru/maps/","https://yandex.ru.evil.example/maps/","https://example.com/maps/","https://user:password@yandex.ru/maps/"] {check(!YandexRoute.allowed(URL(string:bad)!))}
        check(YandexRoute.allowed(URL(string:"https://yandex.kz/maps/")!))
        check(YandexRoute.allowed(URL(string:"https://passport.yandex.ru/")!))
        check(try YandexRoute.clean(Array(repeating:"Москва",count:10)).count==10)
        print("{\"checksPassed\":\(passed),\"failures\":[]}")
    }
}
