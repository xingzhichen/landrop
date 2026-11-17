import Foundation

// Standalone integration test: compiled together with TransferServer.swift.
struct SharedFile {
    let id: UUID
    let name: String
    let path: String
    let bookmarkData: Data?
}

@main
struct ServerSmoke {
    @MainActor
    static func main() async throws {
        let content = Data(repeating: 65, count: 150_000) + Data("\n传输成功\n".utf8)
        let file = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/smoke-file.txt")
        try content.write(to: file)
        let item = SharedFile(id: UUID(), name: "测试\"<文件>.txt", path: file.path, bookmarkData: nil)
        let server = TransferServer()
        try server.start(pageID: UUID(), title: "示例<script>alert(1)</script>", files: [item], preferredPort: nil)
        var attempts = 0
        while server.port == nil && attempts < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        guard let port = server.port else { fatalError("Server did not become ready") }
        let base = "http://127.0.0.1:\(port)"

        func request(_ path: String, method: String = "GET", range: String? = nil) async throws -> (Data, HTTPURLResponse) {
            var req = URLRequest(url: URL(string: base + path)!)
            req.httpMethod = method
            if let range { req.setValue(range, forHTTPHeaderField: "Range") }
            let (bytes, response) = try await URLSession.shared.data(for: req)
            return (bytes, response as! HTTPURLResponse)
        }
        let (home, homeResponse) = try await request("/")
        let html = String(decoding: home, as: UTF8.self)
        precondition(homeResponse.statusCode == 200 && html.contains("&lt;script&gt;") && !html.contains("<script>"))
        precondition(html.contains("测试&quot;&lt;文件&gt;.txt"))
        let (download, response) = try await request("/file/\(item.id.uuidString)")
        precondition(response.statusCode == 200 && download == content)
        precondition(response.value(forHTTPHeaderField: "Content-Disposition")?.contains("filename*=UTF-8''") == true)
        let (partial, partialResponse) = try await request("/file/\(item.id.uuidString)", range: "bytes=100-199")
        precondition(partialResponse.statusCode == 206 && partial == content.subdata(in: 100..<200))
        let (_, headResponse) = try await request("/file/\(item.id.uuidString)", method: "HEAD")
        precondition(headResponse.statusCode == 200 && headResponse.expectedContentLength == Int64(content.count))
        let (_, missing) = try await request("/file/\(UUID().uuidString)")
        precondition(missing.statusCode == 404)
        let (_, traversal) = try await request("/file/../../etc/passwd")
        precondition(traversal.statusCode == 404)
        let other = TransferServer()
        try other.start(pageID: UUID(), title: "另一个页面", files: [], preferredPort: nil)
        attempts = 0
        while other.port == nil && attempts < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        guard let otherPort = other.port else { fatalError("Other server did not become ready") }
        let (crossData, crossResponse) = try await URLSession.shared.data(from:
            URL(string: "http://127.0.0.1:\(otherPort)/file/\(item.id.uuidString)")!)
        precondition((crossResponse as! HTTPURLResponse).statusCode == 404 && !crossData.isEmpty)
        other.stop()
        server.stop()
        precondition(server.port == nil)
        try server.start(pageID: UUID(), title: "再次启动", files: [item], preferredPort: port)
        attempts = 0
        while server.port == nil && attempts < 100 {
            try await Task.sleep(nanoseconds: 50_000_000)
            attempts += 1
        }
        precondition(server.port == port, "Restart should preserve the published URL")
        server.stop()
        print("PASS: HTML escaping, full download, range, HEAD, 404, isolation, stop and restart")
    }
}
