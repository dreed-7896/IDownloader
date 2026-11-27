//
//  AddDownloadSheet.swift
//  Drift
//
//  The + sheet: paste a web page, a file link or a magnet link.
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

    private var isEmpty: Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New download")
                        .font(.sDisplay(28, .heavy))
                        .tracking(-0.6)
                        .foregroundStyle(Color.sText)
                    Text("Paste a web page, file or magnet link")
                        .font(.sInter(14))
                        .foregroundStyle(Color.sText3)
                }
                Spacer()
                DriftCircleButton(icon: .stop, label: "Close", size: 38, action: onClose)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Icon.link.view(20)
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
                        Button {
                            text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        } label: {
                            HStack(spacing: 5) {
                                Icon.copy.view(14)
                                Text("Paste").font(.sInter(13, .semibold))
                            }
                            .foregroundStyle(Color.sMint)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().fill(Color.sMint.opacity(0.14)))
                        }
                        .buttonStyle(PressedOpacityStyle())
                    } else {
                        Button { text = "" } label: {
                            Icon.stop.view(12)
                                .foregroundStyle(Color.sText2)
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.sS3))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear")
                    }
                }
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: 56)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.sS1))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(error != nil ? Color.sCoral : focused ? Color.sMint : Color.white.opacity(0.08),
                                      lineWidth: error != nil || focused ? 1.5 : 1)
                )
                .animation(.easeOut(duration: 0.15), value: focused)

                if let error {
                    HStack(spacing: 6) {
                        Icon.alert.view(14)
                        Text(error).font(.sInter(13))
                    }
                    .foregroundStyle(Color.sCoral)
                    .padding(.leading, 4)
                }
            }

            VStack(spacing: 0) {
                hint(.video, "Web page", "Drift finds the video on the page and remembers the page.")
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 58)
                hint(.file, "File link", "Downloads with up to 16 parallel connections.")
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 58)
                hint(.magnet, "Magnet link", "Starts a torrent.")
            }
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.sS1))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))

            Spacer(minLength: 0)

            BoxButton(title: "Download", systemImage: "arrow.down", prominent: true, action: submit)
                .disabled(isEmpty)
                .opacity(isEmpty ? 0.5 : 1)
        }
        .padding(20)
        .background(Color.sBg.ignoresSafeArea())
        .onAppear {
            text = initialText
            focused = initialText.isEmpty
        }
    }

    private func hint(_ icon: Icon, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            icon.view(17)
                .foregroundStyle(Color.sMint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.sMint.opacity(0.12)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.sInter(15, .semibold)).foregroundStyle(Color.sText)
                Text(detail).font(.sInter(13)).foregroundStyle(Color.sText3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            // Tall enough for the field, the hints and the button without scrolling.
            let fit = UISheetPresentationController.Detent.custom(identifier: .init("drift.addDownload")) { context in
                min(500, context.maximumDetentValue)
            }
            presentation.detents = [fit, .large()]
            presentation.prefersGrabberVisible = true
        }
        present(controller, animated: true)
    }
}
