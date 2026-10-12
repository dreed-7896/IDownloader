import Combine
@preconcurrency import LocalAuthentication
import LibTorrent
import UIKit

extension Notification.Name {
    static let appDidUnlock = Notification.Name("appDidUnlock")
    static let appLockSettingsChanged = Notification.Name("appLockSettingsChanged")
    static let appLockConfigurationAuthentication = Notification.Name("appLockConfigurationAuthentication")
}

/// An opaque window covers every presented screen, including the player and app-switcher snapshot.
@MainActor
final class AppLockController {
    private weak var mainWindow: UIWindow?
    private var coverWindow: UIWindow?
    private var hasUnlocked = false
    private var awaySince: Date?
    private var authenticationInProgress = false
    private var configurationAuthentication = false
    private var attemptedAutomaticUnlock = false
    private var context: LAContext?
    private var subscriptions = Set<AnyCancellable>()
    private var preferences: PreferencesStorage { .shared }

    static var isAnySceneLocked: Bool {
        UIApplication.shared.connectedScenes.compactMap { ($0.delegate as? SceneDelegate)?.appLock }
            .contains { $0.requiresAuthentication }
    }

    init(window: UIWindow) {
        mainWindow = window
        NotificationCenter.default.publisher(for: .appLockSettingsChanged)
            .receive(on: DispatchQueue.main).sink { [weak self] event in
                guard let self else { return }
                if event.userInfo?["authenticated"] as? Bool == true { hasUnlocked = true; awaySince = nil }
                if !preferences.appLockEnabled || hasUnlocked { hideCover() }
            }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .appLockConfigurationAuthentication)
            .receive(on: DispatchQueue.main).sink { [weak self] event in
                guard let self else { return }
                configurationAuthentication = event.object as? Bool ?? false
                if !configurationAuthentication, hasUnlocked { hideCover() }
            }.store(in: &subscriptions)
        if preferences.appLockEnabled { showCover() }
    }

    private var downloading: Bool {
        if FileDownloadService.shared.downloads.contains(where: \.isActive) { return true }
        return TorrentService.shared.torrents.values.contains { handle in
            let snapshot = handle.snapshot
            return !snapshot.isPaused && !snapshot.isFinished
                && [.downloading, .downloadingMetadata, .checkingFiles, .checkingResumeData].contains(snapshot.friendlyState)
        }
    }

    private var requiresAuthentication: Bool {
        guard preferences.appLockEnabled else { return false }
        // A fresh launch always authenticates, even if downloads were restored.
        guard hasUnlocked else { return true }
        guard let awaySince else { return false }
        if !preferences.appLockWhileDownloading && downloading { return false }
        return Date().timeIntervalSince(awaySince) >= Double(max(0, preferences.appLockRequireAfter))
    }

    func willResignActive() {
        guard preferences.appLockEnabled else { return }
        showCover()
        guard !authenticationInProgress, !configurationAuthentication else { return }
        if awaySince == nil { awaySince = Date() }
    }

    func didEnterBackground() {
        guard preferences.appLockEnabled else { return }
        if authenticationInProgress {
            context?.invalidate()
            context = nil
            authenticationInProgress = false
        }
        if awaySince == nil { awaySince = Date() }
        attemptedAutomaticUnlock = false
        showCover()
    }

    func didBecomeActive() {
        guard preferences.appLockEnabled else { hideCover(); return }
        guard !configurationAuthentication, !authenticationInProgress else { return }
        if requiresAuthentication {
            hasUnlocked = false
            showCover()
            if !attemptedAutomaticUnlock {
                attemptedAutomaticUnlock = true
                authenticate()
            }
        } else {
            awaySince = nil
            hideCover()
            NotificationCenter.default.post(name: .appDidUnlock, object: nil)
        }
    }

    private func showCover() {
        guard let scene = mainWindow?.windowScene else { return }
        if coverWindow == nil {
            let window = UIWindow(windowScene: scene)
            window.windowLevel = .alert + 1
            let screen = LockScreenViewController()
            screen.unlockAction = { [weak self] in self?.authenticate() }
            window.rootViewController = screen
            coverWindow = window
        }
        coverWindow?.isHidden = false
        coverWindow?.makeKey()
    }

    private func hideCover() {
        coverWindow?.isHidden = true
        mainWindow?.makeKey()
    }

    private func authenticate() {
        guard !authenticationInProgress,
              mainWindow?.windowScene?.activationState == .foregroundActive else { return }
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            (coverWindow?.rootViewController as? LockScreenViewController)?.showError(error?.localizedDescription ?? "Set a device passcode to unlock Pulled.")
            return
        }
        self.context = context
        authenticationInProgress = true
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock Pulled to access your downloads.") { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self, self.context === context else { return }
                self.context = nil
                self.authenticationInProgress = false
                if success {
                    self.hasUnlocked = true
                    self.awaySince = nil
                    if self.mainWindow?.windowScene?.activationState == .foregroundActive {
                        self.hideCover()
                        NotificationCenter.default.post(name: .appDidUnlock, object: nil)
                    }
                } else {
                    (self.coverWindow?.rootViewController as? LockScreenViewController)?.showError(error?.localizedDescription ?? "Authentication failed. Try again.")
                }
            }
        }
    }
}

private final class LockScreenViewController: UIViewController {
    var unlockAction: (() -> Void)?
    private let detail = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let icon = UIImageView(image: UIImage(systemName: "lock.fill"))
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .secondaryLabel
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        let title = UILabel()
        title.text = "Pulled is locked"
        title.font = .preferredFont(forTextStyle: .title2)
        title.textAlignment = .center
        detail.text = "Authenticate to access your downloads and files."
        detail.font = .preferredFont(forTextStyle: .body)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 0
        detail.textAlignment = .center
        let button = UIButton(configuration: .filled())
        button.configuration?.title = "Unlock"
        button.addAction(UIAction { [weak self] _ in self?.unlockAction?() }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [icon, title, detail, button])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -28)
        ])
    }

    func showError(_ message: String) { detail.text = message }
}

final class AppLockSettingsViewController: UITableViewController, ToolbarHidingProtocol {
    private let timeouts: [(String, Int)] = [("Immediately", 0), ("After 1 minute", 60), ("After 5 minutes", 300), ("After 15 minutes", 900), ("After 1 hour", 3600)]
    private var authenticating = false
    private var context: LAContext?
    private var preferences: PreferencesStorage { .shared }
    var isToolbarItemsHidden: Bool { true }

    init() { super.init(style: .insetGrouped); title = "App lock" }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: false)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 3 }
    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Unlock with Face ID, Touch ID or your device passcode. The delay applies after leaving the app; a fresh launch always requires authentication. Turn off Lock while downloading to skip locking when a download is active. Downloads continue while the app is locked."
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        switch indexPath.row {
        case 0:
            cell.textLabel?.text = "App lock"
            let toggle = UISwitch()
            toggle.isOn = preferences.appLockEnabled
            toggle.isEnabled = !authenticating
            toggle.addTarget(self, action: #selector(changeEnabled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        case 1:
            cell.textLabel?.text = "Require authentication after"
            cell.detailTextLabel?.text = timeouts.first { $0.1 == preferences.appLockRequireAfter }?.0 ?? "Immediately"
            cell.accessoryType = .disclosureIndicator
        default:
            cell.textLabel?.text = "Lock while downloading"
            let toggle = UISwitch()
            toggle.isOn = preferences.appLockWhileDownloading
            toggle.isEnabled = preferences.appLockEnabled
            toggle.addTarget(self, action: #selector(changeDownloading(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        }
        cell.selectionStyle = indexPath.row == 1 ? .default : .none
        if indexPath.row > 0 { cell.isUserInteractionEnabled = preferences.appLockEnabled; cell.textLabel?.textColor = preferences.appLockEnabled ? .label : .secondaryLabel }
        return cell
    }

    @objc private func changeDownloading(_ toggle: UISwitch) {
        preferences.appLockWhileDownloading = toggle.isOn
        NotificationCenter.default.post(name: .appLockSettingsChanged, object: nil)
    }

    @objc private func changeEnabled(_ toggle: UISwitch) {
        guard !authenticating else { return }
        let enabled = toggle.isOn
        toggle.setOn(preferences.appLockEnabled, animated: true)
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            showError(error?.localizedDescription ?? "Set a device passcode before enabling app lock.")
            return
        }
        self.context = context
        authenticating = true
        tableView.reloadData()
        NotificationCenter.default.post(name: .appLockConfigurationAuthentication, object: true)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: enabled ? "Enable app lock for Pulled." : "Turn off app lock for Pulled.") { [weak self] success, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.authenticating = false
                self.context = nil
                if success {
                    self.preferences.appLockEnabled = enabled
                    NotificationCenter.default.post(name: .appLockSettingsChanged, object: nil, userInfo: ["authenticated": true])
                }
                NotificationCenter.default.post(name: .appLockConfigurationAuthentication, object: false)
                self.tableView.reloadData()
                if !success, let error { self.showError(error.localizedDescription) }
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard indexPath.row == 1, preferences.appLockEnabled else { return }
        let alert = UIAlertController(title: "Require authentication after", message: nil, preferredStyle: .actionSheet)
        for (title, seconds) in timeouts {
            alert.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.preferences.appLockRequireAfter = seconds
                self?.tableView.reloadData()
                NotificationCenter.default.post(name: .appLockSettingsChanged, object: nil)
            })
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath)
        alert.popoverPresentationController?.sourceRect = tableView.cellForRow(at: indexPath)?.bounds ?? .zero
        present(alert, animated: true)
    }

    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Authentication unavailable", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
