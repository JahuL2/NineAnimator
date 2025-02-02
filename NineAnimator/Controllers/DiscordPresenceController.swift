//
//  This file is part of the NineAnimator project.
//
//  Copyright © 2018-2020 Marcus Zhou. All rights reserved.
//
//  NineAnimator is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  NineAnimator is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with NineAnimator.  If not, see <http://www.gnu.org/licenses/>.
//

import Foundation
import NineAnimatorCommon
import NineAnimatorNativeParsers
import NineAnimatorNativeSources

#if canImport(SwordRPC)
import SwordRPC
#endif

class DiscordPresenceController {
    /// If rich presence service is available on the current platform
    var isAvailable: Bool {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return true
        #else
        return false
        #endif
    }
    
    /// Reflects the enabled state of rich presence integration from NineAnimatorUser
    var isEnabled: Bool {
        isAvailable && NineAnimator.default.user.richPresenceEnabled
    }
    
    /// Whether the RPC service has been connected
    var isConnected: Bool {
        #if canImport(SwordRPC)
        return _rpcService.isConnected
        #else
        return false
        #endif
    }
    
    #if canImport(SwordRPC)
    private var _rpcService: SwordRPC
    #endif
    
    private(set) var currentPresence: Presence = .chilling
    private var _queue = DispatchQueue(
        label: "com.marcuszhou.NineAnimator.presenceController",
        qos: .default
    )
    
    init() {
        #if canImport(SwordRPC)
        self._rpcService = SwordRPC(appId: DiscordPresenceController.serviceId)
        self._rpcService.delegate = self
        
        // Subscribe to notifications
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_onPlaybackDidStart(notification:)),
            name: .playbackDidStart,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(_onPlaybackDidEnd(notification:)),
            name: .playbackDidEnd,
            object: nil
        )
        #endif
    }
    
    func reset() {
        #if canImport(SwordRPC)
        _queue.async {
            if self.isEnabled {
                self._rpcService = SwordRPC(appId: DiscordPresenceController.serviceId)
                self._rpcService.delegate = self
                self._setupRPCService()
            } else if self._rpcService.isConnected {
                self._rpcService.disconnect()
            }
        }
        #endif
    }
    
    func setup() {
        #if canImport(SwordRPC)
        _queue.sync { self._setupRPCService() }
        #endif
    }
    
    /// Update current rich presence state.
    ///
    /// The presence controller automatically updates the current rich presence when a new video player state has been detected.
    func updatePresence(_ presence: Presence) {
        if self.currentPresence != presence {
            self.currentPresence = presence
            NotificationCenter.default.post(name: .presenceControllerDidUpdatePresence, object: self)
            _queue.async {
                [weak self] in self?._updatePresenceIfPossible()
            }
        }
    }
}

extension DiscordPresenceController {
    enum Presence: Equatable {
        case chilling // Doing nothing
        case watching(EpisodeLink)
    }
}

extension DiscordPresenceController {
    /// Shared rich presence controller
    static let shared = DiscordPresenceController()
}

#if canImport(SwordRPC)
// MARK: - SwordRPCDelegate
extension DiscordPresenceController: SwordRPCDelegate {
    private class var serviceId: String {
        String(
            NineAnimator.default.cloud.serviceSalt.reduce(UInt64(8170)) { $0 * UInt64($1) }
            + NineAnimator.runtime.buildPrefixIdentifier.reduce(UInt64(9840)) { $0 * UInt64($1) }
            + NineAnimator.default.cloud.serviceOffset
        ) + "6"
    }
    
    private func _setupRPCService() {
        if self.isEnabled && !self._rpcService.isConnected {
            Log.info("[DiscordPresenceController] Setting up Discord RPC service...")
            _queue.async { self._rpcService.connect() }
        }
    }
    
    func swordRPCDidConnect(_ rpc: SwordRPC) {
        Log.info("[DiscordPresenceController] Discord RPC connection established.")
        _queue.async {
            self._sendRPCPresence()
            NotificationCenter.default.post(name: .presenceControllerConnectionStateDidUpdate, object: self)
        }
    }
    
    func swordRPCDidDisconnect(_ rpc: SwordRPC, code: Int?, message msg: String?) {
        _queue.async {
            NotificationCenter.default.post(name: .presenceControllerConnectionStateDidUpdate, object: self)
        }
    }
    
    func swordRPCDidReceiveError(_ rpc: SwordRPC, code: Int, message: String) {
        Log.error("[DiscordPresenceController] Discord RPC service encountered an error (%@): %@", code, message)
    }
}

// MARK: - Player Notification Handlers
extension DiscordPresenceController {
    @objc private func _onPlaybackDidStart(notification: Notification) {
        if let media = notification.userInfo?["media"] as? PlaybackMedia {
            updatePresence(.watching(media.link))
        }
    }
    
    @objc private func _onPlaybackDidEnd(notification: Notification) {
        updatePresence(.chilling)
    }
}

// MARK: - RPC Presence
extension DiscordPresenceController {
    /// Update the presence if possible
    private func _updatePresenceIfPossible() {
        if _rpcService.isConnected {
            _sendRPCPresence()
            Log.info("[DiscordPresenceController] Presence updated to %@.", currentPresence)
        } else { self._rpcService.connect() }
    }
    
    /// Send presence to the rpc service
    private func _sendRPCPresence() {
        var presence  = RichPresence()
        
        switch currentPresence {
        case .chilling:
            presence.state = "Just Chilling"
            presence.details = "About to start watching"
            presence.assets.largeImage = "nineanimator_icon"
            presence.assets.largeText = "Using NineAnimator"
        case let .watching(episodeLink):
            presence.state = "Watching an Anime"
            presence.details = "In NineAnimator"
            presence.assets.largeText = "Watching an Anime"
            
            if NineAnimator.default.user.richPresenceShowAnimeName {
                let episodeNumber = NineAnimator
                    .default
                    .trackingContext(for: episodeLink.parent)
                    .suggestingEpisodeNumber(for: episodeLink)
                
                if let episodeNumber = episodeNumber {
                    presence.state = "Watching Episode \(episodeNumber)"
                }
                
                presence.details = episodeLink.parent.title
                presence.assets.largeText = "Watching \(episodeLink.parent.title)"
            }
            
            presence.assets.largeImage = "watching_anime"
            presence.assets.smallImage = "nineanimator_icon"
            presence.assets.smallText = "with NineAnimator"
        }
        
        _rpcService.setPresence(presence)
    }
}
#endif
