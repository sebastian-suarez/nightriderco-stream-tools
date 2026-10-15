//
//  StubURLProtocol.swift
//  StreamMenuBarTests
//

import Foundation
import Synchronization

/// Serves canned responses so token and API calls can be tested without the network.
/// `handler` is global state: suites that set it must be `.serialized`.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (_ request: URLRequest, _ body: Data) throws -> (status: Int, body: Data)

    private static let handler = Mutex<Handler?>(nil)

    /// Replaces the handler. The previous one is released only after the lock is dropped: if it
    /// was the last reference to a suite instance, that instance's deinit calls back in here.
    static func install(_ handler: Handler?) {
        let previous = Self.handler.withLock { locked -> Handler? in
            let previous = locked
            locked = handler
            return previous
        }
        withExtendedLifetime(previous) {}
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, body) = try handler(request, Self.body(of: request))
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// URLSession hands protocols the body as a stream, not as `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// Collects strings from any thread.
final class Recorder: Sendable {
    private let storage = Mutex<[String]>([])

    func record(_ entry: String) {
        storage.withLock { $0.append(entry) }
    }

    var entries: [String] {
        storage.withLock { $0 }
    }
}
