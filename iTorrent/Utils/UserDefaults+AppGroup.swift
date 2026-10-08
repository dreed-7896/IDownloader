//
//  UserDefaults+AppGroup.swift
//  IDownloader
//
//  Created by Даниил Виноградов on 30.06.2024.
//

import Foundation

extension UserDefaults {
    static var itorrentGroup: UserDefaults {
        UserDefaults(suiteName: "group.com.dreed7896.IDownloader.live-activity") ?? .standard
    }
}
