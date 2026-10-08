//
//  UIAlertController+PrimaryAction.swift
//  IDownloader
//
//  Created by Даниил Виноградов on 25.11.2025.
//

import UIKit

extension UIAlertController {
    func addAction(_ action: UIAlertAction, isPrimary: Bool) {
        addAction(action)
        if isPrimary {
            self.preferredAction = action
        }
    }
}
