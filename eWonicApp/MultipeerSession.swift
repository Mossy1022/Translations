//
//  MultipeerSession.swift
//  eWonicApp
//
//  Thread‑safe Swift‑6 version.
//  • Class stays @MainActor for normal API calls.
//  • Every delegate callback is marked `nonisolated`, then
//    re‑dispatched onto the main actor before touching state.


import MultipeerConnectivity
import Combine
import os.log

private let SERVICE_TYPE = "ewonic-xlat"
private let LOG = Logger(subsystem: "com.evansoasis.ewonic", category: "multipeer")

// ──────────────────────────────────────────────────────────────
// MARK: – Model
// ──────────────────────────────────────────────────────────────
@MainActor
final class MultipeerSession: NSObject, ObservableObject {

  // ───────── Public state
  static let peerLimit = 6

  @Published private(set) var connectedPeers  : [MCPeerID] = []
  @Published private(set) var discoveredPeers : [MCPeerID] = []
  @Published private(set) var connectionState : MCSessionState = .notConnected
  @Published private(set) var isAdvertising   = false
  @Published private(set) var isBrowsing      = false
  @Published              var receivedMessage : MessageData?

  // ───────── Core plumbing
  private let myPeerID = MCPeerID(displayName: UIDevice.current.name)

  private lazy var session: MCSession = {
    let s = MCSession(peer: myPeerID,
                      securityIdentity: nil,
                      encryptionPreference: .optional)
    s.delegate = self
    return s
  }()

  private lazy var advertiser = MCNearbyServiceAdvertiser(peer: myPeerID,
                                                          discoveryInfo: nil,
                                                          serviceType: SERVICE_TYPE)

  private lazy var browser = MCNearbyServiceBrowser(peer: myPeerID,
                                                    serviceType: SERVICE_TYPE)

  // ───────── Callbacks
  var  onMessageReceived : ((MessageData) -> Void)?
  let  errorSubject      = PassthroughSubject<String, Never>()

  // ───────── Life‑cycle
  override init() {
    super.init()
    advertiser.delegate = self
    browser  .delegate = self
  }

  deinit { Task { @MainActor in disconnect() } }

  // ──────────────────────────────────────────────────────────
  // MARK: – Host / Join helpers
  // ──────────────────────────────────────────────────────────
  func startHosting() {
    guard !isAdvertising else { return }
    advertiser.startAdvertisingPeer()
    isAdvertising = true
    LOG.debug("[Multipeer] Hosting")
  }

  func startBrowsing() {
    guard !isBrowsing else { return }
    browser.startBrowsingForPeers()
    isBrowsing = true
    LOG.debug("[Multipeer] Browsing")
  }

  /// Stop both advertiser & browser.
  func stopActivities() {
    advertiser.stopAdvertisingPeer()
    browser.stopBrowsingForPeers()
    isAdvertising = false
    isBrowsing    = false
  }

  // ──────────────────────────────────────────────────────────
  // MARK: – Messaging
  // ──────────────────────────────────────────────────────────
  func send(message msg: MessageData, reliable: Bool = true) {

    Task.detached(priority: .userInitiated) { [weak self] in
      guard let self else { return }

      // encode
      guard let raw = try? JSONEncoder().encode(msg) else {
        LOG.error("❌ Failed to encode MessageData")
        return
      }
      // compress
      let bin = (try? (raw as NSData).compressed(using: .zlib) as Data) ?? raw

      await MainActor.run {
          guard !self.session.connectedPeers.isEmpty else { return }
        do {
            try self.session.send(bin,
                                  toPeers: self.session.connectedPeers,
                           with: reliable ? .reliable : .unreliable)
          LOG.debug("📤 Sent \(bin.count) B")
        } catch {
          let txt = "session.send error: \(error.localizedDescription)"
          LOG.error("❌ \(txt)")
            self.errorSubject.send(txt)
        }
      }
    }
  }

  // ──────────────────────────────────────────────────────────
  // MARK: – Disconnect
  // ──────────────────────────────────────────────────────────
  func disconnect() {
    session.disconnect()
    stopActivities()
    connectedPeers.removeAll()
    discoveredPeers.removeAll()
    connectionState = .notConnected
    LOG.debug("[Multipeer] Disconnected")
  }
}

// ──────────────────────────────────────────────────────────────
// MARK: – MCSessionDelegate  (all methods nonisolated)
// ──────────────────────────────────────────────────────────────
extension MultipeerSession: MCSessionDelegate {

  nonisolated
  func session(_ s: MCSession,
               peer id: MCPeerID,
               didChange state: MCSessionState)
  {
    Task { @MainActor in
      switch state {

      case .connected:
        if !connectedPeers.contains(id) { connectedPeers.append(id) }
        if connectedPeers.count < Self.peerLimit {
          startHosting(); startBrowsing()
        } else {
          stopActivities()
        }
        connectionState = .connected
        LOG.debug("[Multipeer] \(id.displayName) CONNECTED")

      case .connecting:
        connectionState = .connecting
        LOG.debug("[Multipeer] \(id.displayName) CONNECTING…")

      case .notConnected:
        connectedPeers.removeAll { $0 == id }
        startHosting(); startBrowsing()
        connectionState = .notConnected
        errorSubject.send("Connection to \(id.displayName) lost.")
        LOG.debug("[Multipeer] \(id.displayName) DISCONNECTED")

      @unknown default: break
      }
    }
  }

  nonisolated
  func session(_: MCSession,
               didReceive data: Data,
               fromPeer _: MCPeerID)
  {
    Task.detached { [weak self] in
      guard let self else { return }
      let dec = (try? (data as NSData).decompressed(using: .zlib) as Data) ?? data
      guard let msg = try? JSONDecoder().decode(MessageData.self, from: dec) else {
        LOG.error("❌ Could not decode MessageData")
        return
      }
      await MainActor.run {
          self.receivedMessage = msg
          self.onMessageReceived?(msg)
      }
    }
  }

  // remaining delegate stubs (empty bodies)
  nonisolated
  func session(_: MCSession, didReceive _: InputStream,
               withName _: String, fromPeer _: MCPeerID) {}

  nonisolated
  func session(_: MCSession, didStartReceivingResourceWithName _: String,
               fromPeer _: MCPeerID, with _: Progress) {}

  nonisolated
  func session(_: MCSession, didFinishReceivingResourceWithName _: String,
               fromPeer _: MCPeerID, at _: URL?, withError _: Error?) {}
}

// ──────────────────────────────────────────────────────────────
// MARK: – Advertiser / Browser delegates (nonisolated)
// ──────────────────────────────────────────────────────────────
extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {

  nonisolated
  func advertiser(_: MCNearbyServiceAdvertiser,
                  didReceiveInvitationFromPeer id: MCPeerID,
                  withContext _: Data?,
                  invitationHandler: @escaping (Bool, MCSession?) -> Void)
  {
    Task { @MainActor in
      let accept = connectedPeers.count < Self.peerLimit
      invitationHandler(accept, accept ? session : nil)
    }
  }

  nonisolated
  func advertiser(_: MCNearbyServiceAdvertiser,
                  didNotStartAdvertisingPeer error: Error)
  {
    Task { @MainActor in
      errorSubject.send("Advertiser error: \(error.localizedDescription)")
    }
  }
}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {

  nonisolated
  func browser(_: MCNearbyServiceBrowser,
               foundPeer id: MCPeerID,
               withDiscoveryInfo _: [String : String]?)
  {
    Task { @MainActor in
      if !discoveredPeers.contains(id) { discoveredPeers.append(id) }
      LOG.debug("🟢 Found peer \(id.displayName)")
    }
  }

  nonisolated
  func browser(_: MCNearbyServiceBrowser, lostPeer id: MCPeerID) {
    Task { @MainActor in
      discoveredPeers.removeAll { $0 == id }
      LOG.debug("🔴 Lost peer \(id.displayName)")
    }
  }

  nonisolated
  func browser(_: MCNearbyServiceBrowser,
               didNotStartBrowsingForPeers error: Error)
  {
    Task { @MainActor in
      errorSubject.send("Browser error: \(error.localizedDescription)")
    }
  }

  /// Convenience wrapper for the 'Join' button.
  func invitePeer(_ peer: MCPeerID, timeout: TimeInterval = 12) {
    browser.invitePeer(peer,
                       to: session,
                       withContext: nil,
                       timeout: timeout)
  }
}
