import AppKit
import ApplicationServices
import Network
import AVFoundation

// Noise gate only: audio is reduced to RMS level, never retained or transcribed.
struct VoiceGate {
    var threshold: Double = -42
    var open = false
    var lastAbove = -Double.infinity
    mutating func sample(db: Double, time: Double) -> Double {
        guard db.isFinite, time.isFinite else { open=false; return 0 }
        if db >= threshold || (open && db >= threshold-5) {open=true;lastAbove=time}
        if time-lastAbove > 0.16 {open=false}
        return open ? min(1,max(0.15,(db-threshold+10)/30)) : 0
    }
    mutating func reset() {open=false;lastAbove = -Double.infinity}
    static func decibels(squareSum: Double, count: Int) -> Double {
        guard count>0, squareSum.isFinite, squareSum>0 else {return -90}
        return max(-90,min(0,10*log10(squareSum/Double(count))))
    }
}

// Only the current normalized pointer position and activity counters are kept.
// No window/app names, click targets, cursor trail, or screen content are read.
struct PointerState {
    var x: Double = 0.5
    var y: Double = 0.5
    var activity: UInt64 = 0
    var clicks: UInt64 = 0
    var buttons: UInt8 = 0
    var scrollCounter: UInt64 = 0
    var scrollX: Double = 0
    var scrollY: Double = 0
    mutating func scroll(dx:Double,dy:Double) {
        guard dx.isFinite,dy.isFinite,dx != 0 || dy != 0 else {return}
        scrollX=max(-1,min(1,dx));scrollY=max(-1,min(1,dy));scrollCounter &+= 1
    }
    static func normalized(_ point:CGPoint, in bounds:CGRect)->CGPoint {
        guard point.x.isFinite,point.y.isFinite,bounds.width>0,bounds.height>0 else {return CGPoint(x:0.5,y:0.5)}
        return CGPoint(x:max(0,min(1,(point.x-bounds.minX)/bounds.width)),y:max(0,min(1,(point.y-bounds.minY)/bounds.height)))
    }
    mutating func update(point:CGPoint,bounds:CGRect,button:UInt8=0,down:Bool?=nil) {
        let p=Self.normalized(point,in:bounds)
        x=(Double(p.x)*1000).rounded()/1000;y=(Double(p.y)*1000).rounded()/1000
        activity &+= 1
        if let down=down {
            if down {buttons |= button;clicks &+= 1} else {buttons &= ~button}
        }
    }
}

// The callback deliberately never reads key codes, Unicode, flags, or app names.
// Control state lives on the main queue; the audio callback computes a scalar only.
final class HuskyBridge: NSObject, NSApplicationDelegate {
    let port: UInt16 = {
        let args=CommandLine.arguments
        guard args.contains("--serve-only"),let i=args.firstIndex(of:"--port"),i+1<args.count else {return 8876}
        guard let value=UInt16(args[i+1]),value>=1024 else {fputs("Invalid test port\n",stderr);exit(2)}
        return value
    }()
    let session = UUID().uuidString
    var counter: UInt64 = 0
    var pointer = PointerState()
    var paused = false
    var tap: CFMachPort?
    var tapSource: CFRunLoopSource?
    var listener: NWListener?
    var statusItem: NSStatusItem?
    var statusMenu: NSMenuItem?
    var pauseMenu: NSMenuItem?
    var micMenu: NSMenuItem?
    var micStatusMenu: NSMenuItem?
    var sensitivityMenu: NSMenu?
    var audioEngine: AVAudioEngine?
    var audioObserver: NSObjectProtocol?
    var recoveryTimer: Timer?
    var lastAudioStart: Double = -Double.infinity
    var audioGeneration = UUID()
    var micWanted = UserDefaults.standard.bool(forKey:"voiceEnabled")
    var micPermissionPending = false
    var micStatus = "Microphone is off"
    var micDB: Double = -90
    var voiceLevel: Double = 0
    var audioAt: Double = -Double.infinity
    var gate = VoiceGate(threshold: UserDefaults.standard.object(forKey:"voiceThreshold") as? Double ?? -42)
    var files: [String: (Data, String)] = [:]
    var connections: [ObjectIdentifier: NWConnection] = [:]
    let serveOnly = CommandLine.arguments.contains("--serve-only")
    var listening: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } == true && !paused }
    var micListening: Bool {audioEngine?.isRunning == true && !paused}
    var audioFresh: Bool {micListening && ProcessInfo.processInfo.systemUptime-audioAt < 0.4}

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        createMenu()
        startServer()
        startMonitoring()
        audioObserver = NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:nil,queue:.main) { [weak self] note in
            guard let self=self, let engine=self.audioEngine, note.object as AnyObject? === engine else {return}
            self.stopMicrophone()
            // AVAudioEngine follows the current default input on a fresh start.
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) { [weak self] in self?.startMicrophone() }
        }
        if micWanted {startMicrophone()}
        // Permissions can change while the helper remains open. Retry without
        // prompting, and recover a stalled default-input engine after a device change.
        recoveryTimer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in
            guard let self=self,!self.paused else {return}
            if !self.listening {self.startMonitoring()}
            if self.micWanted {
                let now=ProcessInfo.processInfo.systemUptime
                if self.audioEngine != nil && !self.audioFresh && now-max(self.audioAt,self.lastAudioStart)>5 {
                    self.stopMicrophone()
                }
                self.startMicrophone()
            }
        }
    }

    func createMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "Husky Typist") {
            image.isTemplate = true
            item.button?.image = image
        } else { item.button?.title = "H" }
        item.button?.toolTip = "NIGHTRIDERCO Husky Typist"
        let menu = NSMenu()
        statusMenu = NSMenuItem(title: "Keyboard and mouse access is off", action: nil, keyEquivalent: "")
        menu.addItem(statusMenu!)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open preview & setup", action: #selector(openPreview), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Enable typing & mouse access", action: #selector(enableAccess), keyEquivalent: "").target = self
        menu.addItem(.separator())
        micStatusMenu=NSMenuItem(title:"Microphone is off",action:nil,keyEquivalent:"")
        menu.addItem(micStatusMenu!)
        micMenu=NSMenuItem(title:"Enable microphone",action:#selector(toggleMicrophone),keyEquivalent:"")
        micMenu?.target=self;menu.addItem(micMenu!)
        let sensitivity=NSMenuItem(title:"Voice sensitivity",action:nil,keyEquivalent:"")
        let choices=NSMenu()
        for (label,threshold) in [("High · quiet voice",-52),("Balanced",-42),("Low · noisy room",-32)] {
            let choice=NSMenuItem(title:label,action:#selector(setSensitivity(_:)),keyEquivalent:"")
            choice.tag=threshold;choice.target=self;choices.addItem(choice)
        }
        sensitivity.submenu=choices;sensitivityMenu=choices;menu.addItem(sensitivity)
        menu.addItem(.separator())
        pauseMenu = NSMenuItem(title: "Pause mascot", action: #selector(togglePause), keyEquivalent: "")
        pauseMenu?.target = self
        menu.addItem(pauseMenu!)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Husky Typist", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        statusItem = item
        updateStatus()
    }

    func updateStatus() {
        statusMenu?.title = paused ? "Paused · husky is resting" : (listening ? "Live · typing and pointer activity" : "Keyboard and mouse access is off")
        pauseMenu?.title = paused ? "Resume mascot" : "Pause mascot"
        micMenu?.title=micWanted ? "Turn microphone off" : "Enable microphone"
        micStatusMenu?.title=paused ? "Microphone paused" : micStatus
        for item in sensitivityMenu?.items ?? [] {item.state=Double(item.tag)==gate.threshold ? .on : .off}
    }

    @objc func openPreview() {
        NSWorkspace.shared.open(URL(string: "http://127.0.0.1:\(port)/preview.html")!)
    }

    @objc func enableAccess() {
        paused = false
        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
        }
        startMonitoring()
        if micWanted {startMicrophone()}
        if !listening {
            let alert = NSAlert()
            alert.messageText = "Allow Husky Typist to react to typing"
            alert.informativeText = "In System Settings → Privacy & Security → Input Monitoring, enable Husky Typist. If macOS asks, quit and reopen the app. The helper sends typing activity and a normalized mouse position to your local overlay. It does not read typed characters, screen content or click targets."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc func togglePause() {
        paused.toggle()
        if paused { pointer.buttons=0; if let tap = tap { CGEvent.tapEnable(tap: tap, enable: false) };stopMicrophone() }
        else { startMonitoring();if micWanted {startMicrophone()} }
        updateStatus()
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func setSensitivity(_ sender:NSMenuItem) {
        gate.threshold=Double(sender.tag);gate.reset();voiceLevel=0
        UserDefaults.standard.set(gate.threshold,forKey:"voiceThreshold")
        updateStatus()
    }

    @objc func toggleMicrophone() {
        if micWanted {
            micWanted=false;UserDefaults.standard.set(false,forKey:"voiceEnabled")
            stopMicrophone();return
        }
        micWanted=true;UserDefaults.standard.set(true,forKey:"voiceEnabled")
        paused=false;startMonitoring()
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized: startMicrophone()
        case .notDetermined:
            micStatus="Waiting for microphone permission";updateStatus()
            AVCaptureDevice.requestAccess(for:.audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self=self, self.micWanted else {return}
                    if granted {self.startMicrophone()} else {self.microphoneDenied()}
                }
            }
        default: microphoneDenied()
        }
    }

    func microphoneDenied() {
        stopMicrophone();micWanted=false;UserDefaults.standard.set(false,forKey:"voiceEnabled")
        micStatus="Microphone permission is off";updateStatus()
        let alert=NSAlert();alert.messageText="Allow microphone access for the wolf"
        alert.informativeText="In System Settings → Privacy & Security → Microphone, enable Husky Typist, then use Enable microphone again. Audio is processed on this Mac as a volume level only. It is not recorded, transcribed, played back, or sent to an external service."
        alert.addButton(withTitle:"Open Microphone settings");alert.addButton(withTitle:"Later")
        NSApp.activate(ignoringOtherApps:true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    func startMicrophone() {
        guard !serveOnly, micWanted, !paused, audioEngine == nil else {return}
        let authorization=AVCaptureDevice.authorizationStatus(for:.audio)
        if authorization == .notDetermined && !micPermissionPending {
            micPermissionPending=true
            AVCaptureDevice.requestAccess(for:.audio) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self=self else {return}
                    self.micPermissionPending=false
                    if AVCaptureDevice.authorizationStatus(for:.audio) == .authorized {self.startMicrophone()}
                }
            }
        }
        guard authorization == .authorized else {
            // Preserve the user's enabled setting while an app update's privacy
            // identity is refreshed. The recovery timer retries after permission returns.
            micStatus="Microphone permission needs attention";updateStatus();return
        }
        lastAudioStart=ProcessInfo.processInfo.systemUptime
        let engine=AVAudioEngine()
        let input=engine.inputNode
        let format=input.outputFormat(forBus:0)
        guard format.sampleRate>0, format.channelCount>0 else {
            micStatus="No default microphone · check Sound settings";updateStatus();return
        }
        audioGeneration=UUID();let generation=audioGeneration
        input.installTap(onBus:0,bufferSize:1024,format:nil) { [weak self] buffer,_ in
            guard let channels=buffer.floatChannelData,buffer.frameLength>0 else {return}
            let frames=Int(buffer.frameLength), count=Int(buffer.format.channelCount)
            var maxDB:Double = -90
            for channel in 0..<count {
                var squares:Double=0
                for frame in 0..<frames {let value=Double(channels[channel][frame]);squares+=value*value}
                maxDB=max(maxDB,VoiceGate.decibels(squareSum:squares,count:frames))
            }
            let db=maxDB
            // No PCM/audio buffer escapes this callback; only a numeric level does.
            DispatchQueue.main.async { [weak self] in
                guard let self=self,self.audioGeneration==generation,self.micListening else {return}
                self.audioAt=ProcessInfo.processInfo.systemUptime;self.micDB=db
                self.voiceLevel=self.gate.sample(db:db,time:self.audioAt)
            }
        }
        do {
            engine.prepare();try engine.start();audioEngine=engine
            micStatus="Mic active · Mac default input";updateStatus()
        } catch {
            input.removeTap(onBus:0);engine.stop()
            micStatus="Microphone unavailable · toggle off/on to retry";updateStatus()
        }
    }

    func stopMicrophone() {
        audioGeneration=UUID()
        if let engine=audioEngine {engine.stop();engine.inputNode.removeTap(onBus:0)}
        audioEngine=nil;micDB = -90;voiceLevel=0;audioAt = -Double.infinity;gate.reset()
        micStatus="Microphone is off";updateStatus()
    }

    func startMonitoring() {
        guard !serveOnly, !paused, CGPreflightListenEventAccess() else { updateStatus(); return }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: true)
            updateStatus()
            return
        }
        let eventTypes:[CGEventType]=[.keyDown,.mouseMoved,.leftMouseDragged,.rightMouseDragged,.otherMouseDragged,
            .leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.scrollWheel]
        let mask=eventTypes.reduce(CGEventMask(0)) {$0 | (CGEventMask(1) << $1.rawValue)}
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: { _, type, event, context in
                guard let context = context else { return Unmanaged.passUnretained(event) }
                let bridge = Unmanaged<HuskyBridge>.fromOpaque(context).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if !bridge.paused, let tap = bridge.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else if !bridge.paused {
                    if type == .keyDown {bridge.counter &+= 1}
                    else {bridge.trackPointer(event,type:type)}
                }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        if let tap = tap {
            tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        updateStatus()
    }

    func trackPointer(_ event:CGEvent,type:CGEventType) {
        let location=event.location
        var display=CGMainDisplayID();var count:UInt32=0
        _ = CGGetDisplaysWithPoint(location,1,&display,&count)
        let bounds=CGDisplayBounds(count>0 ? display : CGMainDisplayID())
        var button:UInt8=0;var down:Bool?=nil
        switch type {
        case .leftMouseDown:button=1;down=true
        case .leftMouseUp:button=1;down=false
        case .rightMouseDown:button=2;down=true
        case .rightMouseUp:button=2;down=false
        case .otherMouseDown:button=4;down=true
        case .otherMouseUp:button=4;down=false
        default:break
        }
        pointer.update(point:location,bounds:bounds,button:button,down:down)
        if type == .scrollWheel {
            var dx=Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            var dy=Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            if dx==0 {dx=event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)}
            if dy==0 {dy=event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)}
            pointer.scroll(dx:dx,dy:dy)
        }
    }

    func fail(_ message: String) {
        if serveOnly { fputs(message + "\n", stderr); exit(1) }
        let alert = NSAlert()
        alert.messageText = "Husky Typist could not start"
        alert.informativeText = message
        alert.addButton(withTitle: "Quit")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    func startServer() {
        // Keep artwork outside the signed helper so future animation-only updates
        // preserve its macOS privacy identity. Older packages still use the bundle.
        let external=Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("web")
        let externalExists=FileManager.default.fileExists(atPath:external.appendingPathComponent("mascot.js").path)
        guard let root = externalExists ? external : Bundle.main.resourceURL?.appendingPathComponent("web") else {
            fail("Keep the app bundle intact and open Husky Typist.app."); return
        }
        let types = ["overlay.html":"text/html; charset=utf-8", "preview.html":"text/html; charset=utf-8",
                     "mascot.js":"text/javascript; charset=utf-8", "husky-atlas.png":"image/png",
                     "keyboard-facing-wolf.png":"image/png", "wolf-speaking.png":"image/png"]
        for (name, mime) in types {
            guard let data = try? Data(contentsOf: root.appendingPathComponent(name)) else {
                fail("A bundled asset is missing: \(name). Extract the complete ZIP again."); return
            }
            files["/"+name] = (data,mime)
        }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let server = try NWListener(using: parameters)
            server.newConnectionHandler = { [weak self] connection in
                guard let self = self else { connection.cancel(); return }
                guard self.connections.count < 32 else {connection.cancel(); return}
                self.connections[ObjectIdentifier(connection)] = connection
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let connection = connection else {return}
                    switch state {case .cancelled, .failed: self?.connections.removeValue(forKey:ObjectIdentifier(connection));default: break}
                }
                connection.start(queue: .main)
                self.receive(connection, buffered: Data())
                DispatchQueue.main.asyncAfter(deadline: .now()+5) { [weak connection] in connection?.cancel() }
            }
            server.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if self.serveOnly { print("Husky helper ready on 127.0.0.1:\(self.port); keyboard and microphone disabled for testing") }
                    else { self.openPreview() }
                case .failed(let error):
                    self.fail("Port \(self.port) is unavailable. Quit any other Husky Typist instance or the app using this port, then reopen.\n\(error.localizedDescription)")
                default: break
                }
            }
            listener = server
            server.start(queue: .main)
        } catch { fail(error.localizedDescription) }
    }

    func receive(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self = self else { connection.cancel(); return }
            var buffer = buffered
            if let data = data { buffer.append(data) }
            if buffer.count > 8192 { connection.cancel(); return }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(connection, request: buffer)
            } else if complete || error != nil { connection.cancel() }
            else { self.receive(connection, buffered: buffer) }
        }
    }

    func respond(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8) else { connection.cancel(); return }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ").map(String.init)
        guard first.count == 3 else { connection.cancel(); return }
        var headers: [String:String] = [:]
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                headers[String(line[..<colon]).lowercased()] = String(line[line.index(after:colon)...]).trimmingCharacters(in:.whitespaces)
            }
        }
        let allowedHosts = ["127.0.0.1:\(port)","localhost:\(port)"]
        guard allowedHosts.contains(headers["host"] ?? "") else {
            send(connection, status: "403 Forbidden", body: Data("Local requests only".utf8), mime:"text/plain"); return
        }
        if let origin = headers["origin"], !allowedHosts.map({"http://"+$0}).contains(origin) {
            send(connection, status: "403 Forbidden", body: Data(), mime:"text/plain"); return
        }
        guard first[0] == "GET" || first[0] == "HEAD" else {
            send(connection, status: "405 Method Not Allowed", body: Data(), mime:"text/plain"); return
        }
        var path = String(first[1].split(separator:"?",maxSplits:1).first ?? "/")
        if path == "/" {path="/preview.html"}
        if path == "/state" {
            let state: [String:Any] = ["app":"nightriderco-husky", "session":session,
                "counter":counter, "listening":listening, "paused":paused,
                "typingPermission":CGPreflightListenEventAccess(),"version":"1.8",
                "mouseListening":listening,"mouseX":pointer.x,"mouseY":pointer.y,
                "mouseCounter":pointer.activity,"mouseClicks":pointer.clicks,"mouseDown":listening && pointer.buttons != 0,
                "scrollCounter":pointer.scrollCounter,"scrollX":pointer.scrollX,"scrollY":pointer.scrollY,
                "micListening":micListening,"micEnabled":micWanted && !serveOnly,
                "micStatus":serveOnly ? "Microphone disabled in test mode" : micStatus,
                "micDB":audioFresh ? micDB : -90,"voiceLevel":audioFresh ? voiceLevel : 0,
                "voiceThreshold":gate.threshold]
            let data = (try? JSONSerialization.data(withJSONObject:state,options:[.sortedKeys])) ?? Data()
            send(connection,status:"200 OK",body:data,mime:"application/json",head:first[0]=="HEAD")
        } else if let (data,mime) = files[path] {
            send(connection,status:"200 OK",body:data,mime:mime,head:first[0]=="HEAD")
        } else {send(connection,status:"404 Not Found",body:Data(),mime:"text/plain")}
    }

    func send(_ connection: NWConnection, status: String, body: Data, mime: String, head: Bool = false) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
        var data = Data(header.utf8)
        if !head {data.append(body)}
        connection.send(content:data,completion:.contentProcessed{_ in connection.cancel()})
    }

    func applicationWillTerminate(_ notification: Notification) {
        recoveryTimer?.invalidate()
        stopMicrophone()
        if let observer=audioObserver {NotificationCenter.default.removeObserver(observer)}
        if let tap = tap {CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap)}
        if let source = tapSource {CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes)}
        listener?.cancel()
        for connection in connections.values {connection.cancel()}
    }
}

if CommandLine.arguments.contains("--self-test") {
    var gate=VoiceGate()
    precondition(VoiceGate.decibels(squareSum:0,count:1024) == -90)
    precondition(abs(VoiceGate.decibels(squareSum:0.01,count:100)+40)<0.0001)
    precondition(gate.sample(db:-65,time:0)==0)
    precondition(gate.sample(db:-35,time:0.1)>0)
    precondition(gate.sample(db:-45,time:0.2)>0) // hysteresis avoids chatter
    precondition(gate.sample(db:-65,time:0.3)>0) // brief pause holds mouth
    precondition(gate.sample(db:-65,time:0.4)==0)
    precondition(gate.sample(db:Double.nan,time:0.5)==0)
    gate.threshold = -52;precondition(gate.sample(db:-48,time:0.6)>0)
    gate.reset();precondition(gate.sample(db:-65,time:0.7)==0)
    var pointer=PointerState()
    pointer.update(point:CGPoint(x:-300,y:100),bounds:CGRect(x:-600,y:0,width:600,height:400))
    precondition(pointer.x==0.5 && pointer.y==0.25 && pointer.activity==1 && pointer.clicks==0)
    pointer.update(point:CGPoint(x:1000,y:-100),bounds:CGRect(x:0,y:0,width:600,height:400),button:1,down:true)
    precondition(pointer.x==1 && pointer.y==0 && pointer.buttons==1 && pointer.clicks==1)
    pointer.update(point:CGPoint(x:300,y:200),bounds:CGRect(x:0,y:0,width:600,height:400),button:2,down:true)
    precondition(pointer.buttons==3 && pointer.clicks==2)
    pointer.update(point:CGPoint(x:300,y:200),bounds:CGRect(x:0,y:0,width:600,height:400),button:1,down:false)
    precondition(pointer.buttons==2 && pointer.clicks==2)
    pointer.update(point:CGPoint(x:300,y:200),bounds:CGRect(x:0,y:0,width:600,height:400),button:2,down:false)
    precondition(pointer.buttons==0)
    precondition(PointerState.normalized(.zero,in:.zero)==CGPoint(x:0.5,y:0.5))
    pointer.scroll(dx:0,dy:0);precondition(pointer.scrollCounter==0)
    pointer.scroll(dx:0,dy:14);precondition(pointer.scrollCounter==1 && pointer.scrollY==1 && pointer.clicks==2)
    pointer.scroll(dx:-4,dy:-0.5);precondition(pointer.scrollCounter==2 && pointer.scrollX == -1 && pointer.scrollY == -0.5)
    pointer.scroll(dx:Double.nan,dy:1);precondition(pointer.scrollCounter==2)
    print("PASS: scroll direction and counters; voice gate; pointer normalization, multiple displays, clamping, clicks and button releases. No microphone or input capture opened.")
    exit(0)
}
let bridge = HuskyBridge()
if bridge.serveOnly {
    bridge.startServer()
    RunLoop.main.run()
} else {
    let application = NSApplication.shared
    application.delegate = bridge
    application.run()
}
