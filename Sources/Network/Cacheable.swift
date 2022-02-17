import Foundation
import Debug
import Cache
import AnyCodable

public enum CachePolicy {
    case never
    
    /// A timed cache policy
    /// - Warning: Passing a timed policy with all values set to 0 is not allowed.
    case timed(days: Int = 0, hours: Int = 0, minutes: Int = 0)
    case forever
    
    func asExpiry() -> Expiry? {
        switch self {
        case .never:
            return nil
            
        case let .timed(days, hours, minutes):
            let daysToSeconds = days * 24 * 60 * 60
            let hoursToSeconds = hours * 60 * 60
            let minutesToSeconds = minutes * 60
            
            return .seconds(.init(daysToSeconds + hoursToSeconds + minutesToSeconds))
            
        case .forever:
            return .never
        }
    }
}

public protocol Cacheable {
    static var cachePolicy: CachePolicy { get }
}

public protocol CacheableResponse: RequestableResponse, Cacheable { }

extension Cacheable where Self: RequestableResponse {
    public static func fetch(given parameters: P, delegate: RequestDelegateConfig? = nil, with networkManager: NetworkManagerProvider = NetworkManager.shared) {
        fetch(given: parameters, delegate: delegate, with: networkManager, dataCallback: { _ in })
    }
    
    @discardableResult
    public static func observe(on object: AnyObject, given parameters: P, delegate: RequestDelegateConfig?, with networkManager: NetworkManagerProvider = NetworkManager.shared, observer: @escaping (_ data: Self) -> Void) -> ObserverToken {
        let request = Self.requestTask(given: parameters, delegate: delegate, dataCallback: { _ in })
                
        let token = networkManager.addObserver(for: request.id, on: object) { data in
            guard
                let value = data.value as? Self
            else {
                Debug.log(level: .error, "Type mismatch", params: ["Expected Type" : Self.self])
                return
            }
            
            DispatchQueue.main.async {
                observer(value)
            }
        }
        
        let isExpired = try? networkManager.isObjectExpired(for: request.id)
        if isExpired != false {
            networkManager.enqueue(request)
        }
        
        // Return any cached data.
        
        if
            let cachedData: Self = try? networkManager.get(object: request.id)
        {
            observer(cachedData)
        }
        else if
            let cachedData: [String: Any] = try? networkManager.get(object: request.id),
            let decodedData = DictionaryDecoder().decode(Self.self, from: cachedData)
        {
            observer(decodedData)
        }
        
        return token
    }
}

extension Cacheable where Self: RequestableResponse, Self.P == NoParameters {
    @discardableResult
    public static func observe(on object: AnyObject, delegate: RequestDelegateConfig?, observer: @escaping (_ data: Self) -> Void) -> ObserverToken {
        observe(on: object, given: .none, delegate: delegate, observer: observer)
    }
    
    public static func fetch(delegate: RequestDelegateConfig?, with networkManager: NetworkManagerProvider = NetworkManager.shared, force: Bool = false) {
        fetch(delegate: delegate, with: networkManager, force: force, dataCallback: { _ in })
    }
    
    public static func fetch(delegate: RequestDelegateConfig?, with networkManager: NetworkManagerProvider = NetworkManager.shared, force: Bool = false, dataCallback: @escaping (Self) -> Void) {
        let requestTask = Self.requestTask(given: .none, delegate: delegate, dataCallback: dataCallback)
        
        let isExpired = (try? networkManager.isObjectExpired(for: requestTask.id)) ?? true
        Debug.log("Is Expired: \(isExpired)")
        if isExpired || force {
            networkManager.enqueue(requestTask)
        }
    }
}
