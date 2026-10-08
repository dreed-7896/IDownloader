//
//  TorrentListViewModel.swift
//  Pulled
//
//  Created by Daniil Vinogradov on 29/10/2023.
//

import Combine
import LibTorrent
import MvvmFoundation
import SwiftData

enum EmptyType {
    case noData
    case badSearch(String)
    case badFilter(TorrentHandle.State)
}

extension TorrentListViewModel {
    enum Sort: CaseIterable, Codable {
        case alphabetically
        case creationDate
        case addedDate
        case size
    }
}

class TorrentListViewModel: BaseViewModel {
    private var itemCache: [String: TorrentListItemViewModel] = [:]
    @Published var sections: [MvvmCollectionSectionModel] = []
    @Published var searchPresented: Bool = false
    @Published var searchQuery: String = ""
    @Published var title: String = ""
    @Published var hasRssNews: Bool = false
    @Published var filterButtons: [String] = []
    @Published var filter: TorrentHandle.State?

    lazy var rssSearchViewModel: RssSearchViewModel = {
        let vm = RssSearchViewModel()
        vm.setNavigationService { [weak self] in
            self?.navigationService?()
        }
        return vm
    }()

    var isGroupedByState: CurrentValueRelay<Bool> {
        PreferencesStorage.shared.$torrentListGroupedByState
    }

    var sortingType: CurrentValueRelay<Sort> {
        PreferencesStorage.shared.$torrentListSortType
    }

    var sortingReverced: CurrentValueRelay<Bool> {
        PreferencesStorage.shared.$torrentListSortReverced
    }

    required init() {
        super.init()
        title = "Pulled"

        filterButtons = [%"common.all"] + TorrentHandle.State.filterArray.map { Self.filterTitle($0) }

//        Task {
//            try await Task.sleep(for: .seconds(0.1))

            let groupsSortingArray = PreferencesStorage.shared.$torrentListGroupsSortingArray
            let fileChanges = FileDownloadService.shared.$downloads
                .map { $0.map { "\($0.id)|\($0.name)|\($0.state.rawValue)|\($0.totalBytes)" } }
                .removeDuplicates().map { _ in () }
            let torrentSectionChanged = TorrentService.shared.updateNotifier.filter { $0.oldSnapshot.friendlyState != $0.handle?.snapshot.friendlyState }.map { _ in () }
                .merge(with: fileChanges, DownloadQueue.shared.changed).prepend(())

            disposeBag.bind {
                rssFeedProvider.hasNewsPublisher.sink { [unowned self] value in
                    hasRssNews = value
                }
            }

            Publishers.combineLatest(
                torrentSectionChanged,
                TorrentService.shared.$torrents.map { Array($0.values) },
                $searchQuery,
                $searchPresented,
                sortingType,
                sortingReverced,
                isGroupedByState,
                groupsSortingArray,
                $filter
            ) { _, torrentHandles, searchQuery, searchPresented, sortingType, sortingReverced, isGrouping, sortingArray, filter in
                return (torrentHandles, searchQuery, isGrouping, sortingArray, filter, searchPresented, sortingType, sortingReverced)
            }
            .receive(on: DispatchQueue.main)
            .map { [unowned self] handles, query, isGrouping, sortingArray, filter, searchPresented, type, reversed in
                let torrents = makeItems(handles).filter { query.isEmpty || Self.searchFilter($0.title, by: query) }.sorted(by: type, reverced: reversed)
                if isGrouping {
                    return makeGroupedSections(with: torrents, by: sortingArray)
                } else {
                    updateFilterNames()
                    return makeUngroupedSection(with: torrents, filter: filter, searchPresented: searchPresented)
                }
            }.assign(to: &$sections)
            $searchQuery.assign(to: &rssSearchViewModel.$searchQuery)
//        }
    }

    static func filterTitle(_ state: TorrentHandle.State) -> String {
        switch state {
        case .storageError: return "Errors"
        case .downloadingMetadata: return "Connecting"
        case .paused: return "Paused / queued"
        default: return state.name
        }
    }

    static func searchFilter(_ text: String, by query: String) -> Bool {
        query.split(separator: " ").allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }
    @Injected private var rssFeedProvider: RssFeedProvider
}

extension TorrentListViewModel {
    var emptyContentType: AnyPublisher<EmptyType?, Never> {
        Publishers.combineLatest($sections, $searchQuery, $filter) { sections, searchQuery, filter in
            if sections.isEmpty || sections.allSatisfy({ $0.items.isEmpty }) {
                if !searchQuery.isEmpty { return EmptyType.badSearch(searchQuery) }
                if let filter { return EmptyType.badFilter(filter) }
                return EmptyType.noData
            }
            return nil
        }.eraseToAnyPublisher()
    }

    func preferencesAction() {
        navigate(to: PreferencesViewModel.self, by: .show)
    }

    func showRss() {
        navigate(to: RssListViewModel.self, by: .show)
    }

    func addTorrent(by url: URL) {
        guard let navigationService = navigationService?() else { return }
        TorrentAddViewModel.present(with: url, from: navigationService)
    }

    func resumeAllSelected(at indexPaths: [IndexPath]) {
        let torrentModels = indexPaths.compactMap { sections[$0.section].items[$0.item] as? TorrentListItemViewModel }
        torrentModels.forEach { 
            guard $0.canResume else { return }
            $0.resume()
        }
    }

    func pauseAllSelected(at indexPaths: [IndexPath]) {
        let torrentModels = indexPaths.compactMap { sections[$0.section].items[$0.item] as? TorrentListItemViewModel }
        torrentModels.forEach { $0.pause() }
    }

    func rehashAllSelected(at indexPaths: [IndexPath]) {
        let torrentModels = indexPaths.compactMap { sections[$0.section].items[$0.item] as? TorrentListItemViewModel }

        alert(title: %"details.rehash.title", message: %"details.rehash.message", actions: [
            .init(title: %"common.cancel", style: .cancel),
            .init(title: %"details.rehash.action", style: .destructive, isPrimary: true, action: {
                torrentModels.filter { !$0.isFile }.forEach { $0.torrentHandle.rehashDownload() }
            })
        ])
    }

    func deleteAllSelected(at indexPaths: [IndexPath]) {
        let torrentModels = indexPaths.compactMap { sections[$0.section].items[$0.item] as? TorrentListItemViewModel }
        let message = torrentModels.map { $0.title }.joined(separator: "\n\n")

        alert(title: %"torrent.remove.title", message: message, actions: [
            .init(title: %"torrent.remove.action.dropData", style: .destructive, action: {
                torrentModels.forEach { torrentModel in
                    torrentModel.delete(deleteFiles: true)
                }
            }),
            .init(title: %"torrent.remove.action.keepData", style: .default, action: {
                torrentModels.forEach { torrentModel in
                    torrentModel.delete(deleteFiles: false)
                }
            }),
            .init(title: %"common.cancel", style: .cancel, isPrimary: true)
        ])
    }

    func removeTorrent(_ torrentHandle: TorrentHandle) {
        alert(title: %"torrent.remove.title", message: torrentHandle.snapshot.name, actions: [
            .init(title: %"torrent.remove.action.dropData", style: .destructive, action: {
                TorrentService.shared.removeTorrent(by: torrentHandle.snapshot.infoHashes, deleteFiles: true)
            }),
            .init(title: %"torrent.remove.action.keepData", style: .default, action: {
                TorrentService.shared.removeTorrent(by: torrentHandle.snapshot.infoHashes, deleteFiles: false)
            }),
            .init(title: %"common.cancel", style: .cancel, isPrimary: true)
        ])
    }

    func updateFilterNames() {
        let items = makeItems(Array(TorrentService.shared.torrents.values))
        let dictionary = Dictionary(grouping: items, by: \.listState)
        filterButtons = ["\(%"common.all")\(items.isEmpty ? "" : " (\(items.count))")"] + TorrentHandle.State.filterArray.map {
            "\(Self.filterTitle($0))\(dictionary[$0].map { " (\($0.count))" } ?? "")"
        }
    }

    private func makeItems(_ handles: [TorrentHandle]) -> [TorrentListItemViewModel] {
        var items: [TorrentListItemViewModel] = []
        for handle in handles where handle.snapshot.isValid {
            let key = handle.snapshot.infoHashes.best.hex
            let vm = itemCache[key] ?? TorrentListItemViewModel(with: handle)
            vm.setNavigationService { [weak self] in self?.navigationService?() }
            itemCache[key] = vm
            items.append(vm)
        }
        for file in FileDownloadService.shared.downloads {
            let key = file.id.uuidString
            let vm = itemCache[key] ?? TorrentListItemViewModel(fileID: file.id)
            vm.setNavigationService { [weak self] in self?.navigationService?() }
            itemCache[key] = vm
            items.append(vm)
        }
        let keys = Set(items.map(\.id))
        itemCache = itemCache.filter { keys.contains($0.key) }
        return items
    }

}

private extension TorrentListViewModel {
    func makeUngroupedSection(with torrents: [TorrentListItemViewModel], filter: TorrentHandle.State?, searchPresented: Bool) -> [MvvmCollectionSectionModel] {
        [.init(id: "torrents", style: .platformPlain, showsSeparators: true, items: torrents.filter { torrent in
            guard filter != nil && !searchPresented else { return true }
            return torrent.listState == filter
        })]
    }

    static func getStateGroupintIndex(_ state: TorrentHandle.State, from sortingArray: [TorrentHandle.State]) -> Int {
        let index = sortingArray.firstIndex(of: state)
        assert(index != nil, "SortingArray missed \(state) state. SortingArray should contain all possible states of \(TorrentHandle.State.self)")
        return index ?? -1
    }

    func makeGroupedSections(with torrents: [TorrentListItemViewModel], by sortingArray: [TorrentHandle.State]) -> [MvvmCollectionSectionModel] {
        let dictionary = [TorrentHandle.State: [TorrentListItemViewModel]](grouping: torrents, by: \.listState)
        return dictionary.sorted { Self.getStateGroupintIndex($0.key, from: sortingArray) < Self.getStateGroupintIndex($1.key, from: sortingArray) }.map { section in
            MvvmCollectionSectionModel(id: section.key.name, header: Self.filterTitle(section.key), style: .platformPlain, items: section.value)
        }
    }
}

private extension Array where Element == TorrentListItemViewModel {
    func sorted(by type: TorrentListViewModel.Sort, reverced: Bool) -> [Element] {
        let res = sorted { first, second in
            switch type {
            case .alphabetically:
                return first.title.localizedCaseInsensitiveCompare(second.title) == .orderedAscending
            case .creationDate:
                return first.creationDate > second.creationDate
            case .addedDate:
                return first.addedDate > second.addedDate
            case .size:
                return first.size > second.size
            }
        }

        return reverced ? res.reversed() : res
    }
}
