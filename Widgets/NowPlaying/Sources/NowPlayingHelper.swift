//
//  NowPlayingHelper.swift
//  Pock
//
//  Created by Pierluigi Galdi on 17/02/2019.
//  Copyright © 2019 Pierluigi Galdi. All rights reserved.
//

import Foundation
import AppKit

import PockAIKit

/// Now Playing data from PockAI's shared helper (works on macOS 15.4+, where direct MediaRemote
/// access is blocked for normal apps).
class NowPlayingHelper {
	
	/// Data
	public private(set) var currentNowPlayingItem: NowPlayingItem?
	
	/// Ref
	internal weak var view: NowPlayingView?
	private var token: UUID?
	private var lastApp: String?
	
	internal init(forView: NowPlayingView) {
		view = forView
		let item = NowPlayingItem()
		item.client = NowPlayingItem.Client(bundleIdentifier: nil, parentApplicationBundleIdentifier: nil, displayName: nil, icon: nil)
		currentNowPlayingItem = item
		token = NowPlayingCenter.shared.subscribe { [weak self] state, artChanged in
			self?.receive(state, artChanged: artChanged)
		}
		for name in [NSNotification.Name.mrMediaRemoteNowPlayingApplicationDidChange, .mrPlaybackQueueContentItemsChanged] {
			NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: name, object: nil)
		}
	}
	
	@objc private func preferencesChanged() {
		lastApp = nil
		receive(NowPlayingCenter.shared.state, artChanged: true)
	}
	
	private func receive(_ state: NowPlaying, artChanged: Bool) {
		guard let item = currentNowPlayingItem else { return }
		let appID = state.app ?? (Preferences[.defaultPlayer] as String)
		if appID != lastApp || item.client.bundleIdentifier == nil {
			lastApp = appID
			item.client = NowPlayingItem.Client(
				bundleIdentifier: appID,
				parentApplicationBundleIdentifier: nil,
				displayName: NSWorkspace.shared.applicationName(for: appID),
				icon: NSWorkspace.shared.applicationIcon(for: appID, fallbackFileType: "mp3")
			)
		}
		item.title = state.hasContent ? state.title : nil
		item.artist = state.artist.isEmpty ? nil : state.artist
		item.album = state.album.isEmpty ? nil : state.album
		item.isPlaying = state.playing && state.hasContent
		if Preferences[.showMediaArtwork] {
			if artChanged || item.artwork == nil { item.artwork = NowPlayingCenter.shared.artwork }
		} else {
			item.artwork = nil
		}
		view?.updateContentViews()
	}
	
	deinit {
		NotificationCenter.default.removeObserver(self)
		NowPlayingCenter.shared.unsubscribe(token)
		view = nil
		currentNowPlayingItem = nil
	}
	
}

extension NowPlayingHelper {
	
	public func togglePlayingState() {
		NowPlayingCenter.shared.send(.toggle)
	}
	
	public func skipToNextTrack() {
		NowPlayingCenter.shared.send(.next)
	}
	
	public func skipToPreviousTrack() {
		NowPlayingCenter.shared.send(.previous)
	}
	
}

extension URLSession {
	static func fetchJSON(fromURL url: URL, completionHandler: @escaping (Data?, Any?, Error?) -> Void) -> URLSessionTask {
		let task = URLSession.shared.dataTask(with: url) { (data, response, error) in
			if error != nil {
				completionHandler(nil, nil, error)
				return
			}
			if data == nil {
				completionHandler(nil, nil, NSError(domain:"", code:401, userInfo:[ NSLocalizedDescriptionKey: "Invalid data"]))
				return
			}
			guard let json = try? JSONSerialization.jsonObject(with: data!, options: .allowFragments) else {
				completionHandler(nil, nil, NSError(domain:"", code:401, userInfo:[ NSLocalizedDescriptionKey: "Invalid json"]))
				return
			}
			completionHandler(data, json, nil)
		}
		return task
	}
}

extension NSWorkspace {
	public func applicationName(for bundleIdentifier: String) -> String? {
		self.urlForApplication(withBundleIdentifier: bundleIdentifier)?.lastPathComponent.replacingOccurrences(of: ".app", with: "")
	}
	public func applicationIcon(for bundleIdentifier: String?, fallbackFileType: String? = nil) -> NSImage? {
		if let bundleIdentifier = bundleIdentifier,
		   let path = NSWorkspace.shared.absolutePathForApplication(withBundleIdentifier: bundleIdentifier) {
			return NSWorkspace.shared.icon(forFile: path)
		} else {
			return NSWorkspace.shared.icon(forFileType: fallbackFileType ?? "pock")
		}
	}
}
