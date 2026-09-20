import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "CollectionsModel.js" as Model

FocusScope {
    id: root
    property var images: []
    property string currentImage: ""
    readonly property string activeSlug: currentImage ? Model.slug({filePath: currentImage}) : (collectionData.current || '')
    property string preferredCollection: ''
    property var pendingSave: null
    property var savedData: null
    property int editRevision: 0
    property string pendingUninstall: ''
    property bool presented: false
    property string configurationPath: Quickshell.env('HOME') + '/.config/omarchy/theme-collections.json'
    property var collectionData: ({ version: 1, favorites: [], collections: [], stock: [] })
    property bool ready: false
    readonly property bool gridMode: collectionData.layout === 'grid'
    onGridModeChanged: if (presented && !dialog) Qt.callLater(focusPicker)
    property string errorText: ""
    property string query: ""
    onQueryChanged: if (presented && !initialSelection) openingRefreshPending = false
    property string collectionId: "favorites"
    property var remembered: ({})
    property string dialog: ""
    property string dialogError: ""
    property string memberSlug: ""
    property string memberName: ""
    property int memberIndex: 0
    property bool creatingForMember: false
    property bool allowUninstall: false
    property string removalSlug: ''
    property string removalName: ''
    property string removalGroupId: ''
    property string removalGroupName: ''
    property var removalOptions: []
    property int removalIndex: 0
    property bool removalFromMembers: false
    readonly property bool storageActive: storage.running
    readonly property bool busy: !ready || themeRemoval.running || pendingUninstall !== ''
    readonly property bool removalConfirmation: dialog === 'delete' || dialog === 'delete-member' || dialog === 'delete-theme'
    property bool initialSelection: true
    property bool openingRefreshPending: false
    property int firstVisibleRow: 0
    // Layout and browsing-preference saves must not recreate every grid delegate.
    readonly property string groupingData: JSON.stringify({favorites: collectionData.favorites, collections: collectionData.collections, stock: collectionData.stock || []})
    readonly property var groups: Model.groups(images, JSON.parse(groupingData), query, currentImage)
    onGroupsChanged: { syncResults(); if (initialSelection) Qt.callLater(restoreSelection) }
    readonly property int groupIndex: Math.max(0, groups.findIndex(function(g) { return g.id === root.collectionId }))
    onGroupIndexChanged: {
        if (groupIndex < firstVisibleRow) firstVisibleRow = groupIndex
        else if (groupIndex >= firstVisibleRow + 3) firstVisibleRow = groupIndex - 2
    }
    readonly property var group: groups[groupIndex] || ({id: '', name: '', images: []})
    readonly property int themeIndex: Model.position(group.images, remembered[group.id], currentImage)
    readonly property var theme: group.images[themeIndex] || null
    readonly property bool isFavorite: theme !== null && collectionData.favorites.indexOf(Model.slug(theme)) >= 0
    readonly property bool customCollection: collectionData.collections.some(function(c) { return c.id === root.collectionId })
    readonly property var memberGroups: [{ id: 'favorites', name: 'Favorites', themes: collectionData.favorites }].concat(collectionData.collections, [{ id: '__new', name: 'New collection…', themes: [] }])
    signal applyRequested(string path)
    signal cancelRequested()
    signal themeRemoved(string slug)
    function renderingStats() { return gridView.renderingStats() }

    // Window-level handling also works when a grid child owns keyboard focus.
    Shortcut {
        sequence: 'Escape'
        context: Qt.WindowShortcut
        enabled: root.presented
        onActivated: root.handleEscape()
    }

    function syncResults() {
        if (!groups.some(function(g) { return g.id === root.collectionId }))
            collectionId = groups.length ? groups[0].id : ''
        firstVisibleRow = Math.max(0, Math.min(firstVisibleRow, groups.length - 3))
        if (groupIndex < firstVisibleRow) firstVisibleRow = groupIndex
        else if (groupIndex >= firstVisibleRow + 3) firstVisibleRow = groupIndex - 2
    }

    function focusPicker() {
        // A FocusScope otherwise restores focus to the hidden name input,
        // which consumes Delete and arrow keys after a name dialog closes.
        nameInput.focus = false
        root.forceActiveFocus()
    }
    function refresh() {
        query = ""
        firstVisibleRow = 0
        dialog = ""
        errorText = ""
        initialSelection = true
        openingRefreshPending = true
        // Reopen from the in-memory model; disk refresh is not on the display
        // path. Its result can refine selection unless the user has navigated.
        if (ready) restoreSelection()
        if (!storage.running && !pendingSave && !themeRemoval.running && !pendingUninstall) {
            storage.revision = editRevision;
            storage.command = ['python3', decodeURIComponent(Qt.resolvedUrl('collection_store.py').toString().replace(/^file:\/\//, '')), 'load', '--config', configurationPath]
            storage.running = true
        }
        focusPicker()
    }
    onPresentedChanged: {
        if (presented) refresh()
        else persistPreferredCollection()
    }
    Component.onCompleted: if (presented) refresh()

    function acceptData(next) {
        if (JSON.stringify(collectionData) !== JSON.stringify(next)) collectionData = next
        ready = true
        if (openingRefreshPending) {
            openingRefreshPending = false
            initialSelection = true
        }
        if (initialSelection) {
            if (!preferredCollection) preferredCollection = next.lastCollection || ''
            restoreSelection()
        }
        syncResults()
    }

    function restoreSelection() {
        if (!initialSelection || !ready || !images.length) return
        var selection = Model.openingSelection(groups, activeSlug, preferredCollection)
        initialSelection = false
        if (!selection) return
        collectionId = selection.group
        // The active theme wins over an old browsing position when opening.
        if (selection.image) {
            var next = Object.assign({}, remembered)
            next[selection.group] = Model.slug(selection.image)
            remembered = next
        }
        syncResults()
    }
    function focusCollection(id) {
        openingRefreshPending = false
        collectionId = id
        preferredCollection = id
        preferenceSave.restart()
    }
    function persistPreferredCollection() {
        if (!preferredCollection || preferredCollection === collectionData.lastCollection) return
        if (busy || !ready) { preferenceSave.restart(); return }
        var next = copyData()
        next.lastCollection = preferredCollection
        save(next)
    }
    Timer { id: preferenceSave; interval: 250; onTriggered: root.persistPreferredCollection() }

    function save(next) {
        if (busy) return false
        errorText = ""
        openingRefreshPending = false
        editRevision++
        collectionData = next
        pendingSave = next
        flushStorage()
        return true
    }
    function flushStorage() {
        if (storage.running || themeRemoval.running) return
        if (pendingSave) {
            storage.revision = editRevision
            storage.command = ['python3', decodeURIComponent(Qt.resolvedUrl('collection_store.py').toString().replace(/^file:\/\//, '')), 'save', '-', '--config', configurationPath]
            storage.input = JSON.stringify(pendingSave)
            pendingSave = null
            storage.running = true
        } else if (pendingUninstall) {
            themeRemoval.command = ['python3', decodeURIComponent(Qt.resolvedUrl('collection_store.py').toString().replace(/^file:\/\//, '')), 'uninstall', pendingUninstall, '--config', configurationPath]
            themeRemoval.running = true
            pendingUninstall = ''
        }
    }
    function storageFailed(message) {
        pendingSave = null
        pendingUninstall = ''
        if (savedData) collectionData = savedData
        errorText = message + ' Recent changes were not saved.'
    }
    function copyData() { return JSON.parse(JSON.stringify(collectionData)) }
    function toggleLayout() {
        var next = copyData()
        next.layout = gridMode ? 'cards' : 'grid'
        save(next)
    }
    function navigateGrid(direction) {
        var next = Model.gridMove(groups, groupIndex, themeIndex, gridView.columns, direction)
        if (next) choose(next.group, next.image)
    }
    function moveGroup(direction) {
        if (!groups.length) return
        var target = groups[Math.max(0, Math.min(groups.length - 1, groupIndex + direction))]
        if (gridMode && target.id !== collectionId && target.images.length) choose(target.id, target.images[0])
        else focusCollection(target.id)
    }
    function choose(groupId, image) {
        focusCollection(groupId)
        var next = Object.assign({}, remembered)
        next[groupId] = Model.slug(image)
        remembered = next
    }
    function moveTheme(direction) {
        if (!group.images.length) return
        choose(group.id, group.images[(themeIndex + direction + group.images.length) % group.images.length])
    }
    function applyTheme() {
        if (theme) {
            focusCollection(collectionId)
            applyRequested(theme.filePath)
        }
    }
    function toggleFavorite() {
        if (!theme) return
        var next = copyData()
        next.favorites = Model.toggle(next.favorites, Model.slug(theme))
        save(next)
    }
    function toggleMember(index) {
        var entry = memberGroups[index]
        if (!entry) return
        if (entry.id === '__new') {
            showDialog('new-member')
            return
        }
        var next = copyData()
        if (entry.id === 'favorites') next.favorites = Model.toggle(next.favorites, memberSlug)
        else {
            var group = next.collections.find(function(g) { return g.id === entry.id })
            group.themes = Model.toggle(group.themes, memberSlug)
        }
        save(next)
    }
    function showDialog(kind) {
        if (busy) return
        removalFromMembers = false
        dialogError = ""
        creatingForMember = kind === 'new-member'
        if (creatingForMember) kind = 'new'
        if (kind === 'members') {
            if (!theme) return
            memberSlug = Model.slug(theme)
            memberName = Model.label(theme)
            memberIndex = 0
        }
        if ((kind === 'rename' || kind === 'delete') && !customCollection) return
        if (kind === 'delete') {
            removalGroupId = collectionId
            removalGroupName = group.name
        }
        if (kind === 'remove') {
            removalSlug = theme ? Model.slug(theme) : ''
            removalName = theme ? Model.label(theme) : ''
            removalGroupId = collectionId
            removalGroupName = group.name
            var options = []
            if (theme && (customCollection || collectionId === 'favorites'))
                options.push({kind: 'delete-member', name: 'Remove from “' + group.name + '”', detail: 'Keep the theme installed and in other collections.', enabled: true})
            if (theme) {
                var reason = !allowUninstall ? 'Uninstall is disabled in this preview.'
                    : (collectionData.stock || []).indexOf(removalSlug) >= 0 ? 'Omarchy defaults cannot be uninstalled here.'
                    : collectionData.current === removalSlug ? 'Apply another theme before uninstalling this one.'
                    : (collectionData.installed || []).indexOf(removalSlug) < 0 ? 'This theme is no longer installed.' : ''
                options.push({kind: 'delete-theme', name: 'Uninstall “' + removalName + '”', detail: reason || 'Remove its installed files and all collection memberships.', enabled: !reason})
            }
            if (customCollection)
                options.push({kind: 'delete', name: 'Remove collection “' + group.name + '”', detail: 'Keep all installed themes.', enabled: true})
            if (!options.length) return
            removalOptions = options
            removalIndex = 0
        }
        dialog = kind
        nameInput.text = kind === 'rename' ? group.name : ""
        if (kind === 'new' || kind === 'rename') {
            nameInput.forceActiveFocus()
            nameInput.selectAll()
        } else focusPicker()
    }
    function closeDialog() {
        if (themeRemoval.running || pendingUninstall) return
        dialog = removalConfirmation ? (removalFromMembers ? 'members' : 'remove') : creatingForMember ? 'members' : ''
        removalFromMembers = false
        creatingForMember = false
        focusPicker()
    }
    function handleEscape() {
        if (dialog) closeDialog()
        else cancelRequested()
    }
    function submitName(value) {
        if (busy || (dialog !== 'new' && dialog !== 'rename')) return
        var name = String(value === undefined ? nameInput.text : value).trim()
        if (name.length > 40 || /[\x00-\x1f]/.test(name)) { dialogError = 'Use a collection name between 1 and 40 characters.'; return }
        if (!name) { dialogError = 'Enter a name for your collection.'; return }
        if ([{id: 'favorites', name: 'Favorites'}, {id: 'defaults', name: 'Omarchy defaults'}, {id: 'custom', name: 'Custom'}].concat(collectionData.collections).some(function(g) { return g.name.toLowerCase() === name.toLowerCase() && !(root.dialog === 'rename' && g.id === root.collectionId) })) {
            dialogError = 'That collection name is already in use.'
            return
        }
        var next = copyData()
        if (dialog === 'new') {
            var id = 'collection-' + Date.now().toString(36)
            next.collections.push({id: id, name: name, themes: creatingForMember ? [memberSlug] : []})
            if (creatingForMember) memberIndex = next.collections.length
            // Leave the current theme available so it can be added immediately.
        } else next.collections.find(function(g) { return g.id === root.collectionId }).name = name
        save(next)
        closeDialog()
    }
    function removeMemberCollection() {
        var entry = memberGroups[memberIndex]
        if (busy || !entry || !collectionData.collections.some(function(g) { return g.id === entry.id })) return
        removalGroupId = entry.id
        removalGroupName = entry.name
        removalFromMembers = true
        dialogError = ''
        dialog = 'delete'
        focusPicker()
    }
    function deleteCollection() {
        if (!collectionData.collections.some(function(g) { return g.id === root.removalGroupId })) return
        var next = copyData()
        next.collections = next.collections.filter(function(g) { return g.id !== root.removalGroupId })
        save(next)
        dialog = removalFromMembers ? 'members' : ''
        removalFromMembers = false
        memberIndex = Math.min(memberIndex, memberGroups.length - 1)
        focusPicker()
    }

    function selectRemoval(index) {
        var option = removalOptions[index]
        if (!option || !option.enabled || busy) return
        dialogError = ''
        dialog = option.kind
        focusPicker()
    }
    function confirmRemoval() {
        if (busy) return
        if (dialog === 'delete') deleteCollection()
        else if (dialog === 'delete-member') {
            var next = copyData()
            if (removalGroupId === 'favorites') next.favorites = next.favorites.filter(function(s) { return s !== root.removalSlug })
            else {
                var target = next.collections.find(function(g) { return g.id === root.removalGroupId })
                if (!target) return
                target.themes = target.themes.filter(function(s) { return s !== root.removalSlug })
            }
            save(next)
            dialog = ''
            focusPicker()
        } else if (dialog === 'delete-theme' && allowUninstall) {
            dialogError = ''
            pendingUninstall = removalSlug
            flushStorage()
        }
    }

    Process {
        id: themeRemoval
        property bool gotResponse: false
        onRunningChanged: if (running) gotResponse = false
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var response = JSON.parse(text)
                    themeRemoval.gotResponse = true
                    if (response.removed) {
                        root.themeRemoved(response.removed)
                        root.dialog = ''
                        root.focusPicker()
                    }
                    if (response.data) { root.savedData = response.data; root.acceptData(response.data) }
                    if (response.error) {
                        if (response.removed) root.errorText = response.error
                        else root.dialogError = response.error
                    }
                } catch (error) { root.dialogError = 'Could not read the theme removal result.' }
            }
        }
        onExited: if (!gotResponse) root.dialogError = 'Could not uninstall the theme.'
    }

    Process {
        id: storage
        property int revision: 0
        property string input: ''
        property bool gotResponse: false
        property bool startedSuccessfully: false
        stdinEnabled: true
        onStarted: {
            startedSuccessfully = true
            if (input) write(input + '\n')
            input = ''
        }
        onRunningChanged: {
            if (running) { gotResponse = false; startedSuccessfully = false }
            else if (!startedSuccessfully) {
                input = ''
                root.storageFailed('Could not start the collections helper.')
            }
        }
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var response = JSON.parse(text)
                    storage.gotResponse = true
                    if (response.error) root.storageFailed(response.error)
                    else {
                        root.savedData = response.data
                        // A completed write must not overwrite newer edits in the UI.
                        if (storage.revision === root.editRevision) root.acceptData(response.data)
                    }
                } catch (error) { root.storageFailed('Could not read collections. Your saved file has been left intact.') }
            }
        }
        onExited: {
            if (!gotResponse) root.storageFailed('Could not load or save collections.')
            Qt.callLater(root.flushStorage)
        }
    }

    Keys.priority: Keys.BeforeItem
    Keys.onPressed: function(event) {
        if (event.key === Qt.Key_Escape) {
            event.accepted = true
            handleEscape()
            return
        }
        if (dialog === 'new' || dialog === 'rename') return
        event.accepted = true
        if (dialog) {
            if (dialog === 'members') {
                if (event.key === Qt.Key_Up) memberIndex = Math.max(0, memberIndex - 1)
                else if (event.key === Qt.Key_Down) memberIndex = Math.min(memberGroups.length - 1, memberIndex + 1)
                else if (event.key === Qt.Key_Space || event.key === Qt.Key_Return || event.key === Qt.Key_Enter) toggleMember(memberIndex)
                else if (event.key === Qt.Key_Delete && !event.isAutoRepeat) removeMemberCollection()
                memberList.positionViewAtIndex(memberIndex, ListView.Contain)
            } else if (dialog === 'remove') {
                if (event.key === Qt.Key_Up) removalIndex = Math.max(0, removalIndex - 1)
                else if (event.key === Qt.Key_Down) removalIndex = Math.min(removalOptions.length - 1, removalIndex + 1)
                else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) selectRemoval(removalIndex)
            } else if (removalConfirmation && !event.isAutoRepeat && (event.key === Qt.Key_Return || event.key === Qt.Key_Enter)) confirmRemoval()
            return
        }
        if (event.modifiers & Qt.ControlModifier) {
            if (event.key === Qt.Key_F) toggleFavorite()
            else if (event.key === Qt.Key_N) showDialog('new')
            else if (event.key === Qt.Key_M) showDialog('members')
            else if (event.key === Qt.Key_R) showDialog('rename')
            else if (event.key === Qt.Key_G && !event.isAutoRepeat) toggleLayout()
            else if (event.key === Qt.Key_Backspace) query = ""
        } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && event.modifiers & Qt.ShiftModifier)) moveGroup(-1)
        else if (event.key === Qt.Key_Tab) moveGroup(1)
        else if (event.key === Qt.Key_Up) gridMode ? navigateGrid('up') : moveGroup(-1)
        else if (event.key === Qt.Key_Down) gridMode ? navigateGrid('down') : moveGroup(1)
        else if (event.key === Qt.Key_Left) gridMode ? navigateGrid('left') : moveTheme(-1)
        else if (event.key === Qt.Key_Right) gridMode ? navigateGrid('right') : moveTheme(1)
        else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) applyTheme()
        else if (event.key === Qt.Key_Delete) showDialog('remove')
        else if (event.key === Qt.Key_Backspace) query = query.slice(0, -1)
        else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && !(event.modifiers & (Qt.AltModifier | Qt.MetaModifier))) query += event.text
    }

    Item {
        id: stage
        // 30px heading + 240px preview + 10px caption gap + 24px caption,
        // leaving 26px before the next collection heading even when expanded.
        readonly property int rowPitch: 330
        width: 1040
        height: 3 * rowPitch + 110
        anchors.centerIn: parent
        scale: Math.min(1.25, (root.width - 64) / width, (root.height - 90) / height)
        opacity: root.gridMode ? 0 : root.dialog ? 0.22 : 1
        visible: opacity > 0
        enabled: !root.gridMode && !root.dialog
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.InOutQuad } }

        MouseArea {
            anchors.fill: parent
            enabled: !root.dialog
            onClicked: root.focusPicker()
            onWheel: function(event) {
                if (!wheelPause.running) {
                    if (Math.abs(event.angleDelta.x) > Math.abs(event.angleDelta.y)) root.moveTheme(event.angleDelta.x > 0 ? -1 : 1)
                    else root.moveGroup(event.angleDelta.y > 0 ? -1 : 1)
                    wheelPause.start()
                }
                event.accepted = true
            }
        }
        Timer { id: wheelPause; interval: 180 }

        Text {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 2
            text: root.query ? 'Search: ' + root.query + '  ·  Ctrl+Backspace clear' : ''
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: 15
        }

        Repeater {
            model: root.groups
            delegate: Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool focused: index === root.groupIndex
                readonly property int selectedIndex: Model.position(modelData.images, root.remembered[modelData.id], root.currentImage)
                readonly property var selectedImage: modelData.images[selectedIndex] || null
                property real previewWidth: focused ? 414 : 220
                property real previewHeight: focused ? 240 : 115
                property real step: focused ? 49 : 27
                property real sliceWidth: focused ? 71 : 40
                readonly property real stackWidth: previewWidth + 10 * step
                Behavior on previewWidth { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on previewHeight { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on step { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                Behavior on sliceWidth { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                width: stage.width
                height: stage.rowPitch
                // Fixed slots: focusing a collection never reorders its neighbors.
                // Scroll only when navigating beyond the three visible rows.
                y: 40 + (index - root.firstVisibleRow) * stage.rowPitch
                visible: index >= root.firstVisibleRow && index < root.firstVisibleRow + 3 && root.ready
                opacity: focused ? 1 : 0.7
                z: focused ? 2 : 1
                Behavior on opacity { NumberAnimation { duration: 160 } }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: row.previewWidth
                    horizontalAlignment: Text.AlignHCenter
                    elide: Text.ElideRight
                    y: 0
                    text: row.modelData.name + '  ' + row.modelData.images.length
                    color: row.focused ? Color.accent : Color.foreground
                    font.family: Style.fontFamily
                    font.pixelSize: row.focused ? 17 : 14
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.focusCollection(row.modelData.id) }
                }

                Repeater {
                    model: row.visible ? Model.neighbors(row.modelData.images, row.selectedIndex) : []
                    delegate: ThemeCard {
                        required property var modelData
                        readonly property int offset: modelData.offset
                        selected: offset === 0
                        activeTheme: Model.slug(modelData.image) === root.activeSlug
                        rowFocused: row.focused
                        source: modelData.image.thumbnailPath || modelData.image.filePath
                        width: selected ? row.previewWidth : row.sliceWidth
                        height: selected ? row.previewHeight : row.previewHeight * 0.92
                        skew: row.focused ? 14 : 8
                        x: selected ? (row.width - row.previewWidth) / 2
                            : offset < 0 ? (row.width - row.previewWidth) / 2 + offset * row.step
                            : (row.width + row.previewWidth) / 2 - (row.sliceWidth - row.step) + (offset - 1) * row.step
                        y: 30 + (row.previewHeight - height) / 2
                        z: selected ? 100 : 50 - Math.abs(offset)
                        onClicked: {
                            if (row.focused && selected) root.applyTheme()
                            else root.choose(row.modelData.id, modelData.image)
                            root.focusPicker()
                        }
                    }
                }

                Rectangle {
                    visible: row.modelData.images.length === 0
                    width: row.previewWidth + 120
                    height: row.previewHeight
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 30
                    color: Util.alpha(Color.background, 0.3)
                    border.color: Color.imagePicker.unselectedBorder
                    Text {
                        anchors.centerIn: parent
                        width: parent.width - 32
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: root.query ? 'No matching themes' : row.modelData.id === 'favorites'
                            ? 'Star a theme with Ctrl+F\nto keep it here.' : row.modelData.id === 'defaults' || row.modelData.id === 'custom'
                            ? 'No themes in this collection' : 'Choose a theme, then Ctrl+M\nto add it to this collection.'
                        color: Color.muted
                        font.family: Style.fontFamily
                        font.pixelSize: 13
                    }
                    MouseArea { anchors.fill: parent; onClicked: { root.focusCollection(row.modelData.id); root.focusPicker() } }
                }

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: row.previewHeight + 40
                    width: row.stackWidth
                    height: 24
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    text: row.selectedImage ? Model.label(row.selectedImage)
                        + (root.collectionData.favorites.indexOf(Model.slug(row.selectedImage)) >= 0 ? '  ★' : '') : ''
                    color: row.focused ? Color.accent : Color.foreground
                    font.family: Style.fontFamily
                    font.pixelSize: row.focused ? 15 : 13
                }
            }
        }

    }

    CollectionGrid {
        id: gridView
        anchors.centerIn: parent
        width: Math.min(1440, root.width - 80)
        height: Math.max(200, root.height - 180)
        groups: root.groups
        favorites: root.collectionData.favorites
        collectionId: root.collectionId
        selectedSlug: root.theme ? Model.slug(root.theme) : ''
        activeSlug: root.activeSlug
        shown: root.gridMode && root.presented && !root.initialSelection
        opacity: root.gridMode ? (root.dialog ? 0.22 : 1) : 0
        visible: opacity > 0
        enabled: root.gridMode && !root.dialog
        scale: root.gridMode ? 1 : 0.97
        Behavior on opacity { NumberAnimation { duration: 200; easing.type: Easing.InOutQuad } }
        Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }
        onChosen: function(groupId, image) { root.choose(groupId, image); root.focusPicker() }
        onActivated: function(path) { root.applyTheme() }
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        y: gridView.y - 36
        visible: root.gridMode && !!root.query
        text: 'Search: ' + root.query + '  ·  Ctrl+Backspace clear'
        color: Color.foreground
        font.family: Style.fontFamily
        font.pixelSize: 15
    }

    Text {
        anchors.centerIn: parent
        visible: root.ready && root.query.trim().length > 0 && root.groups.length === 0
        text: 'No matching themes or collections'
        color: Color.foreground
        font.family: Style.fontFamily
        font.pixelSize: 16
    }

    Text {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
        width: parent.width - 48
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.WordWrap
        text: root.errorText || (!root.ready ? 'Loading collections…'
            : (root.gridMode ? 'Arrows navigate    Tab collection    Ctrl+G cards' : '↑↓ collection    ←→ theme    Ctrl+G grid')
            + '    Enter apply    Ctrl+F favorite    Ctrl+M organize    Del remove    Type to search    Esc close')
        color: root.errorText ? Color.urgent : Color.foreground
        opacity: root.errorText ? 1 : 0.7
        font.family: Style.fontFamily
        font.pixelSize: 12
    }

    MouseArea { anchors.fill: parent; visible: !!root.dialog; onClicked: root.closeDialog() }
    Rectangle {
        id: modal
        visible: !!root.dialog
        anchors.centerIn: parent
        width: Math.min(480, root.width - 40)
        height: root.dialog === 'members' ? Math.min(480, root.height - 80)
            : root.dialog === 'remove' ? removalList.y + removalList.height + 72 : dialogBody.y + dialogBody.height + 72
        color: Color.background
        border.color: Color.accent
        radius: Style.cornerRadius
        MouseArea { anchors.fill: parent }

        Text {
            id: dialogTitle
            x: 24; y: 22
            width: parent.width - 48
            wrapMode: Text.WordWrap
            text: root.dialog === 'new' ? 'New collection' : root.dialog === 'rename' ? 'Rename collection'
                : root.dialog === 'remove' ? 'Remove…'
                : root.dialog === 'delete' ? 'Remove collection “' + root.removalGroupName + '”?'
                : root.dialog === 'delete-member' ? 'Remove “' + root.removalName + '” from “' + root.removalGroupName + '”?'
                : root.dialog === 'delete-theme' ? 'Uninstall “' + root.removalName + '”?'
                : 'Add “' + root.memberName + '” to…'
            color: Color.foreground
            font.family: Style.fontFamily
            font.pixelSize: 17
        }

        Rectangle {
            id: nameField
            x: 24; y: dialogTitle.y + dialogTitle.height + 20; width: parent.width - 48; height: 44
            visible: root.dialog === 'new' || root.dialog === 'rename'
            color: Util.alpha(Color.foreground, 0.05)
            border.color: Color.accent
            TextInput {
                id: nameInput
                anchors.fill: parent
                anchors.margins: 10
                color: Color.foreground
                font.family: Style.fontFamily
                font.pixelSize: 15
                maximumLength: 40
                clip: true
                selectByMouse: true
                selectionColor: Color.accent
                selectedTextColor: Color.background
                Keys.onPressed: function(event) {
                    if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                        // Consume Enter before closing the dialog moves focus to the picker.
                        event.accepted = true
                        if (!event.isAutoRepeat) root.submitName()
                    } else if (event.key === Qt.Key_Escape) {
                        event.accepted = true
                        root.handleEscape()
                    }
                }
            }
        }

        Text {
            id: dialogBody
            x: 24
            y: nameField.visible ? nameField.y + nameField.height + 16 : dialogTitle.y + dialogTitle.height + 18
            width: parent.width - 48
            visible: root.dialog !== 'members' && root.dialog !== 'remove'
            wrapMode: Text.WordWrap
            text: root.dialogError || (themeRemoval.running ? 'Uninstalling…'
                : root.dialog === 'delete' ? 'Only this collection is removed.\nYour installed themes stay available.'
                : root.dialog === 'delete-member' ? 'The theme stays installed and available in other collections.'
                : root.dialog === 'delete-theme' ? 'This removes the installed theme files, including any edits inside its folder, and removes it from Favorites and all collections.'
                : root.creatingForMember ? '“' + root.memberName + '” will be added to this collection.' : 'Give it a name, like Evening or Light themes.')
            color: root.dialogError ? Color.urgent : Color.muted
            font.family: Style.fontFamily
            font.pixelSize: 12
        }

        ListView {
            id: memberList
            x: 20; y: 64
            width: parent.width - 40
            height: parent.height - 130
            visible: root.dialog === 'members'
            clip: true
            model: root.memberGroups
            spacing: 4
            delegate: Rectangle {
                required property var modelData
                required property int index
                width: memberList.width
                height: 40
                color: index === root.memberIndex ? Util.alpha(Color.accent, 0.18) : 'transparent'
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    x: 12
                    width: parent.width - 24
                    elide: Text.ElideRight
                    text: (modelData.id === '__new' ? '+  ' : modelData.themes.indexOf(root.memberSlug) >= 0 ? '☑  ' : '☐  ') + modelData.name
                    color: Color.foreground
                    font.family: Style.fontFamily
                    font.pixelSize: 14
                }
                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.memberIndex = index; root.toggleMember(index) } }
            }
        }

        Column {
            id: removalList
            x: 20; y: dialogTitle.y + dialogTitle.height + 18
            width: parent.width - 40
            visible: root.dialog === 'remove'
            spacing: 6
            Repeater {
                model: root.removalOptions
                delegate: Rectangle {
                    required property var modelData
                    required property int index
                    width: removalList.width
                    height: removalLabel.height + removalDetail.height + 24
                    color: index === root.removalIndex ? Util.alpha(Color.accent, 0.18) : 'transparent'
                    opacity: modelData.enabled ? 1 : 0.5
                    Text {
                        id: removalLabel
                        x: 12; y: 10; width: parent.width - 24
                        text: modelData.name
                        wrapMode: Text.WordWrap
                        color: Color.foreground
                        font.family: Style.fontFamily
                        font.pixelSize: 14
                    }
                    Text {
                        id: removalDetail
                        x: 12; y: removalLabel.y + removalLabel.height + 4; width: parent.width - 24
                        text: modelData.detail
                        wrapMode: Text.WordWrap
                        color: Color.muted
                        font.family: Style.fontFamily
                        font.pixelSize: 12
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: modelData.enabled
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.removalIndex = index; root.selectRemoval(index) }
                    }
                }
            }
        }

        Row {
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 24
            spacing: 28
            Action {
                visible: root.dialog === 'members' && root.memberIndex > 0 && root.memberIndex < root.memberGroups.length - 1
                enabled: !root.busy
                text: 'Delete collection · Del'
                onTriggered: root.removeMemberCollection()
            }
            Action { enabled: !themeRemoval.running; text: root.dialog === 'members' ? 'Done' : root.removalConfirmation ? 'Back' : 'Cancel'; onTriggered: root.closeDialog() }
            Action {
                visible: root.dialog !== 'members' && root.dialog !== 'remove'
                text: root.dialog === 'delete-theme' ? 'Uninstall · Enter' : root.removalConfirmation ? 'Remove · Enter' : root.creatingForMember ? 'Create and add · Enter' : 'Save · Enter'
                onTriggered: root.removalConfirmation ? root.confirmRemoval() : root.submitName()
            }
        }
    }

    component Action: Text {
        signal triggered()
        color: Color.accent
        opacity: !enabled || root.busy ? 0.4 : actionMouse.containsMouse ? 1 : 0.8
        font.family: Style.fontFamily
        font.pixelSize: 13
        height: 24
        verticalAlignment: Text.AlignVCenter
        MouseArea {
            id: actionMouse
            anchors.fill: parent
            hoverEnabled: true
            enabled: parent.enabled && !root.busy
            cursorShape: Qt.PointingHandCursor
            onClicked: parent.triggered()
        }
    }
}
