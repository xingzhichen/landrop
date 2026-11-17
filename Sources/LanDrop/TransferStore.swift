import AppKit
import Foundation
import SwiftUI

struct SharedFile: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let path: String
    let bookmarkData: Data?

    init(url: URL) {
        id = UUID()
        name = url.lastPathComponent
        path = url.path
        bookmarkData = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

}

struct TransferPage: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var files: [SharedFile]
    var preferredPort: UInt16?
    var isRunning: Bool
    let createdAt: Date

    init(title: String, files: [SharedFile]) {
        id = UUID()
        self.title = title
        self.files = files
        preferredPort = nil
        isRunning = true
        createdAt = Date()
    }
}

@MainActor
final class TransferStore: ObservableObject {
    @Published private(set) var pages: [TransferPage] = []
    @Published private(set) var livePorts: [UUID: UInt16] = [:]
    @Published private(set) var errors: [UUID: String] = [:]
    @Published var selectedID: UUID?
    @Published private(set) var localAddress: String?

    private var servers: [UUID: TransferServer] = [:]
    private let storageURL: URL

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LanDrop", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        storageURL = directory.appendingPathComponent("pages.json")
        if let data = try? Data(contentsOf: storageURL),
           let saved = try? JSONDecoder().decode([TransferPage].self, from: data) {
            pages = saved
        }
        selectedID = pages.first?.id
        refreshAddress()
        for page in pages where page.isRunning { startServer(for: page) }
    }

    var selectedPage: TransferPage? { pages.first(where: { $0.id == selectedID }) }

    func refreshAddress() { localAddress = NetworkAddress.primaryIPv4() }

    func url(for page: TransferPage) -> URL? {
        guard let localAddress, let port = livePorts[page.id] else { return nil }
        return URL(string: "http://\(localAddress):\(port)/")
    }

    func create(title: String, files: [SharedFile]) {
        let page = TransferPage(title: title.trimmingCharacters(in: .whitespacesAndNewlines), files: files)
        pages.insert(page, at: 0)
        selectedID = page.id
        save()
        startServer(for: page)
    }

    func stop(_ id: UUID) {
        servers.removeValue(forKey: id)?.stop()
        livePorts[id] = nil
        errors[id] = nil
        if let index = pages.firstIndex(where: { $0.id == id }) {
            pages[index].isRunning = false
            save()
        }
    }

    func restart(_ id: UUID) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        servers.removeValue(forKey: id)?.stop()
        livePorts[id] = nil
        errors[id] = nil
        pages[index].isRunning = true
        save()
        startServer(for: pages[index])
    }

    func delete(_ id: UUID) {
        servers.removeValue(forKey: id)?.stop()
        livePorts[id] = nil
        errors[id] = nil
        pages.removeAll(where: { $0.id == id })
        if selectedID == id { selectedID = pages.first?.id }
        save()
    }

    private func startServer(for page: TransferPage) {
        let server = TransferServer()
        servers[page.id] = server
        server.onPortChange = { [weak self, weak server] port in
            guard let self, let server, self.servers[page.id] === server else { return }
            self.livePorts[page.id] = port
            if let port, let index = self.pages.firstIndex(where: { $0.id == page.id }) {
                self.errors[page.id] = nil
                self.pages[index].preferredPort = port
                self.save()
            } else if self.pages.first(where: { $0.id == page.id })?.isRunning == true {
                self.errors[page.id] = "服务未能启动，请点击重启。"
            }
        }
        do {
            try server.start(pageID: page.id, title: page.title, files: page.files, preferredPort: page.preferredPort)
        } catch {
            errors[page.id] = "启动失败：\(error.localizedDescription)"
            servers[page.id] = nil
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(pages) else { return }
        do { try data.write(to: storageURL, options: .atomic) }
        catch { NSLog("LanDrop: Could not save transfer pages: %@", error.localizedDescription) }
    }
}

private enum NetworkAddress {
    static func primaryIPv4() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }
        var candidates: [(String, String)] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let item = entry.pointee
            guard item.ifa_addr?.pointee.sa_family == UInt8(AF_INET),
                  item.ifa_flags & UInt32(IFF_UP) != 0,
                  item.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let name = String(validatingUTF8: item.ifa_name) else { continue }
            var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var raw = item.ifa_addr!.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            guard inet_ntop(AF_INET, &raw, &address, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            candidates.append((name, String(cString: address)))
        }
        return candidates.first(where: { $0.0 == "en0" })?.1 ??
               candidates.first(where: { $0.0.hasPrefix("en") })?.1 ?? candidates.first?.1
    }
}
