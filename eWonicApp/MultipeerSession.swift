import MultipeerConnectivity
import Combine
import os.log

private let SERVICE_TYPE = "ewonic-xlat"
private let mpq = DispatchQueue(label: "ewonic.multipeer", qos: .userInitiated)

private let osMajor = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
private let isIOS26Plus = osMajor >= 26

private let log = Logger(subsystem: "com.evansoasis.ewonic",
                         category: "multipeer")

// Add near top of file
enum Channel: Equatable {
  case peer, convention
  var serviceType: String {
    switch self {
    case .peer:       return "ewonic-peer"   // ≤ 15 chars; isolated from convention
    case .convention: return "ewonic-conv"
    }
  }
}

enum Role { case none, host, client }


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
    
    @Published private(set) var channel: Channel = .peer
    @Published private(set) var role: Role = .none
    private var serviceType: String { channel.serviceType }
    
  // ────────────────────────────── MC plumbing
    private let myPeerID = MultipeerSession.loadOrCreatePeerID()
    private var localLanguage: String

    // add a safe rebuild (must run on mpq)
    private func rebuildSessionOnMpq() {
      // tear down previous
      session.disconnect()
      let s = MCSession(
        peer: myPeerID,
        securityIdentity: nil,
        encryptionPreference: .optional
      )
      s.delegate = self
      session = s
    }
    

  private var advertiser: MCNearbyServiceAdvertiser
  private var browser   : MCNearbyServiceBrowser

  // ────────────────────────────── Callback
  var onMessageReceived: ((MessageData) -> Void)?
  let errorSubject = PassthroughSubject<String,Never>()

  // ────────────────────────────── Life‑cycle
    init(localLanguage: String, channel: Channel = .peer) {
      self.localLanguage = localLanguage
      self.channel = channel
      self.role = .none

      let st = channel.serviceType   // ← safe: not using self

      advertiser = MCNearbyServiceAdvertiser(
        peer: myPeerID,
        discoveryInfo: [
          "lang": localLanguage,
          "o26": isIOS26Plus ? "1" : "0"
        ],
        serviceType: st
      )

      browser = MCNearbyServiceBrowser(
        peer: myPeerID,
        serviceType: st
      )

      super.init()
      advertiser.delegate = self
      browser.delegate    = self
    }
    
    
  deinit { disconnect() }

    // session factory:
    private lazy var session: MCSession = {
      let s = MCSession(
        peer: myPeerID,
        securityIdentity: nil,
        encryptionPreference: .optional   // was .required
      )
      s.delegate = self
      return s
    }()

    // delegate:
    func session(_ session: MCSession,
                 didReceiveCertificate cert: [Any]?,
                 fromPeer peerID: MCPeerID,
                 certificateHandler: @escaping (Bool) -> Void) {
      certificateHandler(true)
    }
    
  /// Update the advertised discovery info with a new language code.
    func updateLocalLanguage(_ lang: String) {
      mpq.async { [self] in
        guard lang != localLanguage else { return }
        localLanguage = lang

        let wasAdvertising = isAdvertising
        advertiser.stopAdvertisingPeer()
        advertiser = MCNearbyServiceAdvertiser(
          peer: myPeerID,
          discoveryInfo: [
            "lang": lang,
            "o26": isIOS26Plus ? "1" : "0"
          ],
          serviceType: serviceType
        )
        advertiser.delegate = self
        if wasAdvertising { advertiser.startAdvertisingPeer() }
      }
    }
    
    func switchChannel(_ newChannel: Channel) {
      mpq.async { [self] in
        guard newChannel != channel else { return }
        disconnect()
        let st = newChannel.serviceType
        // rebuild advertiser/browser for new type
        advertiser = MCNearbyServiceAdvertiser(
          peer: myPeerID,
          discoveryInfo: ["lang": localLanguage, "o26": isIOS26Plus ? "1" : "0"],
          serviceType: st
        )
        advertiser.delegate = self
        browser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: st)
        browser.delegate = self
        rebuildSessionOnMpq()                           // ← new
        DispatchQueue.main.async {
          self.channel = newChannel
          self.role = .none
        }
      }
    }

  // ────────────────────────────── Host / Join
    // startHosting()
    func startHosting() {
      mpq.async { [self] in
        guard !isAdvertising else { return }
        rebuildSessionOnMpq()                           // ← new
        advertiser.startAdvertisingPeer()
        browser.stopBrowsingForPeers()            // host should not browse
        updateAdvertisingForCapacity()
        DispatchQueue.main.async {
          self.role = .host
          self.isAdvertising = true
          self.isBrowsing = false
        }
        log.debug("[Multipeer] Hosting (\(serviceType)) as \(self.myPeerID.displayName)")
      }
    }
    
    // startBrowsing()
    func startBrowsing() {
      mpq.async { [self] in
        guard !isBrowsing else { return }
        rebuildSessionOnMpq()                           // ← new
          advertiser.stopAdvertisingPeer()          // clients shouldn’t advertise
        browser.startBrowsingForPeers()
        DispatchQueue.main.async {
          self.role = .client
          self.isBrowsing = true
        }
        log.debug("[Multipeer] Browsing (\(serviceType))…")
      }
    }

    func disconnect() {
      mpq.async { [self] in
        session.disconnect()
        quiesceRadio()
        DispatchQueue.main.async {
          self.connectedPeers.removeAll()
          self.discoveredPeers.removeAll()
          self.connectionState = .notConnected
          self.role = .none
        }
        log.debug("[Multipeer] Disconnected")
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


  func stopBrowsing() {
    mpq.async { [self] in
      guard isBrowsing else { return }
      browser.stopBrowsingForPeers()
      DispatchQueue.main.async { self.isBrowsing = false }
      log.debug("[Multipeer] Stopped browsing")
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
          log.debug("📤 Sent \(bin.count) B (\(mode == .reliable ? "R" : "U"))")
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
                         timeout: 60)     // allow AWDL to finish spinning up
    }
  }
    
    private static func loadOrCreatePeerID() -> MCPeerID {
      let key = "ewonic.peerID.v1"
      if let data = UserDefaults.standard.data(forKey: key),
         let pid = try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data) {
        return pid
      }
      // short stable suffix (safe for App Store)
      let suffix = UIDevice.current.identifierForVendor?.uuidString.prefix(4) ?? "XXXX"
      let name   = "\(UIDevice.current.name)-\(suffix)"
      let pid    = MCPeerID(displayName: name)
      if let data = try? NSKeyedArchiver.archivedData(withRootObject: pid, requiringSecureCoding: true) {
        UserDefaults.standard.set(data, forKey: key)
      }
      return pid
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
      quiesceAfterConnect()
      updateAdvertisingForCapacity()
      log.debug("[Multipeer] \(id.displayName) CONNECTED (role=\(String(describing: role)))")
    }

  case .notConnected:
    DispatchQueue.main.async {
      self.connectedPeers.removeAll { $0 == id }
      self.peerLanguages.removeValue(forKey: id)
      self.connectionState = .notConnected
    }
    // If we’re host, stay (or go) advertising depending on capacity. If client, go back to browsing.
    updateAdvertisingForCapacity()
    if role == .client { startBrowsing() }
    log.debug("[Multipeer] \(id.displayName) DISCONNECTED")
      errorSubject.send(Localization.localized("Peer %@ disconnected", id.displayName))

    @unknown default: break
    }
  }
    
    private func quiesceAfterConnect() {
      switch role {
      case .host:
        // Keep advertising so new peers can discover us.
        browser.stopBrowsingForPeers()
        DispatchQueue.main.async { self.isBrowsing = false }
      case .client:
        // We’re connected; no more discovery needed on the client.
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        DispatchQueue.main.async {
          self.isAdvertising = false
          self.isBrowsing = false
        }
      case .none:
        break
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
    
    private func updateAdvertisingForCapacity() {
      guard role == .host else { return }
      let hasRoom = connectedPeers.count < MultipeerSession.peerLimit
      if hasRoom && !isAdvertising {
        advertiser.startAdvertisingPeer()
        DispatchQueue.main.async { self.isAdvertising = true }
//        log.debug("[Multipeer] Host advertising (room \(connectedPeers.count)/\(MultipeerSession.peerLimit))")
      } else if !hasRoom && isAdvertising {
        advertiser.stopAdvertisingPeer()
        DispatchQueue.main.async { self.isAdvertising = false }
        log.debug("[Multipeer] Host paused advertising (capacity reached)")
      }
    }

}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
  func browser(_: MCNearbyServiceBrowser,
               foundPeer id: MCPeerID,
               withDiscoveryInfo info: [String:String]?) {
    DispatchQueue.main.async {
      if let cap = info?["o26"] { self.peerOfflineCapable[id] = (cap == "1") } else { self.peerOfflineCapable[id] = false }
      if !self.discoveredPeers.contains(id) { self.discoveredPeers.append(id) }
      if let lang = info?["lang"] { self.peerLanguages[id] = lang }
    }
    log.debug("🟢 Found peer \(id.displayName)")
  }

  func browser(_: MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
    DispatchQueue.main.async {
      self.discoveredPeers.removeAll { $0 == id }
      self.peerLanguages.removeValue(forKey: id)
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
