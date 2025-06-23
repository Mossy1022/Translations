import MultipeerConnectivity
import Combine

// 10-char ASCII (a–z 0–9 -)
private let SERVICE_TYPE = "ewonic-xlat"

final class MultipeerSession: NSObject, ObservableObject {

  // ────────────────────────────── Public state
  static let peerLimit = 6

  @Published private(set) var connectedPeers:   [MCPeerID] = []
  @Published private(set) var discoveredPeers:  [MCPeerID] = []
  @Published private(set) var connectionState:  MCSessionState = .notConnected
  @Published private(set) var isAdvertising = false
  @Published private(set) var isBrowsing    = false
  @Published              var receivedMessage: MessageData?

  // ────────────────────────────── MC plumbing
  private let myPeerID = MCPeerID(displayName: UIDevice.current.name)

  private lazy var session: MCSession = {
    let s = MCSession(peer: myPeerID,
                      securityIdentity: nil,
                      encryptionPreference: .required)
    s.delegate = self
    return s
  }()

  private lazy var advertiser = MCNearbyServiceAdvertiser(
    peer: myPeerID, discoveryInfo: nil, serviceType: SERVICE_TYPE)

  private lazy var browser = MCNearbyServiceBrowser(
    peer: myPeerID, serviceType: SERVICE_TYPE)

  // ────────────────────────────── Callback to VM
  var onMessageReceived: ((MessageData) -> Void)?

  // Error messages for UI
  let errorSubject = PassthroughSubject<String,Never>()

  // ────────────────────────────── Life-cycle
  override init() {
    super.init()
    advertiser.delegate = self
    browser.delegate    = self
  }
  deinit { disconnect() }

  // ────────────────────────────── Host / Join
  func startHosting() {
    stopBrowsing()
    guard !isAdvertising else { return }
    discoveredPeers.removeAll()
    advertiser.startAdvertisingPeer()
    isAdvertising = true
    print("[Multipeer] Hosting as \(myPeerID.displayName)")
  }

  func stopHosting() {
    guard isAdvertising else { return }
    advertiser.stopAdvertisingPeer()
    isAdvertising = false
    print("[Multipeer] Stopped hosting")
  }

  func startBrowsing() {
    stopHosting()
    guard !isBrowsing else { return }
    discoveredPeers.removeAll()
    browser.startBrowsingForPeers()
    isBrowsing = true
    print("[Multipeer] Browsing for peers…")
  }

  func stopBrowsing() {
    guard isBrowsing else { return }
    browser.stopBrowsingForPeers()
    isBrowsing = false
    print("[Multipeer] Stopped browsing")
  }

  // ────────────────────────────── Messaging
  /// Sends *message* to all connected peers.
  /// - Non-final “live” updates use **unreliable** UDP to avoid back-pressure.
  /// - Final chunks & control messages use **reliable** TCP.
  func send(message: MessageData, reliable: Bool = true) {
    guard !session.connectedPeers.isEmpty else {
      print("⚠️ No connected peers – message not sent")
      return
    }
    guard let data = try? JSONEncoder().encode(message) else {
      print("❌ Failed to encode MessageData")
      return
    }
    do {
      let bin = try (data as NSData).compressed(using: .zlib) as Data
     try session.send(bin, toPeers: session.connectedPeers, with: .reliable)
      print("📤 Sent \(bin.count) bytes (\(reliable ? "R" : "U")) → \(session.connectedPeers.map { $0.displayName })")
    } catch {
      let msg = "session.send error: \(error.localizedDescription)"
      print("❌ \(msg)")
      errorSubject.send(msg)
    }
  }

  func invitePeer(_ id: MCPeerID) {
    browser.invitePeer(id, to: session, withContext: nil, timeout: 30)
  }

  func disconnect() {
    session.disconnect()
    connectedPeers.removeAll()
    discoveredPeers.removeAll()
    connectionState = .notConnected
    stopHosting(); stopBrowsing()
    print("[Multipeer] Disconnected")
  }
}

// ────────────────────────────── MCSessionDelegate
extension MultipeerSession: MCSessionDelegate {

  func session(_ s: MCSession, peer id: MCPeerID, didChange state: MCSessionState) {
    DispatchQueue.main.async { [self] in
      connectionState = state
      switch state {
      case .connected:
        if !connectedPeers.contains(id) { connectedPeers.append(id) }
        stopHosting(); stopBrowsing()
        print("[Multipeer] \(id.displayName) CONNECTED")

      case .connecting:
        print("[Multipeer] \(id.displayName) CONNECTING…")

      case .notConnected:
        connectedPeers.removeAll { $0 == id }
        print("[Multipeer] \(id.displayName) DISCONNECTED")
        errorSubject.send("Lost connection to \(id.displayName)")

        /// 🔄  Auto-recover: resume browsing so user can tap “Join” again quickly.
        if !isBrowsing && connectedPeers.isEmpty { startBrowsing() }

      @unknown default: break
      }
    }
  }

  func session(_ s: MCSession, didReceive data: Data, fromPeer id: MCPeerID) {
    print("📨 Received \(data.count) bytes from \(id.displayName)")
    guard
      let raw   = try? (data as NSData).decompressed(using: .zlib) as Data,
      let msg   = try? JSONDecoder().decode(MessageData.self, from: raw)
    else {
      print("❌ Could not decode MessageData")
      return
    }
    DispatchQueue.main.async {
      self.receivedMessage = msg
      self.onMessageReceived?(msg)
    }
  }

  // unused
  func session(_:MCSession, didReceive _:InputStream, withName _:String, fromPeer _:MCPeerID) {}
  func session(_:MCSession, didStartReceivingResourceWithName _:String, fromPeer _:MCPeerID, with _:Progress) {}
  func session(_:MCSession, didFinishReceivingResourceWithName _:String, fromPeer _:MCPeerID, at _:URL?, withError _:Error?) {}
}

// ────────────────────────────── Advertiser / Browser
extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {
  func advertiser(_:MCNearbyServiceAdvertiser,
                  didReceiveInvitationFromPeer id: MCPeerID,
                  withContext _:Data?,
                  invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    let accept = connectedPeers.count < MultipeerSession.peerLimit
    invitationHandler(accept, accept ? session : nil)
  }
  func advertiser(_:MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
    let msg = "Advertiser error: \(error.localizedDescription)"
    print(msg)
    errorSubject.send(msg)
  }
}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
  func browser(_:MCNearbyServiceBrowser, foundPeer id: MCPeerID, withDiscoveryInfo _: [String:String]?) {
    DispatchQueue.main.async {
      if !self.discoveredPeers.contains(id) { self.discoveredPeers.append(id) }
      print("🟢 Found peer \(id.displayName)")
    }
  }
  func browser(_:MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
    DispatchQueue.main.async { self.discoveredPeers.removeAll { $0 == id } }
    print("🔴 Lost peer \(id.displayName)")
  }
  func browser(_:MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    let msg = "Browser error: \(error.localizedDescription)"
    print(msg)
    errorSubject.send(msg)
  }
}
