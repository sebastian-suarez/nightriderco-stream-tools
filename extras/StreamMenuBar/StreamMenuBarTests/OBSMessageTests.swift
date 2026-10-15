//
//  OBSMessageTests.swift
//  StreamMenuBarTests
//

import Foundation
import Testing
@testable import StreamMenuBar

struct OBSMessageTests {
    @Test func decodesHelloWithAndWithoutAuthentication() throws {
        let withAuth = #"{"d":{"authentication":{"challenge":"c","salt":"s"},"obsStudioVersion":"32.2.2","obsWebSocketVersion":"5.7.4","rpcVersion":1},"op":0}"#
        let hello = try JSONDecoder().decode(OBSMessage<OBSHello>.self, from: Data(withAuth.utf8))
        #expect(hello.op == 0)
        #expect(hello.d.rpcVersion == 1)
        #expect(hello.d.authentication?.challenge == "c")
        #expect(hello.d.authentication?.salt == "s")

        let open = try JSONDecoder().decode(OBSMessage<OBSHello>.self, from: Data(#"{"op":0,"d":{"rpcVersion":1}}"#.utf8))
        #expect(open.d.authentication == nil)
    }

    @Test func encodesIdentifyWithoutNullAuthentication() throws {
        let identify = OBSMessage(op: 1, d: OBSIdentify(rpcVersion: 1, authentication: nil, eventSubscriptions: 64))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(identify)) as? [String: Any]
        let d = json?["d"] as? [String: Any]
        #expect(json?["op"] as? Int == 1)
        #expect(d?["rpcVersion"] as? Int == 1)
        #expect(d?["eventSubscriptions"] as? Int == 64)
        #expect(d?["authentication"] == nil)
    }

    @Test func decodesStreamStatusResponseAsObsSendsIt() throws {
        let json = #"{"d":{"requestId":"r0","requestStatus":{"code":100,"result":true},"requestType":"GetStreamStatus","responseData":{"outputActive":true,"outputBytes":30949295196,"outputCongestion":0.0,"outputDuration":30600815,"outputReconnecting":false,"outputSkippedFrames":353,"outputTimecode":"08:30:00.815","outputTotalFrames":1836049}},"op":7}"#
        let response = try JSONDecoder().decode(OBSMessage<OBSRequestResponse<OBSStreamStatus>>.self, from: Data(json.utf8))
        #expect(response.d.requestStatus.result)
        #expect(response.d.requestStatus.code == 100)
        let status = try #require(response.d.responseData)
        #expect(status.outputActive)
        #expect(status.outputBytes == 30_949_295_196)
        #expect(status.outputDuration == 30_600_815)
        #expect(status.outputSkippedFrames == 353)

        let envelope = try JSONDecoder().decode(OBSEnvelope.self, from: Data(json.utf8))
        #expect(envelope.op == 7)
        #expect(envelope.d?.requestId == "r0")
    }

    @Test func decodesFailedRequestStatus() throws {
        let json = #"{"d":{"requestId":"x","requestStatus":{"code":204,"comment":"Your request type is not valid.","result":false},"requestType":"NoSuchRequest"},"op":7}"#
        let response = try JSONDecoder().decode(OBSMessage<OBSRequestResponse<OBSStreamStatus>>.self, from: Data(json.utf8))
        #expect(!response.d.requestStatus.result)
        #expect(response.d.requestStatus.comment == "Your request type is not valid.")
        #expect(response.d.responseData == nil)
    }

    @Test func authenticationFollowsTheProtocolSteps() {
        // The same two SHA-256 + base64 steps, written out independently of the implementation.
        let password = "hunter2", salt = "PZVbYpvAnZut2SS6JNJytDm9", challenge = "ztTBnnuqrqaKDzRM3xcVdbYm"
        let expected = FakeOBSServer.authentication(password: password, salt: salt, challenge: challenge)
        #expect(OBSAuthentication.response(password: password, salt: salt, challenge: challenge) == expected)
        #expect(OBSAuthentication.response(password: "other", salt: salt, challenge: challenge) != expected)
        #expect(expected.count == 44)
    }

    @Test func mapsCloseCodesAndTransportErrors() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: 57)
        #expect(OBSWebSocketClient.map(posix, closeCode: .init(rawValue: 4009)!) as? EncoderError == .authenticationFailed)
        #expect(OBSWebSocketClient.map(posix, closeCode: .invalid) as? EncoderError == .unavailable(posix.localizedDescription))
        let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost)
        #expect(OBSWebSocketClient.map(refused, closeCode: .invalid) as? EncoderError == .unavailable(refused.localizedDescription))
        #expect(OBSWebSocketClient.map(EncoderError.timedOut("x"), closeCode: .init(rawValue: 4009)!) as? EncoderError == .timedOut("x"))
        #expect(OBSWebSocketClient.map(CancellationError(), closeCode: .invalid) is CancellationError)
    }
}
