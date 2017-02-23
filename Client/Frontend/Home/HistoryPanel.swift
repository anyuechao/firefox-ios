/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit

import Shared
import Storage
import XCGLogger
import Deferred

private let log = Logger.browserLogger

private func getDate(_ dayOffset: Int) -> Date {
    let calendar = Calendar(identifier: Calendar.Identifier.gregorian)
    let nowComponents = (calendar as NSCalendar).components([.year, .month, .day], from: Date())
    let today = calendar.date(from: nowComponents)!
    return (calendar as NSCalendar).date(byAdding: NSCalendar.Unit.day, value: dayOffset, to: today, options: [])!
}

private typealias SectionNumber = Int
private typealias CategoryNumber = Int
private typealias CategorySpec = (section: SectionNumber?, rows: Int, offset: Int)

private struct HistoryPanelUX {
    fileprivate static let WelcomeScreenItemTextColor = UIColor.gray
    fileprivate static let WelcomeScreenItemWidth = 170
}

class HistoryPanel: SiteTableViewController, HomePanel {
    weak var homePanelDelegate: HomePanelDelegate?
    fileprivate var currentSyncedDevicesCount: Int?

    var events = [NotificationFirefoxAccountChanged, NotificationPrivateDataClearedHistory, NotificationDynamicFontChanged]
    var refreshControl: UIRefreshControl?

    private lazy var emptyStateOverlayView: UIView = self.createEmptyStateOverlayView()

    private let QueryLimit = 100
    private let NumSections = 5
    private let Today = getDate(0)
    private let Yesterday = getDate(-1)
    private let ThisWeek = getDate(-7)

    var syncDetailText = ""
    var hasRecentlyClosed = false

    func updateSyncedDevicesCount() -> Success {
        return chainDeferred(self.profile.getCachedClientsAndTabs()) { tabsAndClients in
            self.currentSyncedDevicesCount = tabsAndClients.count
            return succeed()
        }
    }

    init() {
        super.init(nibName: nil, bundle: nil)
        events.forEach { NotificationCenter.default.addObserver(self, selector: #selector(HistoryPanel.notificationReceived(_:)), name: $0, object: nil) }
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        events.forEach { NotificationCenter.default.removeObserver(self, name: $0, object: nil) }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.accessibilityIdentifier = "History List"
        updateSyncedDevicesCount().uponQueue(DispatchQueue.main) { result in
            self.updateNumberOfSyncedDevices(self.currentSyncedDevicesCount)
        }
    }

    func updateNumberOfSyncedDevices(_ count: Int?) {
        if let count = count, count > 0 {
            syncDetailText = String.localizedStringWithFormat(Strings.SyncedTabsTableViewCellDescription, count)
        } else {
            syncDetailText = ""
        }
        self.tableView.reloadRows(at: [IndexPath(row: 1, section: 0)], with: .automatic)
    }

    func showSyncedTabs() {
        let nextController = RemoteTabsPanel()
        nextController.homePanelDelegate = self.homePanelDelegate
        nextController.profile = self.profile
        self.refreshControl?.endRefreshing()
        self.navigationController?.pushViewController(nextController, animated: true)
    }

    func showRecentlyClosed() {
        guard hasRecentlyClosed else {
            return
        }
        let nextController = RecentlyClosedTabsPanel()
        nextController.homePanelDelegate = self.homePanelDelegate
        nextController.profile = self.profile
        self.refreshControl?.endRefreshing()
        self.navigationController?.pushViewController(nextController, animated: true)
    }

    func notificationReceived(_ notification: Notification) {
        switch notification.name {
        case NotificationFirefoxAccountChanged, NotificationPrivateDataClearedHistory:
            if self.profile.hasSyncableAccount() {
                resyncHistory()
            }
            break
        case NotificationDynamicFontChanged:
            if emptyStateOverlayView.superview != nil {
                emptyStateOverlayView.removeFromSuperview()
            }
            emptyStateOverlayView = createEmptyStateOverlayView()
            resyncHistory()
            break
        default:
            // no need to do anything at all
            log.warning("Received unexpected notification \(notification.name)")
            break
        }
    }

    // Category number (index) -> (UI section, row count, cursor offset).
    fileprivate var categories: [CategorySpec] = [CategorySpec]()

    // Reverse lookup from UI section to data category.
    fileprivate var sectionLookup = [SectionNumber: CategoryNumber]()

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        hasRecentlyClosed = profile.recentlyClosedTabs.tabs.count > 0
        // Add a refresh control if the user is logged in and the control was not added before. If the user is not
        // logged in, remove any existing control but only when it is not currently refreshing. Otherwise, wait for
        // the refresh to finish before removing the control.
        if profile.hasSyncableAccount() && refreshControl == nil {
            addRefreshControl()
        } else if refreshControl?.isRefreshing == false {
            removeRefreshControl()
        }
        updateSyncedDevicesCount().uponQueue(DispatchQueue.main) { result in
            self.updateNumberOfSyncedDevices(self.currentSyncedDevicesCount)
        }
    }

    /**
     * fetch from the profile
     **/
    fileprivate func fetchData() -> Deferred<Maybe<Cursor<Site>>> {
        return profile.history.getSitesByLastVisit(QueryLimit)
    }

    fileprivate func setData(_ data: Cursor<Site>) {
        self.data = data
        self.computeSectionOffsets()
    }

    /**
     * sync history with the server and ensure that we update our view afterwards
     **/
    func resyncHistory() {
        profile.syncManager.syncHistory().uponQueue(DispatchQueue.main) { result in
            if result.isSuccess {
                self.reloadData()
            } else {
                self.endRefreshing()
            }

            self.updateSyncedDevicesCount().uponQueue(DispatchQueue.main) { result in
                self.updateNumberOfSyncedDevices(self.currentSyncedDevicesCount)
            }
        }
    }

    func addRefreshControl() {
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(HistoryPanel.refresh), for: UIControlEvents.valueChanged)
        self.refreshControl = refresh
        self.tableView.addSubview(refresh)
    }

    func removeRefreshControl() {
        self.refreshControl?.removeFromSuperview()
        self.refreshControl = nil
    }

    func endRefreshing() {
        // Always end refreshing, even if we failed!
        self.refreshControl?.endRefreshing()

        // Remove the refresh control if the user has logged out in the meantime
        if !self.profile.hasSyncableAccount() {
            self.removeRefreshControl()
        }
    }

    /**
     * called by the table view pull to refresh
     **/
    @objc func refresh() {
        self.refreshControl?.beginRefreshing()
        resyncHistory()
    }

    /**
     * Update our view after a data refresh
     **/
    override func reloadData() {
        self.fetchData().uponQueue(DispatchQueue.main) { result in
            if let data = result.successValue {
                self.setData(data)
                self.tableView.reloadData()
                self.updateEmptyPanelState()
            }
            self.endRefreshing()

            // TODO: error handling.
        }
    }

    fileprivate func updateEmptyPanelState() {
        if data.count == 0 {
            if self.emptyStateOverlayView.superview == nil {
                self.tableView.addSubview(self.emptyStateOverlayView)
                self.emptyStateOverlayView.snp.makeConstraints { make -> Void in
                    make.left.right.bottom.equalTo(self.view)
                    make.top.equalTo(self.view).offset(100)
                }
            }
        } else {
            self.tableView.alwaysBounceVertical = true
            self.emptyStateOverlayView.removeFromSuperview()
        }
    }

    fileprivate func createEmptyStateOverlayView() -> UIView {
        let overlayView = UIView()
        overlayView.backgroundColor = UIColor.white

        let welcomeLabel = UILabel()
        overlayView.addSubview(welcomeLabel)
        welcomeLabel.text = Strings.HistoryPanelEmptyStateTitle
        welcomeLabel.textAlignment = NSTextAlignment.center
        welcomeLabel.font = DynamicFontHelper.defaultHelper.DeviceFontLight
        welcomeLabel.textColor = HistoryPanelUX.WelcomeScreenItemTextColor
        welcomeLabel.numberOfLines = 0
        welcomeLabel.adjustsFontSizeToFitWidth = true

        welcomeLabel.snp.makeConstraints { make in
            make.centerX.equalTo(overlayView)
            // Sets proper top constraint for iPhone 6 in portait and for iPad.
            make.centerY.equalTo(overlayView).offset(HomePanelUX.EmptyTabContentOffset).priority(100)

            // Sets proper top constraint for iPhone 4, 5 in portrait.
            make.top.greaterThanOrEqualTo(overlayView).offset(50)
            make.width.equalTo(HistoryPanelUX.WelcomeScreenItemWidth)
        }
        return overlayView
    }

    func computeSectionOffsets() {
        var counts = [Int](repeating: 0, count: NumSections)

        // Loop over all the data. Record the start of each "section" of our list.
        for i in 0..<data.count {
            if let site = data[i] {
                counts[categoryForDate(site.latestVisit!.date) + 1] += 1
            }
        }

        var section = 0
        var offset = 0
        self.categories = [CategorySpec]()
        for i in 0..<NumSections {
            let count = counts[i]
            if i == 0 {
                sectionLookup[section] = i
                section += 1
            }
            if count > 0 {
                log.debug("Category \(i) has \(count) rows, and thus is section \(section).")
                self.categories.append((section: section, rows: count, offset: offset))
                sectionLookup[section] = i
                offset += count
                section += 1
            } else {
                log.debug("Category \(i) has 0 rows, and thus has no section.")
                self.categories.append((section: nil, rows: 0, offset: offset))
            }
        }
    }

//}
//
//class HistoryPanelSiteTableViewController: SiteTableViewController {
//    weak var homePanelDelegate: HomePanelDelegate?
//    weak var historyPanel: HistoryPanel?
//
//    var refreshControl: UIRefreshControl?
//
//    fileprivate let QueryLimit = 100
//    fileprivate let NumSections = 4
//    fileprivate let Today = getDate(0)
//    fileprivate let Yesterday = getDate(-1)
//    fileprivate let ThisWeek = getDate(-7)
//
//    init() {
//        super.init(nibName: nil, bundle: nil)
//        NotificationCenter.default.addObserver(self, selector: #selector(HistoryPanelSiteTableViewController.notificationReceived(_:)), name: NotificationFirefoxAccountChanged, object: nil)
//        NotificationCenter.default.addObserver(self, selector: #selector(HistoryPanelSiteTableViewController.notificationReceived(_:)), name: NotificationPrivateDataClearedHistory, object: nil)
//        NotificationCenter.default.addObserver(self, selector: #selector(HistoryPanelSiteTableViewController.notificationReceived(_:)), name: NotificationDynamicFontChanged, object: nil)
//    }
//
//    override func viewDidLoad() {
//        super.viewDidLoad()
//        tableView.accessibilityIdentifier = "History List"
//    }
//
//    required init?(coder aDecoder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
//    }
//
//    deinit {
//        NotificationCenter.default.removeObserver(self, name: NotificationFirefoxAccountChanged, object: nil)
//        NotificationCenter.default.removeObserver(self, name: NotificationPrivateDataClearedHistory, object: nil)
//        NotificationCenter.default.removeObserver(self, name: NotificationDynamicFontChanged, object: nil)
//    }



//
//    override func viewWillAppear(_ animated: Bool) {
//        super.viewWillAppear(animated)
//
//        // Add a refresh control if the user is logged in and the control was not added before. If the user is not
//        // logged in, remove any existing control but only when it is not currently refreshing. Otherwise, wait for
//        // the refresh to finish before removing the control.
//        if profile.hasSyncableAccount() && refreshControl == nil {
//            addRefreshControl()
//        } else if refreshControl?.isRefreshing == false {
//            removeRefreshControl()
//        }
//        historyPanel?.updateSyncedDevicesCount().uponQueue(DispatchQueue.main) { result in
//            self.historyPanel?.updateNumberOfSyncedDevices(self.historyPanel?.currentSyncedDevicesCount)
//        }
//    }
//









    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        cell.accessoryType = UITableViewCellAccessoryType.none

        if indexPath.section == 0 {
            cell.imageView!.layer.borderWidth = 0
            return indexPath.row == 0 ? configureRecentlyClosed(cell, for: indexPath) : configureSyncedTabs(cell, for: indexPath)
        } else {
            return configureSite(cell, for: indexPath)
        }
    }

    func configureRecentlyClosed(_ cell: UITableViewCell, for indexPath: IndexPath) -> UITableViewCell {
        cell.accessoryType = UITableViewCellAccessoryType.disclosureIndicator
        cell.textLabel!.text = Strings.RecentlyClosedTabsButtonTitle
        cell.detailTextLabel!.text = ""
        cell.imageView!.image = UIImage(named: "recently_closed")
        cell.imageView?.backgroundColor = UIColor.white
        if !hasRecentlyClosed {
            cell.textLabel?.alpha = 0.5
            cell.imageView!.alpha = 0.5
            cell.selectionStyle = .none
        }
        return cell
    }

    func configureSyncedTabs(_ cell: UITableViewCell, for indexPath: IndexPath) -> UITableViewCell {
        cell.accessoryType = UITableViewCellAccessoryType.disclosureIndicator
        cell.textLabel!.text = Strings.SyncedTabsTableViewCellTitle
        cell.detailTextLabel!.text = self.syncDetailText
        cell.imageView!.image = UIImage(named: "synced_devices")
        cell.imageView?.backgroundColor = UIColor.white
        return cell
    }

    func configureSite(_ cell: UITableViewCell, for indexPath: IndexPath) -> UITableViewCell {
        if let site = siteForIndexPath(indexPath), let cell = cell as? TwoLineTableViewCell {
            cell.setLines(site.title, detailText: site.url)

            cell.imageView!.layer.borderColor = UIColor(white: 0, alpha: 0.1).cgColor
            cell.imageView!.layer.borderWidth = 0.5
            cell.imageView?.setIcon(site.icon, forURL: site.tileURL, completed: { (color, url) in
                cell.imageView?.image = cell.imageView?.image?.createScaled(CGSize(width: 23, height: 23))
                cell.imageView?.contentMode = .center
            })
        }
        return cell
    }

    fileprivate func siteForIndexPath(_ indexPath: IndexPath) -> Site? {
        let offset = self.categories[sectionLookup[indexPath.section]!].offset
        return data[indexPath.row + offset]
    }


    func tableView(_ tableView: UITableView, didSelectRowAtIndexPath indexPath: IndexPath) {
        if indexPath.section == 0 {
            self.tableView.deselectRow(at: indexPath, animated: true)
            return indexPath.row == 0 ? self.showRecentlyClosed() : self.showSyncedTabs()
        }
        if let site = self.siteForIndexPath(indexPath), let url = URL(string: site.url) {
            let visitType = VisitType.typed    // Means History, too.
            if let homePanelDelegate = homePanelDelegate {
                homePanelDelegate.homePanel(self, didSelectURL: url, visitType: visitType)
            }
            return
        }
        log.warning("No site or no URL when selecting row.")
    }

    // Functions that deal with showing header rows.
    func numberOfSectionsInTableView(_ tableView: UITableView) -> Int {
        var count = 1
        for category in self.categories {
            if category.rows > 0 {
                count += 1
            }
        }
        return count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        var title = String()
        switch sectionLookup[section]! {
        case 0: return nil
        case 1: title = NSLocalizedString("Today", comment: "History tableview section header")
        case 2: title = NSLocalizedString("Yesterday", comment: "History tableview section header")
        case 3: title = NSLocalizedString("Last week", comment: "History tableview section header")
        case 4: title = NSLocalizedString("Last month", comment: "History tableview section header")
        default:
            assertionFailure("Invalid history section \(section)")
        }
        return title
    }


    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if section == 0 {
            return nil
        }
        return super.tableView(tableView, viewForHeaderInSection: section)
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        if section == 0 {
            return 0
        }
        return super.tableView(tableView, heightForHeaderInSection: section)
    }

    func categoryForDate(_ date: MicrosecondTimestamp) -> Int {
        let date = Double(date)
        if date > (1000000 * Today.timeIntervalSince1970) {
            return 0
        }
        if date > (1000000 * Yesterday.timeIntervalSince1970) {
            return 1
        }
        if date > (1000000 * ThisWeek.timeIntervalSince1970) {
            return 2
        }
        return 3
    }

    fileprivate func isInCategory(_ date: MicrosecondTimestamp, category: Int) -> Bool {
        return self.categoryForDate(date) == category
    }


    // UI sections disappear as categories empty. We need to translate back and forth.
    fileprivate func uiSectionToCategory(_ section: SectionNumber) -> CategoryNumber {
        for i in 0..<self.categories.count {
            if let s = self.categories[i].section, s == section {
                return i
            }
        }
        return 0
    }

    fileprivate func categoryToUISection(_ category: CategoryNumber) -> SectionNumber? {
        return self.categories[category].section
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if section == 0 {
            return 2
        }
        return self.categories[uiSectionToCategory(section)].rows
    }

    func tableView(_ tableView: UITableView, commitEditingStyle editingStyle: UITableViewCellEditingStyle, forRowAtIndexPath indexPath: IndexPath) {
        // Intentionally blank. Required to use UITableViewRowActions
    }

    func tableView(_ tableView: UITableView, editActionsForRowAtIndexPath indexPath: IndexPath) -> [AnyObject]? {
        if indexPath.section == 0 {
            return []
        }
        let title = NSLocalizedString("Remove", tableName: "HistoryPanel", comment: "Action button for deleting history entries in the history panel.")

        let delete = UITableViewRowAction(style: UITableViewRowActionStyle.default, title: title, handler: { (action, indexPath) in
            if let site = self.siteForIndexPath(indexPath) {
                // Why the dispatches? Because we call success and failure on the DB
                // queue, and so calling anything else that calls through to the DB will
                // deadlock. This problem will go away when the history API switches to
                // Deferred instead of using callbacks.
                self.profile.history.removeHistoryForURL(site.url)
                    .upon { res in
                        self.fetchData().uponQueue(DispatchQueue.main) { result in
                            // If a section will be empty after removal, we must remove the section itself.
                            if let data = result.successValue {

                                let oldCategories = self.categories
                                self.data = data
                                self.computeSectionOffsets()

                                let sectionsToDelete = NSMutableIndexSet()
                                var rowsToDelete = [IndexPath]()
                                let sectionsToAdd = NSMutableIndexSet()
                                var rowsToAdd = [IndexPath]()

                                for (index, category) in self.categories.enumerated() {
                                    let oldCategory = oldCategories[index]

                                    // don't bother if we're not displaying this category
                                    if oldCategory.section == nil && category.section == nil {
                                        continue
                                    }

                                    // 1. add a new section if the section didn't previously exist
                                    if oldCategory.section == nil && category.section != oldCategory.section {
                                        log.debug("adding section \(category.section)")
                                        sectionsToAdd.add(category.section!)
                                    }

                                    // 2. add a new row if there are more rows now than there were before
                                    if oldCategory.rows < category.rows {
                                        log.debug("adding row to \(category.section) at \(category.rows-1)")
                                        //IndexPath(row: <#T##Int#>, section: <#T##Int#>)
                                        rowsToAdd.append(IndexPath(row: category.rows-1, section: category.section!))
                                    }

                                    // if we're dealing with the section where the row was deleted:
                                    // 1. if the category no longer has a section, then we need to delete the entire section
                                    // 2. delete a row if the number of rows has been reduced
                                    // 3. delete the selected row and add a new one on the bottom of the section if the number of rows has stayed the same
                                    if oldCategory.section == indexPath.section {
                                        if category.section == nil {
                                            log.debug("deleting section \(indexPath.section)")
                                            sectionsToDelete.add(indexPath.section)
                                        } else if oldCategory.section == category.section {
                                            if oldCategory.rows > category.rows {
                                                log.debug("deleting row from \(category.section) at \(indexPath.row)")
                                                rowsToDelete.append(indexPath)
                                            } else if category.rows == oldCategory.rows {
                                                log.debug("in section \(category.section), removing row at \(indexPath.row) and inserting row at \(category.rows-1)")
                                                rowsToDelete.append(indexPath)
                                                rowsToAdd.append(IndexPath(row: category.rows-1, section: indexPath.section))
                                            }
                                        }
                                    }
                                }

                                tableView.beginUpdates()
                                if sectionsToAdd.count > 0 {
                                    tableView.insertSections(sectionsToAdd as IndexSet, with: UITableViewRowAnimation.left)
                                }
                                if sectionsToDelete.count > 0 {
                                    tableView.deleteSections(sectionsToDelete as IndexSet, with: UITableViewRowAnimation.right)
                                }
                                if !rowsToDelete.isEmpty {
                                    tableView.deleteRows(at: rowsToDelete, with: UITableViewRowAnimation.right)
                                }

                                if !rowsToAdd.isEmpty {
                                    tableView.insertRows(at: rowsToAdd, with: UITableViewRowAnimation.right)
                                }

                                tableView.endUpdates()
                                self.updateEmptyPanelState()
                            }
                        }
                }
            }
        })
        return [delete]
    }
}
