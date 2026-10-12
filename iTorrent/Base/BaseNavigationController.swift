//
//  BaseNavigationController.swift
//  IDownloader
//
//  Created by Daniil Vinogradov on 30/10/2023.
//

import UIKit

class BaseNavigationController: SANavigationController {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        (topViewController as? VLCPlayerViewController)?.supportedInterfaceOrientations ?? super.supportedInterfaceOrientations
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        (topViewController as? VLCPlayerViewController)?.preferredInterfaceOrientationForPresentation ?? super.preferredInterfaceOrientationForPresentation
    }
    init() {
        super.init(rootViewController: UIViewController())
    }

    @available(*, unavailable)
    @MainActor required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true
    }
}
