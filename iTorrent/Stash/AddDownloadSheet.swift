//
//  AddDownloadSheet.swift
//  Stash
//
//  The + sheet: paste a file link, a web page or a magnet link.
//

import LibTorrent
import SwiftUI
import UIKit

struct AddDownloadSheet: View {
    var initialText: String
    var onSubmit: (URL) -> String?
    var onClose: () -> Void

    @State private var text = ""
    @State private var error: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New download").sLabel(12)
                    Text("Paste a link")
                        .font(.sDisplay(30, .heavy))
                        .tracking(-0.8)
                        .foregroundStyle(Color.sText)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.sText)
                        .frame(width: 40, height: 40)
                        .background(Color.sS1)
                        .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }

            HStack(spacing: 10) {
                Image(systemName: "link").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(focused ? Color.sMint : Color.sText3)
                TextField("https://… or magnet:?…", text: $text)
                    .font(.sInter(16, .medium))
                    .foregroundStyle(Color.sText)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($focused)
                    .onSubmit(submit)
                if text.isEmpty {
                    Button("Paste") {
                        text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    }
                    .font(.sMono(12, .bold))
                    .foregroundStyle(Color.sMint)
                } else {
                    Button { text = "" } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.sText2)
                            .frame(width: 28, height: 28).background(Color.sS3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear")
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 54)
            .background(Color.sS1)
            .overlay(Rectangle().strokeBorder(error != nil ? Color.sCoral : focused ? Color.sMint : Color.sLine, lineWidth: 1))

            if let error {
                Text(error).font(.sInter(13)).foregroundStyle(Color.sCoral)
            }

            VStack(alignment: .leading, spacing: 8) {
                hint("film", "Web page", "Stash finds the video on the page and remembers the page.")
                hint("doc", "File link", "Downloads with up to 16 parallel connections.")
                hint("point.3.connected.trianglepath.dotted", "Magnet", "Starts a torrent.")
            }

            Spacer(minLength: 0)

            BoxButton(title: "Download", systemImage: "arrow.down", prominent: true, action: submit)
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(text.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
        .padding(20)
        .background(Color.sBg.ignoresSafeArea())
        .onAppear {
            text = initialText
            focused = initialText.isEmpty
        }
    }

    private func hint(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.sText3).frame(width: 18)
            Text(title).font(.sMono(12, .bold)).textCase(.uppercase).foregroundStyle(Color.sText2)
            Text(detail).font(.sInter(14)).foregroundStyle(Color.sText3)
        }
    }

    private func submit() {
        guard let url = SharedDownloadInbox.link(in: text) else {
            error = "Enter a valid web, file or magnet link."
            return
        }
        error = onSubmit(url)
    }
}

extension UIViewController {
    /// Presents the + sheet and starts the download it returns.
    func presentAddDownloadSheet() {
        let clipboard = UIPasteboard.general.hasStrings
            ? UIPasteboard.general.string.flatMap { SharedDownloadInbox.link(in: $0) }?.absoluteString ?? ""
            : ""
        weak var host: UIHostingController<AddDownloadSheet>?
        let sheet = AddDownloadSheet(initialText: clipboard, onSubmit: { url in
            if url.scheme?.lowercased() == "magnet" {
                guard let magnet = MagnetURI(with: url) else { return "This magnet link is not valid." }
                guard !TorrentService.shared.checkTorrentExists(with: magnet.infoHashes) else {
                    return "This torrent is already in your downloads."
                }
                TorrentService.shared.addTorrent(by: magnet)
            } else {
                Task { @MainActor in _ = await FileDownloadService.shared.add(SharedLink(url: url)) }
            }
            host?.dismiss(animated: true)
            return nil
        }, onClose: {
            host?.dismiss(animated: true)
        })
        let controller = UIHostingController(rootView: sheet)
        host = controller
        controller.view.backgroundColor = SColor.bg
        if let presentation = controller.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }
}
