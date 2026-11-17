import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

@main
struct LanDropApp: App {
    @StateObject private var store = TransferStore()

    var body: some Scene {
        WindowGroup("LanDrop") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 610)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建传输页面") { NotificationCenter.default.post(name: .newTransferPage, object: nil) }
                    .keyboardShortcut("n")
            }
        }
    }
}

extension Notification.Name { static let newTransferPage = Notification.Name("NewTransferPage") }

private enum Palette {
    static let blue = Color(red: 0.27, green: 0.41, blue: 0.94)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let pane = Color(nsColor: .controlBackgroundColor)
}

struct ContentView: View {
    @EnvironmentObject private var store: TransferStore
    @State private var showingCreate = false
    @State private var deletingID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 272)
            Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
            if let page = store.selectedPage {
                detail(page)
            } else {
                emptyState
            }
        }
        .background(Palette.background)
        .sheet(isPresented: $showingCreate) { CreatePageSheet { title, files in
            store.create(title: title, files: files)
        } }
        .alert("删除传输页面？", isPresented: Binding(
            get: { deletingID != nil },
            set: { if !$0 { deletingID = nil } }
        )) {
            Button("取消", role: .cancel) { deletingID = nil }
            Button("删除", role: .destructive) {
                if let deletingID { store.delete(deletingID) }
                deletingID = nil
            }
        } message: {
            Text("此操作只删除分享页面，不会删除电脑上的原始文件。")
        }
        .onReceive(NotificationCenter.default.publisher(for: .newTransferPage)) { _ in showingCreate = true }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up.on.square.fill")
                    .font(.system(size: 23)).foregroundStyle(Palette.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("LanDrop").font(.system(size: 19, weight: .bold))
                    Text("局域网文件传输").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20).padding(.top, 27).padding(.bottom, 27)

            Button { showingCreate = true } label: {
                Label("新建传输页面", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 9)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.blue)
            .padding(.horizontal, 17)

            HStack {
                Text("我的页面").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text("\(store.pages.count)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 21).padding(.top, 32).padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(store.pages) { page in
                        Button { store.selectedID = page.id } label: {
                            HStack(spacing: 11) {
                                Image(systemName: "doc.on.doc.fill")
                                    .font(.system(size: 17))
                                    .foregroundStyle(store.selectedID == page.id ? Palette.blue : .secondary)
                                    .frame(width: 27)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(page.title).font(.system(size: 13, weight: .semibold))
                                        .lineLimit(1)
                                    Text("\(page.files.count) 个文件 · \(page.isRunning ? "运行中" : "已停止")")
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Circle().fill(page.isRunning && store.livePorts[page.id] != nil ? .green : .gray)
                                    .frame(width: 7, height: 7)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 11)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(store.selectedID == page.id ? Palette.blue.opacity(0.11) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10)
                    }
                }
            }

            Divider().padding(.horizontal, 17)
            HStack(spacing: 7) {
                Image(systemName: "wifi")
                Text(store.localAddress.map { "局域网 IP：\($0)" } ?? "尚未连接局域网")
                Spacer()
                Button { store.refreshAddress() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("刷新网络地址")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(17)
        }
        .background(Palette.pane.opacity(0.55))
    }

    private var emptyState: some View {
        VStack(spacing: 17) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 65, weight: .ultraLight)).foregroundStyle(Palette.blue)
            Text("让文件在手机上触手可及")
                .font(.system(size: 24, weight: .bold))
            Text("选择电脑上的文件，生成专属下载网页。\n手机连接同一 Wi-Fi 后，扫码即可下载。")
                .font(.system(size: 14)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineSpacing(5)
            Button("新建传输页面") { showingCreate = true }
                .buttonStyle(.borderedProminent).tint(Palette.blue)
                .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func detail(_ page: TransferPage) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 23) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(page.title).font(.system(size: 28, weight: .bold)).textSelection(.enabled)
                        Text("创建于 \(page.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Circle().fill(page.isRunning && store.livePorts[page.id] != nil ? .green : .gray)
                            .frame(width: 8, height: 8)
                        Text(!page.isRunning ? "已停止" :
                             store.errors[page.id] != nil ? "启动失败" :
                             store.livePorts[page.id] == nil ? "启动中" : "正在分享")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Palette.pane, in: Capsule())
                }

                accessCard(page)

                VStack(alignment: .leading, spacing: 13) {
                    HStack {
                        Text("分享的文件").font(.system(size: 16, weight: .semibold))
                        Text("\(page.files.count)").foregroundStyle(.secondary)
                        Spacer()
                    }
                    ForEach(page.files) { file in
                        HStack(spacing: 12) {
                            Image(systemName: "doc.fill").foregroundStyle(Palette.blue)
                                .frame(width: 34, height: 34)
                                .background(Palette.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text(file.path).font(.system(size: 11)).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }
                        .padding(11)
                        .background(Palette.pane.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                    }
                }

                HStack(spacing: 9) {
                    if page.isRunning {
                        Button { store.stop(page.id) } label: { Label("停止分享", systemImage: "stop.fill") }
                    } else {
                        Button { store.restart(page.id) } label: { Label("启动分享", systemImage: "play.fill") }
                            .buttonStyle(.borderedProminent).tint(Palette.blue)
                    }
                    Button { store.restart(page.id) } label: { Label("重启", systemImage: "arrow.clockwise") }
                    Spacer()
                    Button(role: .destructive) { deletingID = page.id } label: {
                        Label("删除页面", systemImage: "trash")
                    }
                }
                .controlSize(.large)
                .padding(.top, 3)
            }
            .padding(32)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private func accessCard(_ page: TransferPage) -> some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 11) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 21)).foregroundStyle(Palette.blue)
                Text("扫码下载").font(.system(size: 19, weight: .bold))
                Text("手机与电脑连接同一 Wi-Fi，使用手机相机扫描右侧二维码，即可在浏览器中打开文件下载页面。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                if let url = store.url(for: page) {
                    Text(url.absoluteString)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Palette.blue).textSelection(.enabled)
                        .padding(.top, 7)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) } label: {
                        Label("复制链接", systemImage: "doc.on.doc")
                    }
                } else if let error = store.errors[page.id] {
                    Text(error).foregroundStyle(.red).font(.system(size: 12))
                } else {
                    Text(page.isRunning ? "正在生成访问链接…" : "启动分享后显示二维码与链接")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 10)
            Group {
                if let url = store.url(for: page), let image = QRCode.image(for: url.absoluteString) {
                    Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                } else {
                    Image(systemName: "qrcode").resizable().scaledToFit()
                        .foregroundStyle(.gray.opacity(0.3)).padding(30)
                }
            }
            .frame(width: 160, height: 160)
            .padding(12)
            .background(.white, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(23)
        .background(Palette.pane, in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum QRCode {
    static func image(for value: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
                                                      from: output.extent.applying(CGAffineTransform(scaleX: 10, y: 10))) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

private struct CreatePageSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreate: (String, [SharedFile]) -> Void
    @State private var title = ""
    @State private var files: [SharedFile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "plus.square.fill").font(.system(size: 27)).foregroundStyle(Palette.blue)
                Text("新建传输页面").font(.system(size: 21, weight: .bold))
            }
            Text("为这组文件起一个名字，选择要分享给手机的文件。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 7) {
                Text("页面名称").font(.system(size: 12, weight: .semibold))
                TextField("例如：旅行照片", text: $title).textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("文件").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { chooseFiles() } label: { Label("选择文件", systemImage: "plus") }
            }
            ScrollView {
                if files.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.badge.plus").font(.system(size: 30)).foregroundStyle(.tertiary)
                        Text("尚未选择文件，可一次选择多个")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 35)
                } else {
                    LazyVStack(spacing: 7) {
                        ForEach(files) { file in
                            HStack {
                                Image(systemName: "doc").foregroundStyle(Palette.blue)
                                Text(file.name).lineLimit(1)
                                Spacer()
                                Button { files.removeAll(where: { $0.id == file.id }) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }.buttonStyle(.plain)
                            }
                            .padding(9)
                            .background(Palette.pane, in: RoundedRectangle(cornerRadius: 7))
                        }
                    }
                }
            }
            .frame(height: 156)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                Button("创建并启动") {
                    onCreate(title, files)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).tint(Palette.blue)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || files.isEmpty)
            }
        }
        .padding(28)
        .frame(width: 480)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "添加文件"
        guard panel.runModal() == .OK else { return }
        let existing = Set(files.map(\.path))
        files.append(contentsOf: panel.urls.filter { !existing.contains($0.path) }.map(SharedFile.init(url:)))
    }
}
