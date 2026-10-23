import Foundation
import Network

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

enum HTTPParseResult {
    case incomplete
    case request(HTTPRequest)
    case invalid
}

enum HTTPParser {
    static func parse(_ data: Data) -> HTTPParseResult {
        guard data.count <= 16_384 else { return .invalid }
        guard let boundary = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let text = String(data: data[..<boundary.lowerBound], encoding: .utf8) else { return .invalid }
        let lines = text.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, ["GET", "POST", "OPTIONS"].contains(String(parts[0])),
              parts[1].hasPrefix("/"), parts[2] == "HTTP/1.1" else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return .invalid }
            let key = line[..<colon].lowercased()
            guard !key.isEmpty, headers[key] == nil else { return .invalid }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let host = headers["host"], ["127.0.0.1:48741", "localhost:48741"].contains(host) else { return .invalid }
        let length: Int
        if let value = headers["content-length"] {
            guard let parsed = Int(value), (0...4096).contains(parsed) else { return .invalid }
            length = parsed
        } else { length = 0 }
        let bodyStart = boundary.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        guard data.count == bodyStart + length else { return .invalid }
        let target = String(parts[1])
        guard let components = URLComponents(string: "http://127.0.0.1\(target)") else { return .invalid }
        return .request(HTTPRequest(method: String(parts[0]), path: components.path,
                                    headers: headers, body: data[bodyStart...]))
    }
}

struct HTTPResponse {
    var status: Int
    var body: Data
    var contentType: String = "application/json; charset=utf-8"
    static func json(_ value: [String: Any], status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, body: (try? JSONSerialization.data(withJSONObject: value)) ?? Data("{}".utf8))
    }
}

final class BrowserBridge {
    static let port: UInt16 = 48741
    let extensionID: String
    var onRequest: ((HTTPRequest) -> HTTPResponse)?
    var onStatus: ((String?) -> Void)?
    private let queue = DispatchQueue(label: "local.autodisplay.browser-bridge")
    private var listener: NWListener?

    init(extensionID: String) { self.extensionID = extensionID }

    func isExtensionRequest(_ request: HTTPRequest) -> Bool {
        guard request.headers["x-autodisplay-extension"] == extensionID else { return false }
        if let origin = request.headers["origin"], !origin.isEmpty {
            return origin == "chrome-extension://\(extensionID)"
        }
        // Extension fetch may omit Origin when host permissions apply.
        // Authenticated endpoints still require a per-installation secret.
        return true
    }

    func start() {
        do {
            let parameters = NWParameters.tcp
            let port = NWEndpoint.Port(rawValue: Self.port)!
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: port)
            // The endpoint already specifies the port; passing it again is rejected by Network.framework.
            let listener = try NWListener(using: parameters)
            self.listener = listener
            listener.stateUpdateHandler = { [weak self] state in
                NSLog("AutoDisplay browser bridge: %@", String(describing: state))
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.onStatus?(nil)
                    case .failed(let error): self?.onStatus?("浏览器连接服务不可用：\(error.localizedDescription)")
                    case .waiting(let error): self?.onStatus?("等待本机连接：\(error.localizedDescription)")
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self = self else { return }
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
                self.queue.asyncAfter(deadline: .now() + 4) { connection.cancel() }
            }
            listener.start(queue: queue)
        } catch { onStatus?("浏览器连接端口已被占用") }
    }

    func stop() { listener?.cancel(); listener = nil }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self = self else { connection.cancel(); return }
            var data = accumulated
            if let chunk = chunk { data.append(chunk) }
            switch HTTPParser.parse(data) {
            case .incomplete:
                if complete || error != nil { connection.cancel() }
                else { self.receive(connection, accumulated: data) }
            case .invalid:
                self.send(.json(["error": "请求无效"], status: 400), via: connection)
            case .request(let request):
                DispatchQueue.main.async {
                    if request.method == "OPTIONS" {
                        guard request.headers["origin"] == "chrome-extension://\(self.extensionID)" else {
                            self.send(.json(["error": "来源不受信任"], status: 403), via: connection)
                            return
                        }
                        self.send(HTTPResponse(status: 204, body: Data()), via: connection)
                    } else {
                        let response = self.onRequest?(request) ?? .json(["error": "服务未准备好"], status: 503)
                        self.send(response, via: connection)
                    }
                }
            }
        }
    }

    private func send(_ response: HTTPResponse, via connection: NWConnection) {
        let names = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized",
                     403: "Forbidden", 404: "Not Found", 409: "Conflict", 503: "Unavailable"]
        let header = "HTTP/1.1 \(response.status) \(names[response.status] ?? "Error")\r\n" +
            "Content-Type: \(response.contentType)\r\nContent-Length: \(response.body.count)\r\n" +
            "Cache-Control: no-store\r\nConnection: close\r\n" +
            "Access-Control-Allow-Origin: chrome-extension://\(extensionID)\r\n" +
            "Access-Control-Allow-Methods: POST, OPTIONS\r\n" +
            "Access-Control-Allow-Headers: Content-Type, X-AutoDisplay-Extension, X-AutoDisplay-Client, X-AutoDisplay-Token\r\n\r\n"
        var data = Data(header.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    static let pairingHTML = """
    <!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta name="viewport" content="width=device-width">
    <title>连接 AutoDisplay</title><style>
    body{font:16px -apple-system,BlinkMacSystemFont,sans-serif;background:#f5f5f7;color:#1d1d1f;padding:8vh 24px}
    main{max-width:540px;margin:auto;background:white;border-radius:18px;padding:36px;box-shadow:0 8px 32px #00000008}
    h1{font-size:26px}p{line-height:1.7;color:#555}button{font:inherit;background:#0674e8;color:white;border:0;border-radius:9px;padding:12px 22px;cursor:pointer}
    #autodisplay-result{padding-top:12px;line-height:1.7}.note{font-size:13px;color:#777}
    </style><main><h1>连接 AutoDisplay</h1><p>连接后，全屏视频会使用观影亮度，退出全屏时恢复日常亮度。</p>
    <div id="autodisplay-connect"><p>如果这里没有连接按钮，请先加载浏览器扩展，再刷新本页。</p></div>
    <div id="autodisplay-result" role="status"></div><p class="note">扩展只向本机报告视频是否全屏，不发送网页内容、网址或视频标题。</p>
    <p class="note">扩展文件夹：菜单栏 AutoDisplay → 浏览器扩展文件夹。加载后，回到菜单栏选择连接当前浏览器。</p></main></html>
    """
}
