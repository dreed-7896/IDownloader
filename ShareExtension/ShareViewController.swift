import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private let addButton = UIButton(type: .system)
    private var urls: [URL] = []
    private var loading = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: 420, height: 260)
        let title = UILabel()
        title.text = "IDownloader"
        title.font = .preferredFont(forTextStyle: .title2)
        statusLabel.numberOfLines = 5
        statusLabel.font = .preferredFont(forTextStyle: .body)
        statusLabel.text = "Reading shared link…"
        addButton.setTitle("Start download", for: .normal)
        addButton.isEnabled = false
        addButton.addTarget(self, action: #selector(add), for: .touchUpInside)
        let close = UIButton(type: .system)
        close.setTitle("Cancel", for: .normal)
        close.addTarget(self, action: #selector(done), for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [title, statusLabel, addButton, close])
        stack.axis = .vertical
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16)
        ])
        readItems()
    }

    private func readItems() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        let group = DispatchGroup()
        for provider in providers {
            let type: String
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { type = UTType.url.identifier }
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) { type = UTType.plainText.identifier }
            else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { [weak self] value, _ in
                DispatchQueue.main.async {
                    defer { group.leave() }
                    guard let self else { return }
                    if let url = value as? URL, SharedDownloadInbox.supported(url) { self.urls.append(url) }
                    else if let text = value as? String { self.urls.append(contentsOf: SharedDownloadInbox.urls(in: text)) }
                    else if let data = value as? Data, let text = String(data: data, encoding: .utf8) { self.urls.append(contentsOf: SharedDownloadInbox.urls(in: text)) }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            var seen = Set<String>()
            self.urls = self.urls.filter { seen.insert($0.absoluteString).inserted }
            self.statusLabel.text = self.urls.isEmpty ? "Share an HTTP, HTTPS, or magnet link to download." : self.urls.map(\.absoluteString).joined(separator: "\n")
            self.addButton.isEnabled = !self.urls.isEmpty
        }
    }

    @objc private func add() {
        guard !loading else { return }
        loading = true
        addButton.isEnabled = false
        do {
            try SharedDownloadInbox.enqueue(urls)
            // The inbox survives extension termination and denied URL handoffs.
            extensionContext?.open(URL(string: "IDownloader://shared")!) { [weak self] opened in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if opened { self.done() }
                    else {
                        self.statusLabel.text = "Added to IDownloader. Open IDownloader to start your download."
                        if let stack = self.addButton.superview as? UIStackView,
                           let close = stack.arrangedSubviews.last as? UIButton { close.setTitle("Done", for: .normal) }
                    }
                }
            }
        } catch {
            loading = false
            addButton.isEnabled = true
            statusLabel.text = "Could not share this link: \(error.localizedDescription)"
        }
    }

    @objc private func done() { extensionContext?.completeRequest(returningItems: nil) }
}
