//
//  WeatherService.swift
//  Weather
//
//  Created by Pierluigi Galdi on 20/06/21.
//  Copyright © 2021 Pierluigi Galdi. All rights reserved.
//

import Foundation
import CoreLocation
import AppKit

struct Weather: Codable {
    let name: String
    let temp: Double
    let icon: String
    let description: String
    var temperature: String {
        guard temp > -999 else {
            return "Unknown information"
        }
        let units: String = Preferences[.units]
        switch units {
        case "celsius":
            let converted = (temp - 32) * (5/9)
            return "\(Int(converted))°"
        default:
            return "\(Int(temp))°"
        }
    }
}

struct WeatherData: Codable {
    struct Metadata: Codable {
        let error: String?
        let code: Int
    }
    let metadata: Metadata
    let weather: Weather
    private enum CodingKeys: String, CodingKey {
        case weather = "data", metadata
    }
}

internal class WeatherService {

	// Pock's own weather server (weather.navalia.app) no longer exists. Open-Meteo is free and needs no key.
	// https://api.open-meteo.com/v1/forecast?latitude=..&longitude=..&current=temperature_2m,weather_code,is_day

	private func unknown() -> WeatherData {
		let name: String = Preferences[.city_name]
		return WeatherData(metadata: .init(error: nil, code: -999),
						   weather: Weather(name: name, temp: -999, icon: NSImage.touchBarSearchTemplateName, description: "Unknown information"))
	}

	/// WMO weather code → (icon in Icons.xcassets without d/n, description)
	private static func describe(_ code: Int) -> (String, String) {
		switch code {
		case 0: return ("01", "Clear sky")
		case 1: return ("02", "Mainly clear")
		case 2: return ("03", "Partly cloudy")
		case 3: return ("04", "Overcast")
		case 45, 48: return ("50", "Fog")
		case 51, 53, 55, 56, 57: return ("09", "Drizzle")
		case 61, 63, 65, 66, 67: return ("10", "Rain")
		case 71, 73, 75, 77, 85, 86: return ("13", "Snow")
		case 80, 81, 82: return ("09", "Rain showers")
		case 95, 96, 99: return ("11", "Thunderstorm")
		default: return ("03", "Cloudy")
		}
	}

	func currentConditions(for coordinate: CLLocationCoordinate2D, cityName: String, result: @escaping (WeatherData?) -> Void) {
		var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
		components.queryItems = [
			URLQueryItem(name: "latitude", value: String(format: "%.4f", coordinate.latitude)),
			URLQueryItem(name: "longitude", value: String(format: "%.4f", coordinate.longitude)),
			URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
			// Weather.temperature expects Fahrenheit and converts for Celsius users.
			URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
		]
		guard let url = components.url else { result(unknown()); return }
		let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
		// Strong capture on purpose: callers create a throw-away WeatherService for each request.
		URLSession.shared.dataTask(with: request) { data, _, error in
			guard error == nil, let data = data,
				  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				  let current = json["current"] as? [String: Any],
				  let temp = (current["temperature_2m"] as? NSNumber)?.doubleValue else {
				result(self.unknown())
				return
			}
			let code = (current["weather_code"] as? NSNumber)?.intValue ?? 3
			let isDay = ((current["is_day"] as? NSNumber)?.intValue ?? 1) == 1
			let (icon, description) = Self.describe(code)
			let weather = Weather(name: cityName, temp: temp, icon: icon + (isDay ? "d" : "n"), description: description)
			result(WeatherData(metadata: .init(error: nil, code: 200), weather: weather))
		}.resume()
	}

}
