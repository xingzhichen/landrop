import Foundation
import Network
import Darwin

/// A single-page, plain-HTTP download server. Create a separate instance for each page.
/// Call its public API on the main actor; Network callbacks and file I/O run on a private queue.
@MainActor
final class TransferServer {
    private(set) var port: UInt16?
    var onPortChange: ((UInt16?) -> Void)?

    private var runtime: Runtime?

    func start(pageID: UUID, title: String, files: [SharedFile], preferredPort: UInt16?) throws {
        let parameters = NWParameters.tcp
        // Port 0 asks the OS for an available port. Do not bind to loopback: phones on
        // the same LAN must be able to connect to the Mac's network address.
        let requestedPort = NWEndpoint.Port(rawValue: preferredPort ?? 0) ?? .any
        let listener = try NWListener(using: parameters, on: requestedPort)
        let snapshot = PageSnapshot(
            pageID: pageID,
            title: title,
            files: files.map { FileEntry(id: $0.id, name: $0.name, path: $0.path,
                                          bookmarkData: $0.bookmarkData) }
        )

        stop()
        let runtime = Runtime(listener: listener, page: snapshot)
        self.runtime = runtime

        listener.stateUpdateHandler = { [weak self, weak runtime] state in
            guard let runtime else { return }
            switch state {
            case .ready:
                let boundPort = runtime.listener.port?.rawValue
                Task { @MainActor [weak self, weak runtime] in
                    guard let self, let runtime, self.runtime === runtime else { return }
                    self.port = boundPort
                    self.onPortChange?(boundPort)
                }
            case .failed, .cancelled:
                runtime.shutdown()
                Task { @MainActor [weak self, weak runtime] in
                    guard let self, let runtime, self.runtime === runtime else { return }
                    self.stop()
                }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak runtime] connection in
            runtime?.accept(connection)
        }
        listener.start(queue: runtime.queue)
    }

    func stop() {
        guard let runtime else { return }
        self.runtime = nil // Invalidate ready/failed callbacks already enqueued on the main actor.
        port = nil
        onPortChange?(nil)
        runtime.shutdown()
    }

    deinit {
        // A detached listener must not retain the page or leave its socket open.
        runtime?.shutdown()
    }
}

private struct FileEntry: Sendable {
    let id: UUID
    let name: String
    let path: String
    let bookmarkData: Data?
}

private struct PageSnapshot: Sendable {
    let pageID: UUID
    let title: String
    let files: [FileEntry]
}

/// All mutable state other than TransferServer.port is confined to `queue`.
private final class Runtime: @unchecked Sendable {
    let listener: NWListener
    let page: PageSnapshot
    let queue = DispatchQueue(label: "LanDrop.TransferServer.http")
    private var active = true
    private var sessions: [UUID: HTTPConnection] = [:]

    init(listener: NWListener, page: PageSnapshot) {
        self.listener = listener
        self.page = page
    }

    func accept(_ connection: NWConnection) {
        // NWListener invokes this handler on queue.
        guard active else { connection.cancel(); return }
        let id = UUID()
        let session = HTTPConnection(connection: connection, queue: queue, page: page) { [weak self] in
            self?.sessions.removeValue(forKey: id)
        }
        sessions[id] = session
        session.start()
    }

    func shutdown() {
        queue.async { [self] in
            guard active else { return }
            active = false
            listener.cancel()
            // close() removes its entry through onFinish; never mutate during iteration.
            let openSessions = Array(sessions.values)
            for session in openSessions { session.close() }
            sessions.removeAll()
        }
    }
}

/// One HTTP/1.1 request per TCP connection; responses always use Connection: close.
/// The serial queue owns the read buffer, file handle and send state.
private final class HTTPConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let page: PageSnapshot
    private let onFinish: () -> Void
    private var requestBuffer = Data()
    private var fileHandle: FileHandle?
    private var scopedURL: URL?
    private var remaining: UInt64 = 0
    private var closed = false
    private static let maximumHeaderBytes = 16 * 1024
    private static let chunkBytes = 64 * 1024

    init(connection: NWConnection, queue: DispatchQueue, page: PageSnapshot,
         onFinish: @escaping () -> Void) {
        self.connection = connection
        self.queue = queue
        self.page = page
        self.onFinish = onFinish
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: self.receiveHeader()
            case .failed, .cancelled: self.close()
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        fileHandle?.closeFile()
        fileHandle = nil
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        onFinish()
    }

    private func receiveHeader() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maximumHeaderBytes) {
            [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.requestBuffer.append(data) }
            if let end = self.requestBuffer.range(of: Data("\r\n\r\n".utf8)) {
                guard end.upperBound <= Self.maximumHeaderBytes else {
                    self.respond(431, "Request Header Fields Too Large", head: false); return
                }
                self.handleRequest(self.requestBuffer.subdata(in: 0..<end.upperBound))
            } else if self.requestBuffer.count >= Self.maximumHeaderBytes {
                self.respond(431, "Request Header Fields Too Large", head: false)
            } else if error != nil || isComplete {
                self.close()
            } else {
                self.receiveHeader()
            }
        }
    }

    private func handleRequest(_ header: Data) {
        guard let text = String(data: header, encoding: .utf8), !text.contains("\0") else {
            respond(400, "Bad Request", head: false); return
        }
        let lines = text.components(separatedBy: "\r\n")
        let requestLine = lines[0].components(separatedBy: " ")
        guard requestLine.count == 3, requestLine[2] == "HTTP/1.1" || requestLine[2] == "HTTP/1.0" else {
            respond(400, "Bad Request", head: false); return
        }
        let method = requestLine[0]
        let head = method == "HEAD"
        guard method == "GET" || head else {
            respond(405, "Method Not Allowed", head: false,
                    headers: ["Allow: GET, HEAD"]); return
        }
        var ranges: [String] = []
        for line in lines.dropFirst() where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else {
                respond(400, "Bad Request", head: head); return
            }
            if line[..<colon].lowercased() == "range" {
                ranges.append(String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        guard ranges.count <= 1 else {
            respond(400, "Bad Request", head: head); return
        }

        let path = requestLine[1]
        if path == "/" {
            let html = Self.html(page: page)
            sendHeader(status: "200 OK", length: UInt64(html.count), type: "text/html; charset=utf-8") {
                [weak self] in
                guard let self else { return }
                if head { self.close() } else { self.send(html) { [weak self] in self?.close() } }
            }
            return
        }

        let prefix = "/file/"
        guard path.hasPrefix(prefix) else {
            respond(404, "Not Found", head: head); return
        }
        let component = String(path.dropFirst(prefix.count))
        // No decoding, query string, slash, alternate UUID spelling, or user-supplied path.
        guard let id = UUID(uuidString: component),
              id.uuidString.lowercased() == component.lowercased(),
              let file = page.files.first(where: { $0.id == id }) else {
            respond(404, "Not Found", head: head); return
        }
        sendFile(file, head: head, range: ranges.first)
    }

    private func sendFile(_ file: FileEntry, head: Bool, range: String?) {
        let pathURL = URL(fileURLWithPath: file.path).standardizedFileURL
        var openURL = pathURL
        // A bookmark can grant sandbox access, but never allow it to substitute a
        // different file for the explicit path saved in this page's snapshot.
        if let bookmark = file.bookmarkData {
            var stale = false
            if let bookmarked = try? URL(resolvingBookmarkData: bookmark,
                                         options: [.withSecurityScope], relativeTo: nil,
                                         bookmarkDataIsStale: &stale),
               bookmarked.resolvingSymlinksInPath().path == pathURL.resolvingSymlinksInPath().path,
               bookmarked.startAccessingSecurityScopedResource() {
                openURL = bookmarked
                scopedURL = bookmarked
            }
        }
        do {
            let handle = try FileHandle(forReadingFrom: openURL)
            var info = stat()
            guard fstat(handle.fileDescriptor, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_size >= 0 else {
                handle.closeFile()
                respond(404, "Not Found", head: head)
                return
            }
            fileHandle = handle
            let size = UInt64(info.st_size)
            var offset: UInt64 = 0
            var length = size
            var status = "200 OK"
            var headers = ["Content-Disposition: attachment; filename=\"download\"; filename*=UTF-8''\(Self.encodedFilename(file.name))"]
            if let range {
                guard let selected = Self.parseRange(range, size: size) else {
                    respond(416, "Range Not Satisfiable", head: head,
                            headers: ["Content-Range: bytes */\(size)"])
                    return
                }
                offset = selected.lowerBound
                length = selected.upperBound - selected.lowerBound + 1
                status = "206 Partial Content"
                headers.append("Content-Range: bytes \(selected.lowerBound)-\(selected.upperBound)/\(size)")
            }
            try handle.seek(toOffset: offset)
            remaining = length
            headers.append("Accept-Ranges: bytes")
            sendHeader(status: status, length: length, type: "application/octet-stream", headers: headers) {
                [weak self] in
                guard let self else { return }
                if head { self.close() } else { self.sendNextChunk() }
            }
        } catch {
            respond(404, "Not Found", head: head)
        }
    }

    private static func parseRange(_ value: String, size: UInt64) -> ClosedRange<UInt64>? {
        guard size > 0, value.hasPrefix("bytes=") else { return nil }
        let parts = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty {
            guard let suffix = UInt64(parts[1]), suffix > 0 else { return nil }
            return (size - min(suffix, size))...(size - 1)
        }
        guard let start = UInt64(parts[0]), start < size else { return nil }
        if parts[1].isEmpty { return start...(size - 1) }
        guard let end = UInt64(parts[1]), end >= start else { return nil }
        return start...min(end, size - 1)
    }

    private func sendNextChunk() {
        guard !closed else { return }
        guard remaining > 0 else { close(); return }
        do {
            let count = Int(min(remaining, UInt64(Self.chunkBytes)))
            guard let bytes = try fileHandle?.read(upToCount: count), !bytes.isEmpty else {
                close() // The file was truncated while being transferred.
                return
            }
            remaining -= UInt64(bytes.count)
            send(bytes) { [weak self] in self?.sendNextChunk() }
        } catch {
            close()
        }
    }

    private func respond(_ code: Int, _ reason: String, head: Bool,
                         headers: [String] = []) {
        let body = Data("\(code) \(reason)\n".utf8)
        sendHeader(status: "\(code) \(reason)", length: UInt64(body.count),
                   type: "text/plain; charset=utf-8", headers: headers) { [weak self] in
            guard let self else { return }
            if head { self.close() } else { self.send(body) { [weak self] in self?.close() } }
        }
    }

    private func sendHeader(status: String, length: UInt64, type: String,
                            headers: [String] = [], completed: @escaping () -> Void) {
        let lines = (["HTTP/1.1 \(status)", "Content-Type: \(type)",
                      "Content-Length: \(length)", "Connection: close",
                      "Cache-Control: no-store", "X-Content-Type-Options: nosniff"] + headers)
            .joined(separator: "\r\n") + "\r\n\r\n"
        send(Data(lines.utf8), completed: completed)
    }

    private func send(_ bytes: Data, completed: @escaping () -> Void) {
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, !self.closed else { return }
            if error != nil { self.close() } else { completed() }
        })
    }

    private static func encodedFilename(_ name: String) -> String {
        let safeName = name.isEmpty ? "download" : name
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~".utf8)
        return safeName.utf8.map { byte in
            allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
        }.joined()
    }

    private static func escapedHTML(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func html(page: PageSnapshot) -> Data {
        let items = page.files.map { file in
            """
            <li class="file-card">
              <a class="file-link" href="/file/\(file.id.uuidString)" download>
                <span class="file-icon" aria-hidden="true">
                  <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3v12m0 0 4-4m-4 4-4-4"/><path d="M4 16v3a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-3"/></svg>
                </span>
                <span class="file-info"><span class="file-name">\(escapedHTML(file.name))</span><span class="file-caption">点击下载到设备</span></span>
                <span class="file-arrow" aria-hidden="true">↗</span>
              </a>
            </li>
            """
        }.joined(separator: "\n")
        let fileList = page.files.isEmpty
            ? "<p class=\"empty-state\">这里还没有文件，请在 Mac 上添加文件后刷新页面。</p>"
            : "<ul class=\"file-list\">\(items)</ul>"
        let document = """
        <!doctype html>
        <html lang="zh-CN">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
          <meta name="theme-color" content="#7662e9">
          <title>\(escapedHTML(page.title))</title>
          <style>
            :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-synthesis:none}
            *{box-sizing:border-box}
            body{margin:0;min-height:100vh;min-height:100dvh;background:#f5f6fc;color:#22223b;-webkit-font-smoothing:antialiased}
            .page{width:min(100% - 32px,720px);margin:0 auto;padding:36px 0 max(56px,env(safe-area-inset-bottom))}
            .hero{position:relative;isolation:isolate;overflow:hidden;min-height:240px;padding:38px 40px;border-radius:30px;background:linear-gradient(125deg,#6452db 0%,#8666ee 55%,#ac80f5 100%);color:#fff;box-shadow:0 22px 50px rgba(90,69,182,.23)}
            .hero::before,.hero::after{content:"";position:absolute;z-index:-1;border-radius:50%;pointer-events:none}
            .hero::before{width:260px;height:260px;right:-50px;top:-120px;background:rgba(255,255,255,.12)}
            .hero::after{width:190px;height:190px;right:85px;bottom:-145px;border:35px solid rgba(255,255,255,.12)}
            .eyebrow{display:inline-flex;align-items:center;gap:8px;margin:0 0 27px;padding:7px 12px;border:1px solid rgba(255,255,255,.4);border-radius:999px;background:rgba(255,255,255,.13);font-size:12px;font-weight:650;letter-spacing:.08em}
            .eyebrow::before{content:"";width:7px;height:7px;border-radius:50%;background:#c5ffe3;box-shadow:0 0 0 3px rgba(197,255,227,.2)}
            h1{max-width:580px;margin:0;font-size:clamp(28px,5vw,39px);line-height:1.2;letter-spacing:-.035em;overflow-wrap:anywhere}
            .hero-subtitle{margin:14px 0 0;color:rgba(255,255,255,.86);font-size:14px;line-height:1.6}
            .section-head{display:flex;align-items:baseline;justify-content:space-between;gap:16px;margin:32px 2px 17px}
            h2{margin:0;font-size:18px;letter-spacing:-.02em}
            .count{margin:0;color:#777890;font-size:13px;white-space:nowrap}
            .file-list{display:grid;gap:12px;margin:0;padding:0;list-style:none}
            .file-card{min-width:0;border:1px solid #e9e9f3;border-radius:20px;background:#fff;box-shadow:0 5px 20px rgba(44,43,91,.045);animation:rise-in .55s both}
            .file-card:nth-child(2){animation-delay:.07s}.file-card:nth-child(3){animation-delay:.14s}.file-card:nth-child(n+4){animation-delay:.2s}
            .file-link{display:flex;align-items:center;gap:16px;min-width:0;min-height:88px;padding:16px 20px;border-radius:inherit;color:inherit;text-decoration:none;transition:transform .2s,box-shadow .2s}
            .file-link:hover{transform:translateY(-2px);box-shadow:0 12px 28px rgba(88,73,167,.12)}
            .file-link:focus-visible{outline:3px solid #6957dd;outline-offset:3px}
            .file-icon{display:grid;flex:none;place-items:center;width:48px;height:48px;border-radius:15px;background:#f0edff;color:#7259df}
            .file-icon svg{width:23px;height:23px}
            .file-info{display:grid;min-width:0;gap:5px;flex:1}
            .file-name{font-size:15px;font-weight:650;line-height:1.4;overflow-wrap:anywhere}
            .file-caption{color:#85859b;font-size:12px}
            .file-arrow{flex:none;color:#8a80bc;font-size:20px;line-height:1}
            .empty-state{margin:0;padding:30px 20px;border:1px dashed #d8d5ed;border-radius:20px;color:#777890;text-align:center;line-height:1.6}
            .footnote{margin:26px 0 0;color:#9292a6;font-size:12px;line-height:1.6;text-align:center}
            .toast{position:fixed;z-index:10;left:50%;bottom:max(24px,env(safe-area-inset-bottom));width:max-content;max-width:calc(100% - 32px);padding:12px 18px;border-radius:12px;background:#25243c;color:#fff;box-shadow:0 12px 30px rgba(0,0,0,.18);font-size:13px;text-align:center;opacity:0;transform:translate(-50%,12px);pointer-events:none;transition:opacity .2s,transform .2s}
            .toast.is-visible{opacity:1;transform:translate(-50%,0)}
            @keyframes rise-in{from{opacity:0;transform:translateY(14px)}to{opacity:1;transform:translateY(0)}}
            @media(max-width:540px){.page{width:min(100% - 28px,720px);padding-top:16px}.hero{min-height:225px;padding:30px 25px;border-radius:24px}.eyebrow{margin-bottom:24px}.section-head{margin-top:30px}.file-link{min-height:80px;padding:14px}.file-icon{width:44px;height:44px}.file-link{gap:12px}}
            @media(prefers-color-scheme:dark){body{background:#11121e;color:#f0eff9}.hero{box-shadow:0 22px 50px rgba(0,0,0,.25)}.count,.empty-state{color:#a6a5bb}.file-card{background:#1e1e30;border-color:#34334c;box-shadow:none}.file-icon{background:#353052;color:#baa9ff}.file-caption,.file-arrow{color:#aaa7c3}.empty-state{border-color:#47445e}.footnote{color:#9693ad}.toast{background:#eeebff;color:#24213d}}
            @media(prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:.01ms!important;animation-iteration-count:1!important;scroll-behavior:auto!important;transition-duration:.01ms!important}.file-link:hover{transform:none}}
          </style>
        </head>
        <body>
          <main class="page">
            <header class="hero"><p class="eyebrow">LANDROP · 文件分享</p><h1>\(escapedHTML(page.title))</h1><p class="hero-subtitle">文件已就绪，点击下方卡片即可保存到你的设备。</p></header>
            <section aria-labelledby="files-heading"><div class="section-head"><h2 id="files-heading">分享的文件</h2><p class="count">共 \(page.files.count) 个文件</p></div>\(fileList)</section>
            <p class="footnote">请保持此设备与 Mac 处于同一网络，直到下载完成。</p>
          </main>
          <div class="toast" role="status" aria-live="polite" aria-atomic="true"></div>
          <script type="text/javascript">
            (() => {
              const toast = document.querySelector('.toast');
              let timer;
              document.querySelector('.file-list')?.addEventListener('click', (event) => {
                if (!event.target.closest('a.file-link')) return;
                toast.textContent = '下载已开始，请在浏览器中查看进度';
                toast.classList.add('is-visible');
                clearTimeout(timer);
                timer = setTimeout(() => toast.classList.remove('is-visible'), 3000);
              });
            })();
          </script>
        </body>
        </html>
        """
        return Data(document.utf8)
    }
}
