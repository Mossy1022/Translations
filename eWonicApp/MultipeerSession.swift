import MultipeerConnectivity
import Combine

// Shared service identifier (10 chars, ASCII a–z0–9-)
private let SERVICE_TYPE = "ewonic-xlat"

final class MultipeerSession: NSObject, ObservableObject {
  // MARK: – Public state
  @Published private(set) var connectedPeers: [MCPeerID] = []
  @Published private(set) var discoveredPeers: [MCPeerID] = []
  @Published private(set) var connectionState: MCSessionState = .notConnected
  @Published private(set) var isAdvertising = false
  @Published private(set) var isBrowsing    = false
  @Published var receivedMessage: MessageData?

  // MARK: – MC plumbing
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

  // MARK: – Callback
  var onMessageReceived: ((MessageData) -> Void)?

  // MARK: – Init / Deinit
  override init() {
    super.init()
    advertiser.delegate = self
    browser.delegate    = self
  }

  deinit { disconnect() }

  // MARK: – Host / Join control
  func startHosting() {
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

  // MARK: – Messaging
  func invitePeer(_ peerID: MCPeerID) {
    browser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
  }

  func send(message: MessageData) {
    guard !session.connectedPeers.isEmpty else {
      print("⚠️ No connected peers – message not sent")
      return
    }

    guard let data = try? JSONEncoder().encode(message) else {
      print("❌ Failed to encode MessageData")
      return
    }

    do {
      try session.send(data, toPeers: session.connectedPeers, with: .reliable)
      print("📤 Sent \(data.count) bytes → \(session.connectedPeers.map { $0.displayName })")
    } catch {
      print("❌ session.send error: \(error.localizedDescription)")
    }
  }

  func disconnect() {
    session.disconnect()
    connectedPeers.removeAll()
    discoveredPeers.removeAll()
    connectionState = .notConnected
    stopHosting()
    stopBrowsing()
    print("[Multipeer] Disconnected")
  }
}

// MARK: – MCSessionDelegate
extension MultipeerSession: MCSessionDelegate {
  func session(_ s: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    DispatchQueue.main.async {
      self.connectionState = state
      switch state {
      case .connected:
        if !self.connectedPeers.contains(peerID) { self.connectedPeers.append(peerID) }
        self.stopHosting(); self.stopBrowsing()
        print("[Multipeer] \(peerID.displayName) CONNECTED")
      case .connecting:
        print("[Multipeer] \(peerID.displayName) CONNECTING…")
      case .notConnected:
        self.connectedPeers.removeAll { $0 == peerID }
        print("[Multipeer] \(peerID.displayName) DISCONNECTED")
      @unknown default: break
      }
    }
  }

  func session(_ s: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    print("📨 Received \(data.count) bytes from \(peerID.displayName)")
    guard let msg = try? JSONDecoder().decode(MessageData.self, from: data) else {
      print("❌ Could not decode MessageData")
      return
    }
    DispatchQueue.main.async {
      self.receivedMessage = msg
      self.onMessageReceived?(msg)
    }
  }

  // Unused stubs
  func session(_:MCSession, didReceive _:InputStream, withName _:String, fromPeer _:MCPeerID) {}
  func session(_:MCSession, didStartReceivingResourceWithName _:String, fromPeer _:MCPeerID, with _:Progress) {}
  func session(_:MCSession, didFinishReceivingResourceWithName _:String, fromPeer _:MCPeerID, at _:URL?, withError _:Error?) {}
}

// MARK: – Advertiser / Browser
extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {
  func advertiser(_:MCNearbyServiceAdvertiser,
                  didReceiveInvitationFromPeer peerID: MCPeerID,
                  withContext _:Data?,
                  invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    invitationHandler(self.connectedPeers.isEmpty, self.session)
  }

  func advertiser(_:MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
    print("Advertiser error: \(error.localizedDescription)")
  }
}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
  func browser(_:MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo _: [String:String]?) {
    DispatchQueue.main.async {
      if !self.discoveredPeers.contains(peerID) { self.discoveredPeers.append(peerID) }
      print("🟢 Found peer \(peerID.displayName)")
    }
  }

  func browser(_:MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
    DispatchQueue.main.async { self.discoveredPeers.removeAll { $0 == peerID } }
    print("🔴 Lost peer \(peerID.displayName)")
  }

  func browser(_:MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    print("Browser error: \(error.localizedDescription)")
  }
}
