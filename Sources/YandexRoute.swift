import Foundation

enum YandexRoute {
    static let maximumStops=10
    static func clean(_ points:[String]) throws -> [String] {
        guard (2...maximumStops).contains(points.count) else{throw RouteFailure.invalid("Укажите от 2 до 10 точек маршрута.")}
        return try points.enumerated().map {i,text in
            let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
            guard !value.isEmpty,value.count<=300,!value.contains("~"),value.rangeOfCharacter(from:.controlCharacters)==nil else{throw RouteFailure.invalid("Точка \(i+1): введите адрес или координаты, не более 300 символов, без переноса строки и знака ~.")}
            return value
        }
    }
    static func url(points:[String],widget:Bool) throws -> URL {
        let points=try clean(points)
        var c=URLComponents();c.scheme="https";c.host="yandex.ru";c.path=widget ? "/map-widget/v1/" : "/maps/"
        c.queryItems=[URLQueryItem(name:"mode",value:"routes"),URLQueryItem(name:"rtext",value:points.joined(separator:"~")),URLQueryItem(name:"rtt",value:"auto"),URLQueryItem(name:"lang",value:"ru_RU")]
        guard let u=c.url else{throw RouteFailure.invalid("Не удалось подготовить маршрут для Яндекс.Карт.")};return u
    }
    static func allowed(_ url:URL)->Bool {
        guard url.scheme=="https",url.user==nil,url.password==nil,let host=url.host?.lowercased() else{return false}
        return ["yandex.ru","yandex.kz","yandex.com"].contains{host==$0 || host.hasSuffix("."+$0)}
    }
    static func routePoints(_ url:URL)->[String]? {
        guard allowed(url),let text=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="rtext"})?.value else{return nil}
        return try? clean(text.components(separatedBy:"~"))
    }
    static func place(_ p:RoutePlace)->String {
        if p.confirmed,let c=p.coordinate {return "\(c.latitude),\(c.longitude)"}
        return p.address
    }
}
