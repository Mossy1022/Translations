import MultipeerConnectivity
import Combine
import os.log

private let SERVICE_TYPE = "ewonic-xlat"
private let mpq = DispatchQueue(label: "ewonic.multipeer", qos: .userInitiated)

private let log = Logger(subsystem: "com.evansoasis.ewonic",
                         category: "multipeer")

final class MultipeerSession: NSObject, ObservableObject {

  // ────────────────────────────── Public state
  static let peerLimit = 6

  @Published private(set) var connectedPeers  : [MCPeerID] = []
  @Published private(set) var discoveredPeers : [MCPeerID] = []
  @Published private(set) var connectionState : MCSessionState = .notConnected
  @Published private(set) var isAdvertising   = false
  @Published private(set) var isBrowsing      = false
  @Published              var receivedMessage : MessageData?

  // ────────────────────────────── MC plumbing
  private let myPeerID = MCPeerID(displayName: UIDevice.current.name)

  var localPeerID: MCPeerID { myPeerID }

  private lazy var session: MCSession = {
    let s = MCSession(
      peer:               myPeerID,
      securityIdentity:   nil,
      encryptionPreference: .optional    // was .required
    )
    s.delegate = self
    return s
  }()

  private lazy var advertiser = MCNearbyServiceAdvertiser(
    peer: myPeerID, discoveryInfo: nil, serviceType: SERVICE_TYPE)

  private lazy var browser = MCNearbyServiceBrowser(
    peer: myPeerID, serviceType: SERVICE_TYPE)

  // ────────────────────────────── Callback
  var onMessageReceived: ((MessageData) -> Void)?
  let errorSubject = PassthroughSubject<String,Never>()

  // ────────────────────────────── Life‑cycle
  override init() {
    super.init()
    advertiser.delegate = self
    browser.delegate    = self
  }
  deinit { disconnect() }

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
    
    // ────────────────────────────── Messaging
    func send(message: MessageData, reliable: Bool = true) {
      mpq.async { [self] in
        guard !session.connectedPeers.isEmpty else {
          let msg = "No connected peers – message not sent"
          log.debug("\(msg)")
          errorSubject.send(msg)
          return
        }
        guard let raw = try? JSONEncoder().encode(message),
              let bin = try? (raw as NSData).compressed(using: .zlib) as Data
        else {
          let msg = "Failed to encode/compress MessageData"
          log.error("\(msg)")
          errorSubject.send(msg)
          return
        }
        do {
          let mode: MCSessionSendDataMode = reliable ? .reliable : .unreliable
          try session.send(bin, toPeers: session.connectedPeers, with: mode)
          log.debug("📤 Sent \(bin.count) B (\(mode == .reliable ? "R" : "U"))")
        } catch {
          let msg = "session.send error: \(error.localizedDescription)"
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
      DispatchQueue.main.async {
        self.connectedPeers.removeAll()
        self.discoveredPeers.removeAll()
        self.connectionState = .notConnected
      }
      log.debug("[Multipeer] Disconnected")
    }
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
        self.connectionState = self.connectedPeers.isEmpty ? .notConnected : .connected
      }
      log.debug("[Multipeer] \(id.displayName) DISCONNECTED")
      errorSubject.send("Peer \(id.displayName) disconnected")
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
        let err = "Failed to decode message from \(id.displayName)"
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
      self.errorSubject.send("Advertiser error: \(error.localizedDescription)")
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
  func browser(_: MCNearbyServiceBrowser,
               foundPeer id: MCPeerID,
               withDiscoveryInfo _: [String:String]?) {
    DispatchQueue.main.async {
      if !self.discoveredPeers.contains(id) { self.discoveredPeers.append(id) }
    }
    log.debug("🟢 Found peer \(id.displayName)")
  }

  func browser(_: MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
    DispatchQueue.main.async { self.discoveredPeers.removeAll { $0 == id } }
    log.debug("🔴 Lost peer \(id.displayName)")
  }

  func browser(_: MCNearbyServiceBrowser,
               didNotStartBrowsingForPeers error: Error) {
    DispatchQueue.main.async {
      self.errorSubject.send("Browser error: \(error.localizedDescription)")
    }
  }
}
