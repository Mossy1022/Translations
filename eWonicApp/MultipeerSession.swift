import MultipeerConnectivity
import Combine
import os.log

private let SERVICE_TYPE = "ewonic-xlat"
private let mpq = DispatchQueue(label: "ewonic.multipeer", qos: .userInitiated)

private let log = Logger(subsystem: "com.evansoasis.ewonic",  // ← ADD
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

    private lazy var session: MCSession = {
      let s = MCSession(
        peer:               myPeerID,
        securityIdentity:   nil,
        encryptionPreference: .optional   // was .required
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

  // ────────────────────────────── Life-cycle
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
        print("[Multipeer] Hosting as \(myPeerID.displayName)")
      }
    }

  func stopHosting() {
    mpq.async { [self] in
      guard isAdvertising else { return }
      advertiser.stopAdvertisingPeer()
      DispatchQueue.main.async { self.isAdvertising = false }
      print("[Multipeer] Stopped hosting")
    }
  }

    func startBrowsing() {
      mpq.async { [self] in
        guard !isBrowsing else { return }
        browser.startBrowsingForPeers()
        DispatchQueue.main.async { self.isBrowsing = true }
        print("[Multipeer] Browsing for peers…")
      }
    }

  func stopBrowsing() {
    mpq.async { [self] in
      guard isBrowsing else { return }
      browser.stopBrowsingForPeers()
      DispatchQueue.main.async { self.isBrowsing = false }
      print("[Multipeer] Stopped browsing")
    }
  }

  // ────────────────────────────── Messaging
  func send(message: MessageData, reliable: Bool = true) {
    mpq.async { [self] in
      guard !session.connectedPeers.isEmpty else {
        let msg = "No connected peers – message not sent"
        print("⚠️ \(msg)")
        errorSubject.send(msg)
        return
      }
      guard let raw = try? JSONEncoder().encode(message),
            let bin = try? (raw as NSData).compressed(using: .zlib) as Data
      else {
        let msg = "Failed to encode/compress MessageData"
        print("❌ \(msg)")
        errorSubject.send(msg)
        return
      }
      do {
        let mode: MCSessionSendDataMode = reliable ? .reliable : .unreliable
        try session.send(bin, toPeers: session.connectedPeers, with: mode)
        print("📤 Sent \(bin.count) B (\(mode == .reliable ? "R" : "U"))")
      } catch {
        let msg = "session.send error: \(error.localizedDescription)"
        print("❌ \(msg)")
        errorSubject.send(msg)
      }
    }
  }

    func invitePeer(_ id: MCPeerID) {
      mpq.async { [self] in
        quiesceRadio()                                         // new
        browser.invitePeer(id,
                           to: session,
                           withContext: nil,
                           timeout: 12)                        // was 30
      }
    }


  func disconnect() {
    mpq.async { [self] in
      session.disconnect()
      advertiser.stopAdvertisingPeer()
      browser.stopBrowsingForPeers()
      DispatchQueue.main.async {
        self.connectedPeers.removeAll()
        self.discoveredPeers.removeAll()
        self.connectionState = .notConnected
        self.isAdvertising  = false
        self.isBrowsing     = false
      }
      print("[Multipeer] Disconnected")
    }
  }
}

// ────────────────────────────── MCSessionDelegate
extension MultipeerSession: MCSessionDelegate {

  func session(_ s: MCSession, peer id: MCPeerID, didChange state: MCSessionState) {
    switch state {
    case .connected:
      mpq.async { [self] in
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        DispatchQueue.main.async {
            if !self.connectedPeers.contains(id) { self.connectedPeers.append(id) }
            self.connectionState = .connected
            self.isAdvertising   = false
            self.isBrowsing      = false
        }
        print("[Multipeer] \(id.displayName) CONNECTED")
      }

    case .connecting:
        DispatchQueue.main.async { self.connectionState = .connecting }
        print("[Multipeer] \(id.displayName) CONNECTING…")

    case .notConnected:
      DispatchQueue.main.async {
        self.connectedPeers.removeAll { $0 == id }
        self.connectionState = .notConnected
      }
      print("[Multipeer] \(id.displayName) DISCONNECTED")
      errorSubject.send("Peer \(id.displayName) disconnected")
      if connectedPeers.isEmpty { startBrowsing() }

    @unknown default: break
    }
  }

  func session(_ s: MCSession, didReceive data: Data, fromPeer id: MCPeerID) {
    mpq.async { [self] in
      guard
        let raw = try? (data as NSData).decompressed(using: .zlib) as Data,
        let msg = try? JSONDecoder().decode(MessageData.self, from: raw)
      else {
        let err = "Failed to decode message from \(id.displayName)"
        print("❌ \(err)")
        errorSubject.send(err)
        return
      }
      DispatchQueue.main.async {
        self.receivedMessage = msg
        self.onMessageReceived?(msg)
      }
    }
  }

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
      quiesceRadio()                                           // new
      let accept = connectedPeers.count < MultipeerSession.peerLimit
      invitationHandler(accept, accept ? session : nil)
    }

  func advertiser(_:MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
    DispatchQueue.main.async {
      self.errorSubject.send("Advertiser error: \(error.localizedDescription)")
    }
  }
    
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
  func browser(_:MCNearbyServiceBrowser, foundPeer id: MCPeerID, withDiscoveryInfo _: [String:String]?) {
    DispatchQueue.main.async {
      if !self.discoveredPeers.contains(id) { self.discoveredPeers.append(id) }
    }
    print("🟢 Found peer \(id.displayName)")
  }
  func browser(_:MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
    DispatchQueue.main.async { self.discoveredPeers.removeAll { $0 == id } }
    print("🔴 Lost peer \(id.displayName)")
  }
  func browser(_:MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
    DispatchQueue.main.async {
      self.errorSubject.send("Browser error: \(error.localizedDescription)")
    }
  }
}
