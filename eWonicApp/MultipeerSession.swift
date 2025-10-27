import MultipeerConnectivity
import Combine
import os.log

private let SERVICE_TYPE = "ewonic-xlat"
private let mpq = DispatchQueue(label: "ewonic.multipeer", qos: .userInitiated)

private let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
private let isIOS26Plus = osMajor >= 26

private let log = Logger(subsystem: "com.evansoasis.ewonic",
                         category: "multipeer")

enum WireMode: String { case peer, convention } // internal (default)


final class MultipeerSession: NSObject, ObservableObject {

  // ────────────────────────────── Public state
  static let peerLimit = 6

  @Published private(set) var connectedPeers  : [MCPeerID] = []
  @Published private(set) var discoveredPeers : [MCPeerID] = []
  @Published private(set) var peerLanguages   : [MCPeerID:String] = [:]
  @Published private(set) var connectionState : MCSessionState = .notConnected
  @Published private(set) var isAdvertising   = false
  @Published private(set) var isBrowsing      = false
  @Published              var receivedMessage : MessageData?

  @Published private(set) var peerOfflineCapable: [MCPeerID: Bool] = [:]
    
@Published var wireMode: WireMode = .peer              // what this device is advertising
@Published var isHost: Bool = false                    // host (true) vs listener (false) in Convention

@Published private(set) var peerModes : [MCPeerID:String] = [:]   // "peer" | "convention"
@Published private(set) var peerRoles : [MCPeerID:String] = [:]   // "host" | "listener"
    
  // ────────────────────────────── MC plumbing
  private let myPeerID = MCPeerID(displayName: UIDevice.current.name)
  private var localLanguage: String

    
  private var session: MCSession

  private func makeSession() -> MCSession {
    let s = MCSession(
      peer:               myPeerID,
      securityIdentity:   nil,
      encryptionPreference: .optional    // was .required
    )
    s.delegate = self
    return s
  }

  private var advertiser: MCNearbyServiceAdvertiser
  private var browser   : MCNearbyServiceBrowser

  // ────────────────────────────── Callback
  var onMessageReceived: ((MessageData) -> Void)?
  let errorSubject = PassthroughSubject<String,Never>()

  // ────────────────────────────── Life‑cycle
  init(localLanguage: String) {
    self.localLanguage = localLanguage

      // ✅ Build discoveryInfo without using `self`
       let initialInfo: [String:String] = [
         "lang": localLanguage,
         "o26":  isIOS26Plus ? "1" : "0",
         "mode": WireMode.peer.rawValue,
         "role": "peer"
       ]


      self.advertiser = MCNearbyServiceAdvertiser(
         peer: myPeerID,
         discoveryInfo: initialInfo,
         serviceType: SERVICE_TYPE
       )

    self.browser = MCNearbyServiceBrowser(
      peer: myPeerID,
      serviceType: SERVICE_TYPE)

    // Initialize session
    self.session = MCSession(
      peer: myPeerID,
      securityIdentity: nil,
      encryptionPreference: .optional
    )

    super.init()
    session.delegate = self
    advertiser.delegate = self
    browser.delegate    = self
  }
  deinit { disconnect() }

  /// Update the advertised discovery info with a new language code.
    func updateLocalLanguage(_ lang: String) {
      mpq.async { [self] in
        guard lang != localLanguage else { return }
        localLanguage = lang

        let wasAdvertising = isAdvertising
        advertiser.stopAdvertisingPeer()

        advertiser = MCNearbyServiceAdvertiser(
          peer: myPeerID,
          discoveryInfo: makeDiscoveryInfo(),
          serviceType: SERVICE_TYPE
        )
        advertiser.delegate = self
        if wasAdvertising { advertiser.startAdvertisingPeer() }
      }
    }

  // ────────────────────────────── Host / Join
  func startHosting() {
    mpq.async { [self] in
      guard !isAdvertising else { return }
      advertiser.startAdvertisingPeer()
      DispatchQueue.main.async { self.isAdvertising = true }
      log.debug("[Multipeer] Hosting as \(self.myPeerID.displayName)")
    }
  }

  func stopHosting() {
    mpq.async { [self] in
      guard isAdvertising else { return }
      advertiser.stopAdvertisingPeer()
      DispatchQueue.main.async { self.isAdvertising = false }
      log.debug("[Multipeer] Stopped hosting")
    }
  }

  func startBrowsing() {
    mpq.async { [self] in
      guard !isBrowsing else { return }
      browser.startBrowsingForPeers()
      DispatchQueue.main.async { self.isBrowsing = true }
      log.debug("[Multipeer] Browsing for peers…")
    }
  }

  func stopBrowsing() {
    mpq.async { [self] in
      guard isBrowsing else { return }
      browser.stopBrowsingForPeers()
      DispatchQueue.main.async { self.isBrowsing = false }
      log.debug("[Multipeer] Stopped browsing")
    }
  }
    
    func updateMode(_ mode: String, isHost: Bool) {
      mpq.async { [self] in
        guard let newMode = WireMode(rawValue: mode) else { return }
        let modeChanged = (newMode != wireMode) || (self.isHost != isHost)
        guard modeChanged else { return }

        wireMode = newMode
        self.isHost = isHost

        let wasAdvertising = isAdvertising
        advertiser.stopAdvertisingPeer()
        advertiser = MCNearbyServiceAdvertiser(
          peer: myPeerID,
          discoveryInfo: makeDiscoveryInfo(),
          serviceType: SERVICE_TYPE
        )
        advertiser.delegate = self
        if wasAdvertising { advertiser.startAdvertisingPeer() }
      }
    }
    
    // ────────────────────────────── Messaging
    func send(message: MessageData, reliable: Bool = true) {
      mpq.async { [self] in
        guard !session.connectedPeers.isEmpty else {
          let msg = Localization.localized("No connected peers – message not sent")
          log.debug("\(msg)")
          errorSubject.send(msg)
          return
        }
        guard let raw = try? JSONEncoder().encode(message),
              let bin = try? (raw as NSData).compressed(using: .zlib) as Data
        else {
          let msg = Localization.localized("Failed to encode/compress MessageData")
          log.error("\(msg)")
          errorSubject.send(msg)
          return
        }
        do {
          let mode: MCSessionSendDataMode = reliable ? .reliable : .unreliable
            try session.send(bin, toPeers: session.connectedPeers, with: mode)
            let turnStr = message.turnId?.uuidString.prefix(8) ?? "--"
            let seqStr  = message.seq.map(String.init) ?? "-"
            log.debug("📤 Sent \(bin.count)B (\(mode == .reliable ? "R" : "U")) turn=\(turnStr) seq=\(seqStr) final=\(message.isFinal)")
        } catch {
          let msg = Localization.localized("session.send error: %@", error.localizedDescription)
          log.error("\(msg)")
          errorSubject.send(msg)
        }
      }
    }

  /// Invite a specific peer.
  /// *No* quiesce here – keep discovery sockets up until we are connected.
  func invitePeer(_ id: MCPeerID) {
    mpq.async { [self] in
      browser.invitePeer(id,
                         to: session,
                         withContext: nil,
                         timeout: 30)     // allow AWDL to finish spinning up
    }
  }

  func disconnect() {
    mpq.async { [self] in
      session.disconnect()
      quiesceRadio()

      // Create a fresh session to avoid "Connection invalid" errors
      session = makeSession()

      DispatchQueue.main.async {
        self.connectedPeers.removeAll()
        self.discoveredPeers.removeAll()
        self.connectionState = .notConnected
      }
      log.debug("[Multipeer] Disconnected")
    }
  }
    
    private func makeDiscoveryInfo() -> [String:String] {
      [
        "lang": localLanguage,
        "o26":  isIOS26Plus ? "1" : "0",
        "mode": wireMode.rawValue,
        "role": (wireMode == .convention ? (isHost ? "host" : "listener") : "peer")
      ]
    }

}

// ────────────────────────────── MCSessionDelegate
extension MultipeerSession: MCSessionDelegate {

  func session(_ s: MCSession, peer id: MCPeerID, didChange state: MCSessionState) {
    switch state {

    case .connected:
      mpq.async { [self] in
        DispatchQueue.main.async {
          if !self.connectedPeers.contains(id) { self.connectedPeers.append(id) }
          self.connectionState = .connected
        }
        log.debug("[Multipeer] \(id.displayName) CONNECTED")
      }

    case .connecting:
      DispatchQueue.main.async { self.connectionState = .connecting }
      log.debug("[Multipeer] \(id.displayName) CONNECTING…")

    case .notConnected:
      DispatchQueue.main.async {
        self.connectedPeers.removeAll { $0 == id }
        self.peerLanguages.removeValue(forKey: id)
        self.connectionState = .notConnected
      }
      log.debug("[Multipeer] \(id.displayName) DISCONNECTED")
      errorSubject.send(Localization.localized("Peer %@ disconnected", id.displayName))
      if connectedPeers.isEmpty { startBrowsing() }

    @unknown default: break
    }
  }

  func session(_: MCSession, didReceive data: Data, fromPeer id: MCPeerID) {
    mpq.async { [self] in
      guard
        let raw = try? (data as NSData).decompressed(using: .zlib) as Data,
        let msg = try? JSONDecoder().decode(MessageData.self, from: raw)
      else {
        let err = Localization.localized("Failed to decode message from %@", id.displayName)
        log.error("\(err)")
        errorSubject.send(err)
        return
      }
      DispatchQueue.main.async {
        self.receivedMessage = msg
        self.onMessageReceived?(msg)
          let turnStr = msg.turnId?.uuidString.prefix(8) ?? "--"
          let seqStr  = msg.seq.map(String.init) ?? "-"
          log.debug("📥 Rx turn=\(turnStr) seq=\(seqStr) final=\(msg.isFinal) ts=\(Int(msg.timestamp))")

      }
    }
  }

  func session(_: MCSession, didReceive _: InputStream, withName _: String, fromPeer _: MCPeerID) {}
  func session(_: MCSession, didStartReceivingResourceWithName _: String, fromPeer _: MCPeerID, with _: Progress) {}
  func session(_: MCSession, didFinishReceivingResourceWithName _: String, fromPeer _: MCPeerID, at _: URL?, withError _: Error?) {}
}

// ────────────────────────────── Advertiser / Browser
extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {

  func advertiser(_: MCNearbyServiceAdvertiser,
                  didReceiveInvitationFromPeer id: MCPeerID,
                  withContext _: Data?,
                  invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    let accept = connectedPeers.count < MultipeerSession.peerLimit
    invitationHandler(accept, accept ? session : nil)
  }

  func advertiser(_: MCNearbyServiceAdvertiser,
                  didNotStartAdvertisingPeer error: Error) {
    DispatchQueue.main.async {
      self.errorSubject.send(Localization.localized("Advertiser error: %@", error.localizedDescription))
    }
  }

  /// Stop discovery radios once a session is fully established.
  private func quiesceRadio() {
    advertiser.stopAdvertisingPeer()
    browser.stopBrowsingForPeers()
    DispatchQueue.main.async {
      self.isAdvertising = false
      self.isBrowsing    = false
    }
  }
}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    func browser(_ : MCNearbyServiceBrowser,
                 foundPeer id: MCPeerID,
                 withDiscoveryInfo info: [String:String]?) {
      DispatchQueue.main.async {
        if let cap = info?["o26"] { self.peerOfflineCapable[id] = (cap == "1") } else { self.peerOfflineCapable[id] = false }
        if !self.discoveredPeers.contains(id) { self.discoveredPeers.append(id) }
        if let lang = info?["lang"]  { self.peerLanguages[id] = lang }
        if let mode = info?["mode"]  { self.peerModes[id]     = mode }            // "peer" | "convention"
        if let role = info?["role"]  { self.peerRoles[id]     = role }            // "host" | "listener" | "peer"
      }
      log.debug("🟢 Found peer \(id.displayName)")
    }

    func browser(_ : MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
      DispatchQueue.main.async {
        self.discoveredPeers.removeAll { $0 == id }
        self.peerLanguages.removeValue(forKey: id)
        self.peerModes.removeValue(forKey: id)
        self.peerRoles.removeValue(forKey: id)
      }
      log.debug("🔴 Lost peer \(id.displayName)")
    }

  func browser(_: MCNearbyServiceBrowser,
               didNotStartBrowsingForPeers error: Error) {
    DispatchQueue.main.async {
      self.errorSubject.send(Localization.localized("Browser error: %@", error.localizedDescription))
    }
  }
}
