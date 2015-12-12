/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import XCGLogger
import Deferred

private let log = Logger.syncLogger

private let desktopBookmarksLabel = NSLocalizedString("Desktop Bookmarks", tableName: "BookmarkPanel", comment: "The folder name for the virtual folder that contains all desktop bookmarks.")

func titleForSpecialGUID(guid: GUID) -> String? {
    switch guid {
    case BookmarkRoots.RootGUID:
        return "<Root>"
    case BookmarkRoots.MobileFolderGUID:
        return BookmarksFolderTitleMobile
    case BookmarkRoots.ToolbarFolderGUID:
        return BookmarksFolderTitleToolbar
    case BookmarkRoots.MenuFolderGUID:
        return BookmarksFolderTitleMenu
    case BookmarkRoots.UnfiledFolderGUID:
        return BookmarksFolderTitleUnsorted
    default:
        return nil
    }
}

class SQLiteBookmarkFolder: BookmarkFolder {
    private let cursor: Cursor<BookmarkNode>
    override var count: Int {
        return cursor.count
    }

    override subscript(index: Int) -> BookmarkNode {
        let bookmark = cursor[index]
        return bookmark! as BookmarkNode
    }

    init(guid: String, title: String, children: Cursor<BookmarkNode>) {
        self.cursor = children
        super.init(guid: guid, title: title)
    }
}

class BookmarkFactory {
    private class func addIcon(bookmark: BookmarkNode, row: SDRow) {
        // TODO: share this logic with SQLiteHistory.
        if let faviconURL = row["iconURL"] as? String,
           let date = row["iconDate"] as? Double,
           let faviconType = row["iconType"] as? Int {
                bookmark.favicon = Favicon(url: faviconURL,
                                           date: NSDate(timeIntervalSince1970: date),
                                           type: IconType(rawValue: faviconType)!)
        }
    }

    private class func livemarkFactory(row: SDRow) -> BookmarkItem {
        let id = row["id"] as! Int
        let guid = row["guid"] as! String
        let url = row["siteUri"] as! String
        let title = row["title"] as? String ?? "Livemark"       // TODO
        let bookmark = BookmarkItem(guid: guid, title: title, url: url)
        bookmark.id = id
        BookmarkFactory.addIcon(bookmark, row: row)
        return bookmark
    }

    // We ignore queries altogether inside the model factory.
    private class func queryFactory(row: SDRow) -> BookmarkItem {
        log.warning("Creating a BookmarkItem from a query. This is almost certainly unexpected.")
        let id = row["id"] as! Int
        let guid = row["guid"] as! String
        let title = row["title"] as? String ?? SQLiteBookmarks.defaultItemTitle
        let bookmark = BookmarkItem(guid: guid, title: title, url: "about:blank")
        bookmark.id = id
        BookmarkFactory.addIcon(bookmark, row: row)
        return bookmark
    }

    private class func separatorFactory(row: SDRow) -> BookmarkSeparator {
        let id = row["id"] as! Int
        let guid = row["guid"] as! String
        let separator = BookmarkSeparator(guid: guid)
        separator.id = id
        return separator
    }

    private class func itemFactory(row: SDRow) -> BookmarkItem {
        let id = row["id"] as! Int
        let guid = row["guid"] as! String
        let url = row["bmkUri"] as! String
        let title = row["title"] as? String ?? url
        let bookmark = BookmarkItem(guid: guid, title: title, url: url)
        bookmark.id = id
        BookmarkFactory.addIcon(bookmark, row: row)
        return bookmark
    }

    private class func folderFactory(row: SDRow) -> BookmarkFolder {
        let id = row["id"] as! Int
        let guid = row["guid"] as! String
        let title = titleForSpecialGUID(guid) ??
                    row["title"] as? String ??
                    SQLiteBookmarks.defaultFolderTitle

        let folder = BookmarkFolder(guid: guid, title: title)
        folder.id = id
        BookmarkFactory.addIcon(folder, row: row)
        return folder
    }

    class func factory(row: SDRow) -> BookmarkNode {
        if let typeCode = row["type"] as? Int, type = BookmarkNodeType(rawValue: typeCode) {
            switch type {
            case .Bookmark:
                return itemFactory(row)
            case .DynamicContainer:
                // This should never be hit: we exclude dynamic containers from our models.
                fallthrough
            case .Folder:
                return folderFactory(row)
            case .Separator:
                return separatorFactory(row)
            case .Livemark:
                return livemarkFactory(row)
            case .Query:
                // This should never be hit: we exclude queries from our models.
                return queryFactory(row)
            }
        }
        assert(false, "Invalid bookmark data.")
        return itemFactory(row)     // This will fail, but it keeps the compiler happy.
    }

    class func mirrorItemFactory(row: SDRow) -> BookmarkMirrorItem {
        // TODO
        // let id = row["id"] as! Int

        let guid = row["guid"] as! GUID
        let typeCode = row["type"] as! Int
        let is_deleted = row.getBoolean("is_deleted")
        let parentid = row["parentid"] as? GUID
        let parentname = row["parentname"] as? String
        let feedUri = row["feedUri"] as? String
        let siteUri = row["siteUri"] as? String
        let pos = row["pos"] as? Int
        let title = row["title"] as? String
        let description = row["description"] as? String
        let bmkUri = row["bmkUri"] as? String
        let tags = row["tags"] as? String
        let keyword = row["keyword"] as? String
        let folderName = row["folderName"] as? String
        let queryId = row["queryId"] as? String

        // TODO
        //let faviconID = row["faviconID"] as? Int

        // Local only. TODO
        //let local_modified = row.getTimestamp("local_modified")
        //let sync_status = row["sync_status"] as? Int

        // Mirror and buffer.
        let server_modified = row.getTimestamp("server_modified")
        let hasDupe = row.getBoolean("hasDupe")

        // Mirror only. TODO
        //let is_overridden = row.getBoolean("is_overridden")

        // Use the struct initializer directly. Yes, this doesn't validate as strongly as
        // using the static constructors, but it'll be as valid as the contents of the DB.
        let type = BookmarkNodeType(rawValue: typeCode)!
        let item = BookmarkMirrorItem(guid: guid, type: type, serverModified: server_modified ?? 0,
                                      isDeleted: is_deleted, hasDupe: hasDupe, parentID: parentid, parentName: parentname,
                                      feedURI: feedUri, siteURI: siteUri,
                                      pos: pos,
                                      title: title, description: description,
                                      bookmarkURI: bmkUri, tags: tags, keyword: keyword,
                                      folderName: folderName, queryID: queryId,
                                      children: nil)
        return item
    }
}

public class SQLiteBookmarks: BookmarksModelFactory {
    let db: BrowserDB
    let favicons: FaviconsTable<Favicon>

    private static let defaultFolderTitle = NSLocalizedString("Untitled", tableName: "Storage", comment: "The default name for bookmark folders without titles.")
    private static let defaultItemTitle = NSLocalizedString("Untitled", tableName: "Storage", comment: "The default name for bookmark nodes without titles.")

    public init(db: BrowserDB) {
        self.db = db
        self.favicons = FaviconsTable<Favicon>()
    }

    /**
     * Return the children of the provided parent.
     * Rows are ordered by positional index.
     * This method is aware of is_overridden and deletion, using local override structure by preference.
     * Note that a folder can be empty locally; we thus use the flag rather than looking at the structure itself.
     */
    private func getChildrenWithParent(parentGUID: GUID, excludingGUIDs: [GUID]?=nil, includeIcon: Bool) -> Deferred<Maybe<Cursor<BookmarkNode>>> {
        let childrenOfLocallyOverridden =
        "SELECT parent, child AS guid, idx FROM \(TableBookmarksLocalStructure) WHERE parent = ?"

        // This could be a view: a join between structure and mirror.
        let childrenOfNotOverridden =
        "SELECT parent, child AS guid, idx FROM \(TableBookmarksMirrorStructure) " +
        "WHERE " +
        "((SELECT is_overridden FROM \(TableBookmarksMirror) WHERE guid = ?) IS NOT 1) " +
        "AND parent = ?"

        // This could be a view.
        let either =
        childrenOfLocallyOverridden + " UNION ALL " + childrenOfNotOverridden + " ORDER BY idx ASC"

        // This could be a view.
        let values =
        "SELECT -1 AS id, guid, type, is_deleted, parentid, parentName, feedUri, pos, title, bmkUri, folderName, faviconID " +
        "FROM \(TableBookmarksMirror) WHERE is_overridden IS NOT 1 " +
        "UNION ALL " +
        "SELECT -1 AS id, guid, type, is_deleted, parentid, parentName, feedUri, pos, title, bmkUri, folderName, faviconID " +
        "FROM \(TableBookmarksLocal) WHERE is_deleted IS NOT 1"

        // We exclude queries and dynamic containers, because we can't
        // usefully display them.
        let typeQuery = BookmarkNodeType.Query.rawValue
        let typeDynamic = BookmarkNodeType.DynamicContainer.rawValue
        let typeFilter = " vals.type NOT IN (\(typeQuery), \(typeDynamic))"

        let args: Args
        let exclusion: String
        if let excludingGUIDs = excludingGUIDs {
            args = ([parentGUID, parentGUID, parentGUID] + excludingGUIDs).map { $0 as AnyObject }
            exclusion = "\(typeFilter) AND vals.guid NOT IN " + BrowserDB.varlist(excludingGUIDs.count)
        } else {
            args = [parentGUID, parentGUID, parentGUID]
            exclusion = typeFilter
        }

        let fleshed =
        "SELECT vals.id AS id, vals.guid AS guid, vals.type AS type, vals.is_deleted AS is_deleted, " +
        "       vals.parentid AS parentid, vals.parentName AS parentName, vals.feedUri AS feedUri, " +
        "       vals.pos AS pos, vals.title AS title, vals.bmkUri AS bmkUri, vals.folderName AS folderName, " +
        "       vals.faviconID AS faviconID, " +
        "       structure.idx AS idx, " +
        "       structure.parent AS _parent " +
        "FROM (\(either)) AS structure JOIN (\(values)) AS vals " +
        "ON vals.guid = structure.guid " +
        "WHERE " + exclusion

        let withIcon =
        "SELECT bookmarks.id AS id, bookmarks.guid AS guid, bookmarks.type AS type, " +
        "       bookmarks.is_deleted AS is_deleted, " +
        "       bookmarks.parentid AS parentid, bookmarks.parentName AS parentName, " +
        "       bookmarks.feedUri AS feedUri, bookmarks.pos AS pos, title AS title, " +
        "       bookmarks.bmkUri AS bmkUri, bookmarks.folderName AS folderName, " +
        "       bookmarks.idx AS idx, bookmarks._parent AS _parent, " +
        "       favicons.url AS iconURL, favicons.date AS iconDate, favicons.type AS iconType " +
        "FROM (\(fleshed)) AS bookmarks " +
        "LEFT OUTER JOIN favicons ON bookmarks.faviconID = favicons.id"

        let sql = (includeIcon ? withIcon : fleshed) + " ORDER BY idx ASC"
        return self.db.runQuery(sql, args: args, factory: BookmarkFactory.factory)
    }

    private func getRootChildren() -> Deferred<Maybe<Cursor<BookmarkNode>>> {
        return self.getChildrenWithParent(BookmarkRoots.RootGUID, excludingGUIDs: [BookmarkRoots.RootGUID], includeIcon: true)
    }

    private func getChildren(guid: String) -> Deferred<Maybe<Cursor<BookmarkNode>>> {
        return self.getChildrenWithParent(guid, includeIcon: true)
    }

    func folderForGUID(guid: GUID, title: String) -> Deferred<Maybe<BookmarkFolder>> {
        return self.getChildren(guid)
            >>== { cursor in

            if cursor.status == .Failure {
                return deferMaybe(DatabaseError(description: "Couldn't get children: \(cursor.statusMessage)."))
            }

            let folder = SQLiteBookmarkFolder(guid: guid, title: title, children: cursor)

            // We add some suggested sites to the mobile bookmarks folder only.
            if guid == BookmarkRoots.MobileFolderGUID {
                return deferMaybe(BookmarkFolderWithDefaults(folder: folder, sites: SuggestedSites))
            }

            return deferMaybe(folder)
        }
    }

    private func modelWithRoot(root: BookmarkFolder) -> Deferred<Maybe<BookmarksModel>> {
        return deferMaybe(BookmarksModel(modelFactory: self, root: root))
    }

    public func modelForFolder(guid: String, title: String) -> Deferred<Maybe<BookmarksModel>> {
        if guid == BookmarkRoots.FakeDesktopFolderGUID {
            return self.modelForDesktopBookmarks()
        }

        let outputTitle = titleForSpecialGUID(guid) ?? title
        return self.folderForGUID(guid, title: outputTitle)
          >>== self.modelWithRoot
    }

    public func modelForFolder(folder: BookmarkFolder) -> Deferred<Maybe<BookmarksModel>> {
        return self.modelForFolder(folder.guid, title: folder.title)
    }

    public func modelForFolder(guid: String) -> Deferred<Maybe<BookmarksModel>> {
        return self.modelForFolder(guid, title: "")
    }

    public func modelForRoot() -> Deferred<Maybe<BookmarksModel>> {
        log.debug("Getting model for root.")
        // Return a virtual model containing "Desktop bookmarks" prepended to the local mobile bookmarks.
        return self.folderForGUID(BookmarkRoots.MobileFolderGUID, title: BookmarksFolderTitleMobile)
            >>== { folder in
                return self.extendWithDesktopBookmarksFolder(folder, factory: self)
        }
    }

    public var nullModel: BookmarksModel {
        let children = Cursor<BookmarkNode>(status: .Failure, msg: "Null model")
        let folder = SQLiteBookmarkFolder(guid: "Null", title: "Null", children: children)
        return BookmarksModel(modelFactory: self, root: folder)
    }

    public func isBookmarked(url: String) -> Deferred<Maybe<Bool>> {
        let sql = "SELECT id FROM " +
            "(SELECT id FROM \(TableBookmarksLocal) WHERE " +
            " bmkUri = ? AND is_deleted IS NOT 1" +
            " UNION ALL " +
            " SELECT id FROM \(TableBookmarksMirror) WHERE " +
            " bmkUri = ? AND is_deleted IS NOT 1 AND is_overridden IS NOT 1" +
            " LIMIT 1)"
        let args: Args = [url, url]

        return self.db.runQuery(sql, args: args, factory: { $0["id"] as! Int })
            >>== { cursor in
                return deferMaybe((cursor.status == .Success) && (cursor.count > 0))
        }
    }

    // TODO: rewrite me.
    public func clearBookmarks() -> Success {
        return self.db.run([
            ("DELETE FROM \(TableBookmarksLocal) WHERE parentid IS NOT ?", [BookmarkRoots.RootGUID]),
            self.favicons.getCleanupCommands()
        ])
    }

    private func nonDeletedGUIDsForURL(url: String) -> Deferred<Maybe<(local: [GUID], mirror: [GUID])>> {
        let local = "SELECT guid FROM \(TableBookmarksLocal) WHERE bmkUri = ? AND is_deleted = 0"
        let mirror = "SELECT guid FROM \(TableBookmarksMirror) WHERE bmkUri = ? AND is_overridden = 0 AND is_deleted = 0"

        let args: Args = [url]

        return self.db.runQuery(local, args: args, factory: { $0["guid"] as! GUID }) >>== { ls in
            return self.db.runQuery(mirror, args: args, factory: { $0["guid"] as! GUID }) >>== { ms in
                let locals = ls.asArray()
                let mirrors = ms.asArray()
                return deferMaybe((local: locals, mirror: mirrors))
            }
        }
    }

    // We delete locals then non-overridden. We don't do this in one step in order to avoid
    // potential complications when removing multiple children in a single folder (as will
    // be the case if Sync has screwed up a user's bookmarks already!). We don't delete both
    // non-overridden and local at the same time because it's convenient to know which is which.
    public func removeByURL(url: String) -> Success {
        let urls = self.nonDeletedGUIDsForURL(url)
        return urls >>== { (local: [GUID], mirror: [GUID]) in
            log.debug("Found GUIDs local = \(local), mirror = \(mirror).")
            return self.removeGUIDs(mirror, thatAreLocal: false)
             >>> { self.removeGUIDs(local, thatAreLocal: true) }
        }
    }

    private func removeGUIDs(guids: [GUID], thatAreLocal local: Bool) -> Success {
        let f = local ? self.removeLocalByGUID : self.removeNonOverriddenByGUID
        return walk(guids, f: f)
    }

    private func removeNonOverriddenByGUID(guid: GUID) -> Success {
        // If the bookmark only exists in the mirror, we must override it and mark it as
        // deleted, and override its parent and remove the deleted bookmark from its child list.
        let (sql, args) = self.getSQLToOverrideParent(guid, atModifiedTime: NSDate.now(), andDelete: true)
        return db.run(sql.map { ($0, args) })
    }

    public func removeByGUID(guid: GUID) -> Success {
        return self.removeLocalByGUID(guid)
         >>> { self.removeNonOverriddenByGUID(guid) }
    }

    private func removeLocalByGUID(guid: GUID) -> Success {
        let args: Args = [guid]

        // Find the index we're currently occupying.
        let previousIndexSubquery = "SELECT idx FROM \(TableBookmarksLocalStructure) WHERE child = ?"

        // Fix up the indices of subsequent siblings.
        let updateIndices =
        "UPDATE \(TableBookmarksLocalStructure) SET idx = (idx - 1) WHERE idx > (\(previousIndexSubquery))"

        // If the bookmark is New, delete it outright.
        let deleteNew =
        "DELETE FROM \(TableBookmarksLocal) WHERE guid = ? AND sync_status = \(SyncStatus.New.rawValue)"

        // If the bookmark is Changed, mark it as deleted and bump its modified time.
        let markChanged =
        "UPDATE \(TableBookmarksLocal) SET is_deleted = 1, local_modified = \(NSDate.now()) " +
        "WHERE guid = ? AND sync_status = \(SyncStatus.Changed.rawValue)"

        // Its parent must be either New or Changed, so we don't need to re-mirror it.
        // TODO: bump the parent's modified time, because the child list changed?

        // Now delete from structure.
        let deleteStructure =
        "DELETE FROM \(TableBookmarksLocalStructure) WHERE child = ?"

        return self.db.run([
            (updateIndices, args),
            (deleteNew, args),
            (markChanged, args),
            (deleteStructure, args),
        ])
    }
}

extension SQLiteBookmarks {
    private func getSQLToOverrideParent(folder: GUID, atModifiedTime modified: Timestamp, andDelete: Bool=false) -> (sql: [String], args: Args) {
        let args: Args = [folder]

        // Copy it to the local table.
        // Most of these will be NULL, because we're only dealing with folders,
        // and in this case only the Mobile Bookmarks root.
        let overrideSQL = "INSERT OR IGNORE INTO \(TableBookmarksLocal) " +
                          "(guid, type, bmkUri, title, parentid, parentName, feedUri, siteUri, pos," +
                          " description, tags, keyword, folderName, queryId, is_deleted, " +
                          " local_modified, sync_status, faviconID) " +
                          "SELECT guid, type, bmkUri, title, parentid, parentName, " +
                          "feedUri, siteUri, pos, description, tags, keyword, folderName, queryId, " +
                          (andDelete ? "1, " : "is_deleted, ") +
                          "\(modified) AS local_modified, \(SyncStatus.Changed.rawValue) AS sync_status, faviconID " +
                          "FROM \(TableBookmarksMirror) WHERE guid = ?"

        // Copy its mirror structure.
        let dropSQL = "DELETE FROM \(TableBookmarksLocalStructure) WHERE parent = ?"
        let copySQL = "INSERT INTO \(TableBookmarksLocalStructure) " +
                      "SELECT * FROM \(TableBookmarksMirrorStructure) WHERE parent = ?"

        // Mark as overridden.
        let markSQL = "UPDATE \(TableBookmarksMirror) SET is_overridden = 1 WHERE guid = ?"
        return (sql: [overrideSQL, dropSQL, copySQL, markSQL], args: args)
    }

    /**
     * Insert a bookmark into the specified folder.
     * If the folder doesn't exist, or is deleted, insertion will fail.
     *
     * Preconditions:
     * * `deferred` has not been filled.
     * * this function is called inside a transaction that hasn't been finished.
     *
     * Postconditions:
     * * `deferred` has been filled with success or failure.
     * * the transaction will include any status/overlay changes necessary to save the bookmark.
     * * the return value determines whether the transaction should be committed, and
     *   matches the success-ness of the Deferred.
     *
     * Sorry about the long line. If we break it, the indenting below gets crazy.
     */
    func insertBookmarkInTransaction(deferred: Success, url: NSURL, title: String, favicon: Favicon?, intoFolder parent: GUID, withTitle parentTitle: String)(conn: SQLiteDBConnection, inout err: NSError?) -> Bool {

        log.debug("Begun bookmark transaction on thread \(NSThread.currentThread())")

        // Keep going if this returns true.
        func change(sql: String, args: Args?, desc: String) -> Bool {
            err = conn.executeChange(sql, withArgs: args)
            if let err = err {
                log.error(desc)
                deferred.fillIfUnfilled(Maybe(failure: DatabaseError(err: err)))
                return false
            }
            return true
        }

        let urlString = url.absoluteString
        let newGUID = Bytes.generateGUID()
        let now = NSDate.now()
        let parentArgs: Args = [parent]

        //// Insert the new bookmark and icon without touching structure.
        var args: Args = [
            newGUID,
            BookmarkNodeType.Bookmark.rawValue,
            urlString,
            title,
            parent,
            parentTitle,
            NSDate.nowNumber(),
            SyncStatus.New.rawValue,
        ]

        let faviconID: Int?

        // Insert the favicon.
        if let icon = favicon {
            faviconID = self.favicons.insertOrUpdate(conn, obj: icon)
        } else {
            faviconID = nil
        }

        log.debug("Inserting bookmark with specified icon \(faviconID).")

        // If the caller didn't provide an icon (and they usually don't!),
        // do a reverse lookup in history. We use a view to make this simple.
        let iconValue: String
        if let faviconID = faviconID {
            iconValue = "?"
            args.append(faviconID)
        } else {
            iconValue = "(SELECT iconID FROM \(ViewIconForURL) WHERE url = ?)"
            args.append(urlString)
        }

        let insertSQL = "INSERT INTO \(TableBookmarksLocal) " +
                        "(guid, type, bmkUri, title, parentid, parentName, local_modified, sync_status, faviconID) " +
                        "VALUES (?, ?, ?, ?, ?, ?, ?, ?, \(iconValue))"
        if !change(insertSQL, args: args, desc: "Error inserting \(newGUID).") {
            return false
        }

        let bumpParentStatus = { (status: Int) -> Bool in
            let bumpSQL = "UPDATE \(TableBookmarksLocal) SET sync_status = \(status), local_modified = \(now) WHERE guid = ?"
            return change(bumpSQL, args: parentArgs, desc: "Error bumping \(parent)'s modified time.")
        }


        func overrideParentMirror() -> Bool {
            // We do this slightly tortured work so that we can reuse these queries
            // in a different context.
            let (sql, args) = getSQLToOverrideParent(parent, atModifiedTime: now)
            var generator = sql.generate()
            while let query = generator.next() {
                if !change(query, args: args, desc: "Error running overriding query.") {
                    return false
                }
            }
            return true
        }

        //// Make sure our parent is overridden and appropriately bumped.
        // See discussion here: <https://github.com/mozilla/firefox-ios/commit/2041f1bbde430de29aefb803aae54ed26db47d23#commitcomment-14572312>
        // Note that this isn't as obvious as you might think. We must:
        let localStatusFactory: SDRow -> (Int, Bool) = { row in
            let status = row["sync_status"] as! Int
            let deleted = (row["is_deleted"] as! Int) != 0
            return (status, deleted)
        }

        let overriddenFactory: SDRow -> Bool = { row in
            row.getBoolean("is_overridden")
        }

        // TODO: these can be merged into a single query.
        let mirrorStatusSQL = "SELECT is_overridden FROM \(TableBookmarksMirror) WHERE guid = ?"
        let localStatusSQL = "SELECT sync_status, is_deleted FROM \(TableBookmarksLocal) WHERE guid = ?"
        let mirrorStatus = conn.executeQuery(mirrorStatusSQL, factory: overriddenFactory, withArgs: parentArgs)[0]
        let localStatus = conn.executeQuery(localStatusSQL, factory: localStatusFactory, withArgs: parentArgs)[0]

        let parentExistsInMirror = mirrorStatus != nil
        let parentExistsLocally = localStatus != nil

        // * Figure out if we were already overridden. We only want to re-clone
        //   if we weren't.
        if !parentExistsLocally {
            if !parentExistsInMirror {
                deferred.fillIfUnfilled(Maybe(failure: DatabaseError(description: "Folder \(parent) doesn't exist in either mirror or local.")))
                return false
            }
            // * Mark the parent folder as overridden if necessary.
            //   Overriding the parent involves copying the parent's structure, so that
            //   we can amend it, but also the parent's row itself so that we know it's
            //   changed.
            overrideParentMirror()
        } else {
            let (status, deleted) = localStatus!
            if deleted {
                log.error("Trying to insert into deleted local folder.")
                deferred.fillIfUnfilled(Maybe(failure: DatabaseError(description: "Local folder \(parent) is deleted.")))
                return false
            }

            // * Bump the overridden parent's modified time. We already copied its
            //   structure and values, and if it's in the local table it'll either
            //   already be New or Changed.

            if let syncStatus = SyncStatus(rawValue: status) {
                switch syncStatus {
                case .Synced:
                    log.debug("We don't expect folders to ever be marked as Synced.")
                    if !bumpParentStatus(SyncStatus.Changed.rawValue) {
                        return false
                    }
                case .New:
                    fallthrough
                case .Changed:
                    // Leave it marked as new or changed, but bump the timestamp.
                    if !bumpParentStatus(syncStatus.rawValue) {
                        return false
                    }
                }
            } else {
                log.warning("Local folder marked with unknown state \(status). This should never occur.")
                if !bumpParentStatus(SyncStatus.Changed.rawValue) {
                    return false
                }
            }
        }

        /// Add the new bookmark as a child in the modified local structure.
        // We always append the new row: after insertion, the new item will have the largest index.
        let newIndex = "(SELECT (COALESCE(MAX(idx), -1) + 1) AS newIndex FROM \(TableBookmarksLocalStructure) WHERE parent = ?)"
        let structureSQL = "INSERT INTO \(TableBookmarksLocalStructure) (parent, child, idx) " +
                           "VALUES (?, ?, \(newIndex))"
        let structureArgs: Args = [parent, newGUID, parent]

        log.debug("Wrapping up bookmark transaction on thread \(NSThread.currentThread())")
        if !change(structureSQL, args: structureArgs, desc: "Error adding new item \(newGUID) to local structure.") {
            return false
        }


        /// Fill the deferred and commit the transaction.
        deferred.fill(Maybe(success: ()))
        return true
    }

    /**
     * Assumption: the provided folder GUID exists in either the local table or the mirror table.
     */
    func insertBookmark(url: NSURL, title: String, favicon: Favicon?, intoFolder parent: GUID, withTitle parentTitle: String) -> Success {
        log.debug("Inserting bookmark task on thread \(NSThread.currentThread())")
        let deferred = Success()

        var error: NSError?
        let inTransaction = self.insertBookmarkInTransaction(deferred, url: url, title: title, favicon: favicon, intoFolder: parent, withTitle: parentTitle)
        error = self.db.transaction(synchronous: false, err: &error, callback: inTransaction)

        log.debug("Returning deferred on thread \(NSThread.currentThread())")
        return deferred
    }
}

extension SQLiteBookmarks: ShareToDestination {
    public func addToMobileBookmarks(url: NSURL, title: String, favicon: Favicon?) -> Success {
        return self.insertBookmark(url, title: title, favicon: favicon,
                                   intoFolder: BookmarkRoots.MobileFolderGUID,
                                   withTitle: BookmarksFolderTitleMobile)
    }

    public func shareItem(item: ShareItem) {
        // We parse here in anticipation of getting real URLs at some point.
        if let url = item.url.asURL {
            let title = item.title ?? url.absoluteString
            self.addToMobileBookmarks(url, title: title, favicon: item.favicon)
        }
    }
}

extension SQLiteBookmarks: SearchableBookmarks {
    public func bookmarksByURL(url: NSURL) -> Deferred<Maybe<Cursor<BookmarkItem>>> {
        let inner =
        "SELECT id, type, guid, bmkUri, title, faviconID FROM \(TableBookmarksLocal) " +
        "WHERE " +
        "type = \(BookmarkNodeType.Bookmark.rawValue) AND is_deleted IS NOT 1 AND bmkUri = ? " +
        "UNION ALL " +
        "SELECT id, type, guid, bmkUri, title, faviconID FROM \(TableBookmarksMirror) " +
        "WHERE " +
        "type = \(BookmarkNodeType.Bookmark.rawValue) AND is_overridden IS NOT 1 AND is_deleted IS NOT 1 AND bmkUri = ? "

        let sql =
        "SELECT bookmarks.id AS id, bookmarks.type AS type, guid, bookmarks.bmkUri AS bmkUri, title, " +
        "favicons.url AS iconURL, favicons.date AS iconDate, favicons.type AS iconType " +
        "FROM (\(inner)) AS bookmarks " +
        "LEFT OUTER JOIN favicons ON bookmarks.faviconID = favicons.id"

        let u = url.absoluteString
        let args: Args = [u, u]
        return db.runQuery(sql, args: args, factory: BookmarkFactory.itemFactory)
    }
}

private extension BookmarkMirrorItem {
    func getChildrenArgs() -> [Args] {
        // Only folders have children, and we manage roots ourselves.
        if self.type != .Folder ||
           self.guid == BookmarkRoots.RootGUID {
            return []
        }
        let parent = self.guid
        var idx = 0
        return self.children?.map { child in
            let ret: Args = [parent, child, idx++]
            return ret
        } ?? []
    }

    func getUpdateOrInsertArgs() -> Args {
        let args: Args = [
            self.type.rawValue,
            NSNumber(unsignedLongLong: self.serverModified),
            self.isDeleted ? 1 : 0,
            self.hasDupe ? 1 : 0,
            self.parentID,
            self.parentName,
            self.feedURI,
            self.siteURI,
            self.pos,
            self.title,
            self.description,
            self.bookmarkURI,
            self.tags,
            self.keyword,
            self.folderName,
            self.queryID,
            self.guid,
        ]

        return args
    }
}

/**
 * This stores incoming records in a buffer.
 * When appropriate, the buffer is merged with the mirror and local storage
 * in the DB.
 */
public class SQLiteBookmarkBufferStorage: BookmarkBufferStorage {
    private let db: BrowserDB

    public init(db: BrowserDB) {
        self.db = db
    }

    /**
     * Remove child records for any folders that've been deleted or are empty.
     */
    private func deleteChildrenInTransactionWithGUIDs(guids: [GUID], connection: SQLiteDBConnection, withMaxVars maxVars: Int=BrowserDB.MaxVariableNumber) -> NSError? {
        log.debug("Deleting \(guids.count) parents from buffer structure table.")
        let chunks = chunk(guids, by: maxVars)
        for chunk in chunks {
            let inList = Array<String>(count: chunk.count, repeatedValue: "?").joinWithSeparator(", ")
            let delStructure = "DELETE FROM \(TableBookmarksBufferStructure) WHERE parent IN (\(inList))"

            let args: Args = chunk.flatMap { $0 as AnyObject }
            if let error = connection.executeChange(delStructure, withArgs: args) {
                log.error("Updating mirror structure: \(error.description).")
                return error
            }
        }
        return nil
    }

    /**
     * This is a little gnarly because our DB access layer is rough.
     * Within a single transaction, we walk the list of items, attempting to update
     * and inserting if the update failed. (TODO: batch the inserts!)
     * Once we've added all of the records, we flatten all of their children
     * into big arg lists and hard-update the structure table.
     */
    public func applyRecords(records: [BookmarkMirrorItem]) -> Success {
        return self.applyRecords(records, withMaxVars: BrowserDB.MaxVariableNumber)
    }

    public func applyRecords(records: [BookmarkMirrorItem], withMaxVars maxVars: Int) -> Success {
        let deferred = Deferred<Maybe<()>>(defaultQueue: dispatch_get_main_queue())

        let deleted = records.filter { $0.isDeleted }.map { $0.guid }
        let values = records.map { $0.getUpdateOrInsertArgs() }
        let children = records.filter { !$0.isDeleted }.flatMap { $0.getChildrenArgs() }
        let folders = records.filter { $0.type == BookmarkNodeType.Folder }.map { $0.guid }

        var err: NSError?
        self.db.transaction(&err) { (conn, err) -> Bool in
            // These have the same values in the same order.
            let update =
            "UPDATE \(TableBookmarksBuffer) SET " +
            "type = ?, server_modified = ?, is_deleted = ?, " +
            "hasDupe = ?, parentid = ?, parentName = ?, " +
            "feedUri = ?, siteUri = ?, pos = ?, title = ?, " +
            "description = ?, bmkUri = ?, tags = ?, keyword = ?, " +
            "folderName = ?, queryId = ? " +
            "WHERE guid = ?"

            let insert =
            "INSERT OR IGNORE INTO \(TableBookmarksBuffer) " +
            "(type, server_modified, is_deleted, hasDupe, parentid, parentName, " +
             "feedUri, siteUri, pos, title, description, bmkUri, tags, keyword, folderName, queryId, guid) " +
            "VALUES " +
            "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)"

            for args in values {
                if let error = conn.executeChange(update, withArgs: args) {
                    log.error("Updating mirror in buffer: \(error.description).")
                    err = error
                    deferred.fill(Maybe(failure: DatabaseError(err: error)))
                    return false
                }

                if conn.numberOfRowsModified > 0 {
                    continue
                }

                if let error = conn.executeChange(insert, withArgs: args) {
                    log.error("Inserting mirror into buffer: \(error.description).")
                    err = error
                    deferred.fill(Maybe(failure: DatabaseError(err: error)))
                    return false
                }
            }

            // Delete existing structure for any folders we've seen. We always trust the folders,
            // not the children's parent pointers, so we do this here: we'll insert their current
            // children right after, when we process the child structure rows.
            // We only drop the child structure for deleted folders, not the record itself.
            // Deleted records stay in the buffer table so that we know about the deletion
            // when we do a real sync!

            log.debug("\(folders.count) folders and \(deleted.count) deleted maybe-folders to drop from buffer structure table.")

            if let error = self.deleteChildrenInTransactionWithGUIDs(folders + deleted, connection: conn) {
                deferred.fill(Maybe(failure: DatabaseError(err: error)))
                return false
            }

            // (Re-)insert children in chunks.
            log.debug("Inserting \(children.count) children.")
            if !children.isEmpty {
                // Insert the new structure rows. This uses three vars per row.
                let maxRowsPerInsert: Int = maxVars / 3
                let chunks = chunk(children, by: maxRowsPerInsert)
                for chunk in chunks {
                    log.verbose("Inserting \(chunk.count)…")
                    let childArgs: Args = chunk.flatMap { $0 }   // Flatten [[a, b, c], [...]] into [a, b, c, ...].
                    let ins = "INSERT INTO \(TableBookmarksBufferStructure) (parent, child, idx) VALUES " +
                              Array<String>(count: chunk.count, repeatedValue: "(?, ?, ?)").joinWithSeparator(", ")
                    log.debug("Inserting \(chunk.count) records (out of \(children.count)).")
                    if let error = conn.executeChange(ins, withArgs: childArgs) {
                        log.error("Updating buffer structure: \(error.description).")
                        err = error
                        deferred.fill(Maybe(failure: DatabaseError(err: error)))
                        return false
                    }
                }
            }

            if err == nil {
                deferred.fillIfUnfilled(Maybe(success: ()))
                return true
            }

            deferred.fillIfUnfilled(Maybe(failure: DatabaseError(err: err)))
            return false
        }

        return deferred
    }

    public func doneApplyingRecordsAfterDownload() -> Success {
        self.db.checkpoint()
        return succeed()
    }
}

extension SQLiteBookmarks {
    private func hasDesktopBookmarks() -> Deferred<Maybe<Bool>> {
        // This is very lazy, but it has the nice property of keeping Desktop Bookmarks visible
        // for a while after you mark the last desktop child as deleted.
        let parents: Args = [
            // Local.
            BookmarkRoots.MenuFolderGUID,
            BookmarkRoots.ToolbarFolderGUID,
            BookmarkRoots.UnfiledFolderGUID,

            // Mirror.
            BookmarkRoots.MenuFolderGUID,
            BookmarkRoots.ToolbarFolderGUID,
            BookmarkRoots.UnfiledFolderGUID,
        ]

        let sql =
        "SELECT 1 FROM \(TableBookmarksLocalStructure) WHERE parent IN (?, ?, ?)" +
        " UNION ALL " +
        "SELECT 1 FROM \(TableBookmarksMirrorStructure) WHERE parent IN (?, ?, ?)"

        return db.runQuery(sql, args: parents, factory: { row in
            return row[0] != nil
        }) >>== { deferMaybe($0[0] ?? false) }
    }

    private func getDesktopRoots() -> Deferred<Maybe<Cursor<BookmarkNode>>> {
        // We deliberately exclude the mobile folder, because we're inverting the containment
        // relationship here.
        let exclude = [BookmarkRoots.MobileFolderGUID, BookmarkRoots.RootGUID]
        return self.getChildrenWithParent(BookmarkRoots.RootGUID, excludingGUIDs: exclude, includeIcon: false)
    }

    /**
     * Prepend the provided mobile bookmarks folder with a single folder.
     * The prepended folder is "Desktop Bookmarks". It contains mirrored folders.
     * We also *append* suggested sites.
     */
    public func extendWithDesktopBookmarksFolder(mobile: BookmarkFolder, factory: BookmarksModelFactory) -> Deferred<Maybe<BookmarksModel>> {

        func onlyMobile() -> Deferred<Maybe<BookmarksModel>> {
            // No desktop bookmarks.
            log.debug("No desktop bookmarks. Only showing mobile.")
            return deferMaybe(BookmarksModel(modelFactory: factory, root: mobile))
        }

        return self.hasDesktopBookmarks() >>== { yes in
            if !yes {
                return onlyMobile()
            }

            return self.getDesktopRoots() >>== { cursor in
                if cursor.count == 0 {
                    return onlyMobile()
                }

                let desktop = self.folderForDesktopBookmarksCursor(cursor)
                let prepended = PrependedBookmarkFolder(main: mobile, prepend: desktop)
                return deferMaybe(BookmarksModel(modelFactory: factory, root: prepended))
            }
        }
    }

    private func modelForDesktopBookmarks() -> Deferred<Maybe<BookmarksModel>> {
        return self.getDesktopRoots() >>== { cursor in
            let desktop = self.folderForDesktopBookmarksCursor(cursor)
            return deferMaybe(BookmarksModel(modelFactory: self, root: desktop))
        }
    }

    private func folderForDesktopBookmarksCursor(cursor: Cursor<BookmarkNode>) -> SQLiteBookmarkFolder {
        return SQLiteBookmarkFolder(guid: BookmarkRoots.FakeDesktopFolderGUID, title: desktopBookmarksLabel, children: cursor)
    }
}

public class MergedSQLiteBookmarks {
    let local: SQLiteBookmarks
    let buffer: SQLiteBookmarkBufferStorage

    public init(db: BrowserDB) {
        self.local = SQLiteBookmarks(db: db)
        self.buffer = SQLiteBookmarkBufferStorage(db: db)
    }
}

extension MergedSQLiteBookmarks: BookmarkBufferStorage {
    public func applyRecords(records: [BookmarkMirrorItem]) -> Success {
        return self.buffer.applyRecords(records)
    }

    public func doneApplyingRecordsAfterDownload() -> Success {
        // It doesn't really matter which one we checkpoint -- they're both backed by the same DB.
        return self.buffer.doneApplyingRecordsAfterDownload()
    }
}

extension MergedSQLiteBookmarks: ShareToDestination {
    public func shareItem(item: ShareItem) {
        self.local.shareItem(item)
    }
}

extension MergedSQLiteBookmarks: BookmarksModelFactory {
    public func modelForFolder(folder: BookmarkFolder) -> Deferred<Maybe<BookmarksModel>> {
        return self.local.modelForFolder(folder)
    }

    public func modelForFolder(guid: String) -> Deferred<Maybe<BookmarksModel>> {
        return self.local.modelForFolder(guid)
    }

    public func modelForFolder(guid: String, title: String) -> Deferred<Maybe<BookmarksModel>> {
        return self.local.modelForFolder(guid, title: title)
    }

    public func modelForRoot() -> Deferred<Maybe<BookmarksModel>> {
        return self.local.modelForRoot()
    }

    // Whenever async construction is necessary, we fall into a pattern of needing
    // a placeholder that behaves correctly for the period between kickoff and set.
    public var nullModel: BookmarksModel {
        return self.local.nullModel
    }

    public func isBookmarked(url: String) -> Deferred<Maybe<Bool>> {
        return self.local.isBookmarked(url)
    }

    public func removeByGUID(guid: GUID) -> Success {
        return self.local.removeByGUID(guid)
    }

    public func removeByURL(url: String) -> Success {
        return self.local.removeByURL(url)
    }

    public func clearBookmarks() -> Success {
        return self.local.clearBookmarks()
    }
}

extension MergedSQLiteBookmarks: AccountRemovalDelegate {
    public func onRemovedAccount() -> Success {
        return self.local.onRemovedAccount() >>> self.buffer.onRemovedAccount
    }
}

extension MergedSQLiteBookmarks: ResettableSyncStorage {
    public func resetClient() -> Success {
        return self.local.resetClient() >>> self.buffer.resetClient
    }
}

extension SQLiteBookmarkBufferStorage: AccountRemovalDelegate {
    public func onRemovedAccount() -> Success {
        return self.resetClient()
    }
}

extension SQLiteBookmarkBufferStorage: ResettableSyncStorage {
    /**
     * Our buffer is simply a copy of server contents. That means we should
     * be very willing to drop it and re-populate it from the server whenever we might
     * be out of sync. See Bug 1212431 Comment 2.
     */
    public func resetClient() -> Success {
        return self.wipeBookmarks()
    }

    public func wipeBookmarks() -> Success {
        return self.db.run("DELETE FROM \(TableBookmarksBuffer)")
         >>> { self.db.run("DELETE FROM \(TableBookmarksBufferStructure)") }
    }
}

extension SQLiteBookmarks {
    private func collapseMirrorIntoLocalPreservingDeletions(preserveDeletions: Bool) -> Success {
        // As implemented, this won't work correctly without ON DELETE CASCADE.
        assert(SwiftData.EnableForeignKeys)

        // 1. Drop anything from the mirror that's overridden. It's already in
        //    local, deleted or not.
        //    The REFERENCES clause will drop old structure, too.
        let removeOverridden =
        "DELETE FROM \(TableBookmarksMirror) WHERE is_overridden IS 1"

        // 2. Drop anything from local that's deleted. We don't need to track the
        //    deletion now. Optional: keep them around if they're non-uploaded changes.
        let removeLocalDeletions =
        "DELETE FROM \(TableBookmarksLocal) WHERE is_deleted IS 1 " +
            (preserveDeletions ? "AND sync_status IS NOT \(SyncStatus.Changed.rawValue)" : "")

        // 3. Mark everything in local as New.
        let markLocalAsNew =
        "UPDATE \(TableBookmarksLocal) SET sync_status = \(SyncStatus.New.rawValue)"

        // 4. Insert into local anything left in mirror.
        //    Note that we use the server modified time as our substitute local modified time.
        //    This will provide an ounce of conflict avoidance if the user re-links the same
        //    account at a later date.
        let copyMirrorContents =
        "INSERT INTO \(TableBookmarksLocal) " +
        "(sync_status, local_modified, " +
        " guid, type, bmkUri, title, parentid, parentName, feedUri, siteUri, pos," +
        " description, tags, keyword, folderName, queryId, faviconID) " +
        "SELECT " +
        "\(SyncStatus.New.rawValue) AS sync_status, " +
        "server_modified AS local_modified, " +
        "guid, type, bmkUri, title, parentid, parentName, " +
        "feedUri, siteUri, pos, description, tags, keyword, folderName, queryId, faviconID " +
        "FROM \(TableBookmarksMirror)"

        // 5. Insert into localStructure anything left in mirrorStructure.
        //    This won't copy the structure of any folders that were already overridden --
        //    we already deleted those, and the deletions cascaded.
        let copyMirrorStructure =
        "INSERT INTO \(TableBookmarksLocalStructure) SELECT * FROM \(TableBookmarksMirrorStructure)"

        // 6. Blank the mirror.
        let removeMirrorStructure =
        "DELETE FROM \(TableBookmarksMirrorStructure)"

        let removeMirrorContents =
        "DELETE FROM \(TableBookmarksMirror)"

        return db.run([
            removeOverridden,
            removeLocalDeletions,
            markLocalAsNew,
            copyMirrorContents,
            copyMirrorStructure,
            removeMirrorStructure,
            removeMirrorContents,
        ])
    }
}

extension SQLiteBookmarks: AccountRemovalDelegate {
    public func onRemovedAccount() -> Success {
        return self.collapseMirrorIntoLocalPreservingDeletions(false)
    }
}

extension SQLiteBookmarks: ResettableSyncStorage {
    public func resetClient() -> Success {
        // Flip flags to prompt a re-sync.
        //
        // We copy the mirror to local, preserving local changes, apart from
        // deletions of records that were never synced.
        //
        // Records that match the server record that we'll redownload will be
        // marked as Synced and won't be reuploaded.
        //
        // Records that are present locally but aren't on the server will be
        // uploaded.
        //
        return self.collapseMirrorIntoLocalPreservingDeletions(true)
    }
}