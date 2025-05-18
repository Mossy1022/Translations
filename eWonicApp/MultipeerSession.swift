//
//  MultipeerSession.swift
//  eWonicMVP
//
//  Created by Evan Moscoso on 5/18/25.
//

import MultipeerConnectivity
import Combine

class MultipeerSession: NSObject, ObservableObject {
    private let serviceType = "mytranslator-nstt" // Matches Info.plist
    private let myPeerID = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession!
    private var serviceAdvertiser: MCNearbyServiceAdvertiser!
    private var serviceBrowser: MCNearbyServiceBrowser!

    @Published var connectedPeers: [MCPeerID] = []
    @Published var receivedMessage: MessageData?
    @Published var connectionState: MCSessionState = .notConnected
    @Published var discoveredPeers: [MCPeerID] = [] // To show in UI

    var onMessageReceived: ((MessageData) -> Void)?

    override init() {
        super.init()
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self

        serviceAdvertiser = MCNearbyServiceAdvertiser(peer: myPeerID, discoveryInfo: nil, serviceType: serviceType)
        serviceAdvertiser.delegate = self

        serviceBrowser = MCNearbyServiceBrowser(peer: myPeerID, serviceType: serviceType)
        serviceBrowser.delegate = self
    }

    func startHosting() {
        discoveredPeers.removeAll()
        serviceAdvertiser.startAdvertisingPeer()
        print("Started hosting.")
    }

    func stopHosting() {
        serviceAdvertiser.stopAdvertisingPeer()
        print("Stopped hosting.")
    }

    func startBrowsing() {
        discoveredPeers.removeAll()
        serviceBrowser.startBrowsingForPeers()
        print("Started browsing.")
    }

    func stopBrowsing() {
        serviceBrowser.stopBrowsingForPeers()
        print("Stopped browsing.")
    }

    func send(message: MessageData) {
        guard !session.connectedPeers.isEmpty else {
            print("No connected peers to send message to.")
            return
        }
        do {
            let data = try JSONEncoder().encode(message)
            try session.send(data, toPeers: session.connectedPeers, with: .reliable)
            print("Sent message: \(message.originalText)")
        } catch {
            print("Error sending message: \(error.localizedDescription)")
        }
    }

    func invitePeer(_ peerID: MCPeerID) {
        print("Inviting peer: \(peerID.displayName)")
        serviceBrowser.invitePeer(peerID, to: session, withContext: nil, timeout: 30)
    }

    func disconnect() {
        session.disconnect()
        // Clear states
        DispatchQueue.main.async {
            self.connectedPeers.removeAll()
            self.discoveredPeers.removeAll() // Clear discovered peers on disconnect
            self.connectionState = .notConnected
        }
        print("Disconnected session.")
    }
}

extension MultipeerSession: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.connectionState = state
            switch state {
            case .connected:
                print("Connected to: \(peerID.displayName)")
                if !self.connectedPeers.contains(peerID) {
                    self.connectedPeers.append(peerID)
                }
                self.discoveredPeers.removeAll() // Clear discovered peers once connected
                self.stopBrowsing() // Optional: stop browsing once connected to one peer
                self.stopHosting()  // Optional: stop advertising if you only want one connection
            case .connecting:
                print("Connecting to: \(peerID.displayName)")
            case .notConnected:
                print("Disconnected from: \(peerID.displayName)")
                self.connectedPeers.removeAll(where: { $0 == peerID })
                if self.connectedPeers.isEmpty {
                    // Connection lost or never established
                    // Potentially restart browsing/advertising or notify user
                }
            @unknown default:
                print("Unknown state for peer \(peerID.displayName): \(state)")
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        print("Received data from \(peerID.displayName)")
        do {
            let message = try JSONDecoder().decode(MessageData.self, from: data)
            DispatchQueue.main.async {
                self.receivedMessage = message
                self.onMessageReceived?(message)
                print("Received message: \(message.originalText)")
            }
        } catch {
            print("Error decoding received data: \(error.localizedDescription)")
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        print("Received stream from \(peerID.displayName)")
    }

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        print("Started receiving resource \(resourceName) from \(peerID.displayName)")
    }

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {
        print("Finished receiving resource \(resourceName) from \(peerID.displayName)")
    }
}

extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        print("Received invitation from \(peerID.displayName)")
        // For a real app, you'd probably prompt the user.
        // For this example, we'll auto-accept if not already connected to someone.
        if connectedPeers.isEmpty {
            invitationHandler(true, self.session)
        } else {
            print("Already connected to a peer. Ignoring new invitation from \(peerID.displayName).")
            invitationHandler(false, nil)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        print("Error starting advertising: \(error.localizedDescription)")
    }
}

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        print("Found peer: \(peerID.displayName)")
        DispatchQueue.main.async {
            if !self.discoveredPeers.contains(peerID) && !self.connectedPeers.contains(peerID) {
                self.discoveredPeers.append(peerID)
            }
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        print("Lost peer: \(peerID.displayName)")
        DispatchQueue.main.async {
            self.discoveredPeers.removeAll(where: { $0 == peerID })
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        print("Error starting browsing: \(error.localizedDescription)")
    }
}
