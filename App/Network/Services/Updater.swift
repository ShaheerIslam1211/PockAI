//
//  Updater.swift
//  Pock
//
//  Created by Pierluigi Galdi on 05/05/21.
//

import AppKit
import Foundation

// MARK: Error
internal enum UpdaterError: PockError {
	case invalidEndpointURL
	case responseError(reason: String?)
	case parsingError
	case invalidCoreVersion(minVersion: String)
	var description: String {
		switch self {
		case .invalidEndpointURL:
			return "error.updater.invalid-endpoint-url".localized
		case .responseError(let reason):
			return "error.updater.response-error".localized(reason ?? "error.unknown-server-error".localized)
		case .parsingError:
			return "error.updater.parsing-error".localized
		case .invalidCoreVersion(let minVersion):
			return "error.updater.invalid-core-version".localized(minVersion)
		}
	}
}

// MARK: Notification
extension NSNotification.Name {
	static var didFetchLatestVersions = NSNotification.Name("didFetchLatestVersions")
}

internal class Updater {
	
	typealias Error = UpdaterError
	
	public typealias WidgetVersion = (version: Version?, error: Error?)
	
	// MARK: Build info
	
	static var appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
	static var buildVersion: String? = {
		let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
		return build == "1" ? nil : build
	}()
	static var fullAppVersion: String = {
		guard let build = buildVersion else {
			return appVersion
		}
		return "\(appVersion)-\(build)"
	}()
	
	// MARK: Netowrk core-info
	
	#if DEBUG
	private let latestVersionURLString: String = "https://stage.pock.app/api/latestVersions.json"
	#else
	private let latestVersionURLString: String = "https://pock.app/api/latestVersions.json"
	#endif
	
	// MARK: Cache (?)
	static private(set) var cachedLatestReleases: LatestReleases?
	
	// MARK: Fetch latest versions
	
	/// PockAI ships every widget inside the app, so there is nothing to fetch from pock.app.
	/// Kept as an API so the rest of the Pock core keeps working unchanged (and offline).
	internal func fetchLatestVersions(ignoreCache: Bool = false, _ completion: @escaping (LatestReleases?, Error?) -> Void) {
		_ = latestVersionURLString
		completion(Updater.cachedLatestReleases, nil)
	}
	
	// MARK: Get newest version for given widget
	
	static func newVersion(for widget: PKWidgetInfo) -> WidgetVersion {
		guard let new = cachedLatestReleases?.widgets.first(where: { $0.key.lowercased() == widget.bundleIdentifier.lowercased() })?.value else {
			return (nil, nil)
		}
		if let coreMin = new.coreMin {
            if coreMin.isGreatherThan(fullAppVersion) {
                return (nil, .invalidCoreVersion(minVersion: coreMin))
            }
		}
        return new.name.isGreatherThan(widget.fullVersion) ? (new, nil) : (nil, nil)
	}
	
}
