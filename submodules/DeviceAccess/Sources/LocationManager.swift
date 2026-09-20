import Foundation
import CoreLocation

private func currentLocationAuthorizationStatus(_ manager: CLLocationManager) -> CLAuthorizationStatus {
    if #available(iOS 14.0, *) {
        return manager.authorizationStatus
    } else {
        return CLLocationManager.authorizationStatus()
    }
}

public final class LocationManager: NSObject, CLLocationManagerDelegate {
    public let manager = CLLocationManager()
    var pendingCompletion: ((CLAuthorizationStatus) -> Void, CLAuthorizationStatus)?
    
    public override init() {
        super.init()
        self.manager.delegate = self
    }
    
    func requestWhenInUseAuthorization(completion: @escaping (CLAuthorizationStatus) -> Void) {
        let status = currentLocationAuthorizationStatus(self.manager)
        if status == .notDetermined {
            self.manager.requestWhenInUseAuthorization()
            self.pendingCompletion = (completion, .authorizedWhenInUse)
        } else {
            completion(status)
        }
    }
    
    func requestAlwaysAuthorization(completion: @escaping (CLAuthorizationStatus) -> Void) {
        let status = currentLocationAuthorizationStatus(self.manager)
        if status == .notDetermined {
            self.manager.requestWhenInUseAuthorization()
            self.pendingCompletion = (completion, .authorizedAlways)
        } else {
            completion(status)
        }
    }
    
    public func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if let (pendingCompletion, _) = self.pendingCompletion {
            pendingCompletion(status)
            self.pendingCompletion = nil
        }
    }
}
