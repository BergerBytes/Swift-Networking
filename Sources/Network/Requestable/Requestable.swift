//  Copyright © 2022 BergerBytes LLC. All rights reserved.
//
//  Permission to use, copy, modify, and/or distribute this software for any
//  purpose with or without fee is hereby granted, provided that the above
//  copyright notice and this permission notice appear in all copies.
//
//  THE SOFTWARE IS PROVIDED  AS IS AND THE AUTHOR DISCLAIMS ALL WARRANTIES
//  WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
//  MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY
//  SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
//  WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
//  ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR
//  IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

import Cache
import CryptoKit
import Debug
import Foundation

public protocol Requestable: Decodable {
    associatedtype P: NetworkParameters

    static var decoder: ResponseDecoder { get }

    static var queue: QueuePolicy { get }
    
    static var method: RequestMethod { get }

    /// The scheme subcomponent of the URL. Defaults to "https"
    ///
    /// The getter for this property removes any percent encoding this component may have (if the component allows percent encoding).
    /// Setting this property assumes the subcomponent or component string is not percent encoded and will add percent encoding (if the component allows percent encoding).
    /// Attempting to set the scheme with an invalid scheme string will cause an exception.
    static var scheme: String { get }

    /// The host subcomponent. Example: "www.apple.com"
    ///
    /// - Attention: Don't include any path separators.
    ///
    /// The getter for this property removes any percent encoding this component may have (if the component allows percent encoding).
    /// Setting this property assumes the subcomponent or component string is not percent encoded and will add percent encoding (if the component allows percent encoding).
    static var host: String { get }

    /// The port subcomponent.
    ///
    /// The getter for this property removes any percent encoding this component may have (if the component allows percent encoding).
    /// Setting this property assumes the subcomponent or component string is not percent encoded and will add percent encoding (if the component allows percent encoding).
    /// Attempting to set a negative port number will cause a fatal error.
    static var port: Int? { get }

    /// The path subcomponent.
    ///
    /// The getter for this property removes any percent encoding this component may have (if the component allows percent encoding).
    /// Setting this property assumes the subcomponent or component string is not percent encoded and will add percent encoding (if the component allows percent encoding).
    static func path(given parameters: P) -> URLPath?

    static func headers(given parameters: P) -> [String: String]?
    static func handle(response: URLResponse, data: Data?) -> Error?
    static func generateId(given parameters: P) -> String

    static func requestTask(given parameters: P, delegate: RequestDelegateConfig?, dataCallback: ((Self) -> Void)?, resultCallback: ((Result<Self, Error>) -> Void)?) -> QueueableTask
}

public extension Requestable {
    static var scheme: String { "https" }
    static var port: Int? { nil }
    static var decoder: ResponseDecoder { JSONDecoder() }
    static var queue: QueuePolicy { .single(queue: .default) }
    
    static func url(given parameters: P) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        components.path = path(given: parameters)?.pathString ?? ""

        guard let url = components.url else {
            fatalError("Failed to create valid URL. \(dump(components))")
        }

        return url
    }
}

public extension Requestable {
    static func headers(given _: P) -> [String: String]? { nil }

    static func fetch(given parameters: P, delegate: RequestDelegateConfig?, with networkManager: NetworkManagerProvider = NetworkManager.shared, dataCallback: @escaping (Self) -> Void) {
        networkManager.enqueue(Self.requestTask(given: parameters, delegate: delegate, dataCallback: dataCallback))
    }

    static func fetch(given parameters: P, with networkManager: NetworkManagerProvider = NetworkManager.shared) async throws -> Self {
        try await withCheckedThrowingContinuation { continuation in
            networkManager.enqueue(
                Self.requestTask(given: parameters) { [continuation] result in
                    switch result {
                    case let .success(response):
                        continuation.resume(returning: response)

                    case let .failure(error):
                        continuation.resume(throwing: error)
                    }
                }
            )
        }
    }

    /// Create a URLSessionNetworkTask for a request response.
    /// - Parameter parameters: The parameters for the network response.
    /// - Returns: A URL session task. (QueueableTask)
    static func requestTask(given parameters: P, delegate: RequestDelegateConfig?, dataCallback: ((Self) -> Void)?) -> QueueableTask {
        requestTask(given: parameters, delegate: delegate, dataCallback: dataCallback, resultCallback: nil)
    }

    static func requestTask(given parameters: P, callback: @escaping (Result<Self, Error>) -> Void) -> QueueableTask {
        requestTask(given: parameters, delegate: nil, dataCallback: nil, resultCallback: callback)
    }

    static func requestTask(given parameters: P, delegate: RequestDelegateConfig?, dataCallback: ((Self) -> Void)?, resultCallback: ((Result<Self, Error>) -> Void)?) -> QueueableTask {
        URLSessionNetworkTask(
            method: method,
            url: url(given: parameters),
            parameters: parameters,
            headers: headers(given: parameters),
            cachePolicy: (Self.self as? Cacheable.Type)?.cachePolicy,
            dataCallback: dataCallback,
            delegate: delegate,
            resultCallback: resultCallback
        )
    }

    static func generateId(given parameters: P) -> String {
        let urlString = url(given: parameters).absoluteString
        guard
            let encodedParameters = try? JSONEncoder().encode(parameters),
            let hash = try? SHA256.hash(data: JSONEncoder().encode([method.rawValue, urlString, String(decoding: encodedParameters, as: UTF8.self)]))
        else {
            Log.error(
                in: .network,
                "Failed to runtime agnostically hash a URLSessionNetworkTask id. Falling back to Hasher().",
                params: [
                    "Response Type": "\(Self.self)",
                    "Parameters Type": "\(P.self)",
                    "URL": "\(urlString)",
                    "method": method.rawValue,
                ]
            )

            var hasher = Hasher()
            hasher.combine(method)
            hasher.combine(urlString)
            hasher.combine(parameters)

            return "\(urlString) | \(hasher.finalize())"
        }

        let stringHash = hash.map { String(format: "%02hhx", $0) }.joined()
        return "\(urlString) | \(stringHash)"
    }
}

// MARK: - Requestable where P == NoParameters

public extension Requestable where P == NoParameters {
    /// Create a URLSessionNetworkTask for a request response without any parameter requirements.
    /// - Returns: The URL session task. (QueueableTask)
    static func requestTask(delegate: RequestDelegateConfig?, dataCallback: @escaping (_ data: Self) -> Void) -> QueueableTask {
        requestTask(given: .none, delegate: delegate, dataCallback: dataCallback)
    }

    static func fetch(delegate: RequestDelegateConfig?, with networkManager: NetworkManagerProvider = NetworkManager.shared, dataCallback: @escaping (Self) -> Void) {
        fetch(given: .none, delegate: delegate, with: networkManager, dataCallback: dataCallback)
    }

    static func fetch(with networkManager: NetworkManagerProvider = NetworkManager.shared) async throws -> Self {
        try await fetch(given: .none, with: networkManager)
    }
}

// MARK: - Requestable where P == EmptyInitializable

public extension Requestable where P: EmptyInitializable {
    /// Create a URLSessionNetworkTask for a request response without any parameter requirements.
    /// - Returns: The URL session task. (QueueableTask)
    static func requestTask(delegate: RequestDelegateConfig?, dataCallback: @escaping (_ data: Self) -> Void) -> QueueableTask {
        requestTask(given: .init(), delegate: delegate, dataCallback: dataCallback)
    }

    static func fetch(delegate: RequestDelegateConfig?, with networkManager: NetworkManagerProvider = NetworkManager.shared, dataCallback: @escaping (Self) -> Void) {
        fetch(given: .init(), delegate: delegate, with: networkManager, dataCallback: dataCallback)
    }

    static func fetch(with networkManager: NetworkManagerProvider = NetworkManager.shared) async throws -> Self {
        try await fetch(given: .init(), with: networkManager)
    }
}

public enum RequestMethod: String {
    case get = "GET"
    case head = "HEAD"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case trace = "TRACE"
    case options = "OPTIONS"
    case connect = "CONNECT"
    case patch = "PATCH"
}
