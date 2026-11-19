import AppKit
import Foundation
import Network

/// A tiny HTTP endpoint on 127.0.0.1 (never reachable from other machines) that the PockAI
/// browser extension posts the on-screen captions to:
///
///     POST http://127.0.0.1:38917/subtitle   {"text": "...", "site": "Netflix"}
///     GET  http://127.0.0.1:38917/ping       -> "pockai"
final class SubtitleServer {

	static let port: UInt16 = 38917

	private var listener: NWListener?
	private var sink: ((String, SubtitleCenter.Source, String) -> Void)?
	private let queue = DispatchQueue(label: "com.pockai.subtitles.server")

	var isRunning: Bool { listener != nil }

	func start(_ sink: @escaping (String, SubtitleCenter.Source, String) -> Void) {
		self.sink = sink
		guard listener == nil else { return }
		do {
			let params = NWParameters.tcp
			params.allowLocalEndpointReuse = true
			params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: Self.port)!)
			let listener = try NWListener(using: params)
			listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
			listener.stateUpdateHandler = { [weak self] state in
				if case .failed(let error) = state {
					NSLog("[PockAI][Subtitles] server failed: \(error)")
					DispatchQueue.main.async { self?.listener?.cancel(); self?.listener = nil }
				}
			}
			listener.start(queue: queue)
			self.listener = listener
		} catch {
			NSLog("[PockAI][Subtitles] can't start server: \(error)")
		}
	}

	func stop() {
		listener?.cancel()
		listener = nil
	}

	// MARK: HTTP (just enough of it)

	private func handle(_ connection: NWConnection) {
		connection.start(queue: queue)
		receive(on: connection, buffer: Data())
		// Never keep a half-open connection around.
		queue.asyncAfter(deadline: .now() + 5) { connection.cancel() }
	}

	private func receive(on connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
			guard let self else { connection.cancel(); return }
			var buffer = buffer
			if let data { buffer.append(data) }
			if buffer.count > 256 * 1024 || error != nil { connection.cancel(); return }
			if let request = Self.parse(buffer) {
				self.respond(to: request, on: connection)
			} else if complete {
				connection.cancel()
			} else {
				self.receive(on: connection, buffer: buffer)
			}
		}
	}

	private struct Request { let method: String; let path: String; let body: Data }

	private static func parse(_ data: Data) -> Request? {
		guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
		guard let head = String(data: data[data.startIndex..<headerEnd.lowerBound], encoding: .utf8) else { return nil }
		let lines = head.components(separatedBy: "\r\n")
		let parts = lines.first?.split(separator: " ") ?? []
		guard parts.count >= 2 else { return nil }
		var length = 0
		for line in lines.dropFirst() where line.lowercased().hasPrefix("content-length:") {
			length = Int(line.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) ?? "0") ?? 0
		}
		let body = data[headerEnd.upperBound...]
		guard body.count >= length else { return nil }
		return Request(method: String(parts[0]), path: String(parts[1]), body: Data(body.prefix(length)))
	}

	private func respond(to request: Request, on connection: NWConnection) {
		var status = "200 OK"
		var payload = "ok"
		switch (request.method, request.path) {
		case ("OPTIONS", _):
			payload = ""
		case ("GET", "/ping"):
			payload = "pockai"
		case ("POST", "/subtitle"):
			if let json = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any] {
				let text = (json["text"] as? String) ?? ""
				let site = (json["site"] as? String) ?? "Browser"
				DispatchQueue.main.async { [weak self] in self?.sink?(String(text.prefix(600)), .browser, site) }
			} else {
				status = "400 Bad Request"; payload = "bad json"
			}
		default:
			status = "404 Not Found"; payload = "not found"
		}
		let body = Data(payload.utf8)
		let header = """
		HTTP/1.1 \(status)\r
		Content-Type: text/plain\r
		Content-Length: \(body.count)\r
		Access-Control-Allow-Origin: *\r
		Access-Control-Allow-Methods: GET, POST, OPTIONS\r
		Access-Control-Allow-Headers: Content-Type\r
		Access-Control-Allow-Private-Network: true\r
		Connection: close\r
		\r

		"""
		connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
	}
}
