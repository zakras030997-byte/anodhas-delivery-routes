import Foundation

@main struct RoadTests {
    static func main() throws {
        let p=try RoadClient.decodePolyline6("_p~iF~ps|U_ulLnnqC_mqNvxq`@")
        precondition(p.count==3 && abs(p[0].latitude-3.85)<0.000001 && abs(p[2].longitude+12.6453)<0.000001)
        for bad in ["!","~~~~~~~","?","????????????\n"] {
            do {_=try RoadClient.decodePolyline6(bad);throw NSError(domain:"AcceptedInvalidShape",code:1)}
            catch is RouteFailure {}
        }
        var v=FleetVehicle();v.heightM="2,4";v.widthM="2";v.lengthM="6";v.axleKg="2 000"
        let profile=RoadClient.profile(v,grossKg:3500,settings:ProviderSettings())
        precondition(profile["height"] as? Double==2.4 && profile["axle_load"] as? Double==2 && profile["weight"] as? Double==3.5)
        let key=RoadClient.fingerprint(v,grossKg:3500,settings:ProviderSettings())
        precondition(key != RoadClient.fingerprint(v,grossKg:2000,settings:ProviderSettings()))
        print("{\"checksPassed\":7,\"failures\":[]}")
    }
}
