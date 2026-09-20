import QtQuick
import qs.Commons
import "CollectionsModel.js" as Model

Item {
    id: grid
    property var groups: []
    property var favorites: []
    property string collectionId: ''
    property string selectedSlug: ''
    property string activeSlug: ''
    property bool shown: false
    property bool initialized: false
    property bool animateScroll: false
    // Layer-shell windows briefly lose their size while hidden. Keep the last
    // viewport geometry so closing does not unload and recreate every tile.
    property real layoutWidth: 1440
    property real layoutHeight: 800
    property int createdCards: 0
    property int liveCards: 0
    function renderingStats() { return {createdCards: createdCards, liveCards: liveCards, columns: columns, scrollY: viewport.contentY} }
    readonly property int columns: Math.max(2, Math.min(6, Math.floor(layoutWidth / 210)))
    readonly property real cellWidth: (layoutWidth - 12) / columns
    readonly property real cardWidth: cellWidth - 20
    readonly property real cardHeight: cardWidth * 0.60
    readonly property real cellHeight: cardHeight + 48
    readonly property var sections: Model.gridSections(groups, columns, cellHeight)
    readonly property real scrollY: viewport.contentY
    signal chosen(string groupId, var image)
    signal activated(string path)

    function revealSelection() {
        if (!shown) return
        var section = sections.find(function(s) { return s.id === grid.collectionId })
        if (!section) { viewport.contentY = 0; return }
        var index = section.images.findIndex(function(image) { return Model.slug(image) === grid.selectedSlug })
        var top = section.top + (index < columns ? 0 : 40 + Math.floor(index / columns) * cellHeight)
        var bottom = section.top + 40 + (Math.floor(Math.max(0, index) / columns) + 1) * cellHeight
        var next = viewport.contentY
        if (top < next) next = top
        else if (bottom > next + viewport.height) next = bottom - viewport.height
        viewport.contentY = Math.max(0, Math.min(next, viewport.contentHeight - viewport.height))
    }
    onSelectedSlugChanged: Qt.callLater(revealSelection)
    onCollectionIdChanged: Qt.callLater(revealSelection)
    onSectionsChanged: Qt.callLater(revealSelection)
    function settleOpening() {
        if (!shown) return
        updateGeometry()
        revealSelection()
        initialized = true
        Qt.callLater(function() { grid.animateScroll = grid.shown })
    }
    function updateGeometry() {
        if (!shown || width <= 0 || height <= 0) return
        layoutWidth = width
        layoutHeight = height
    }
    onWidthChanged: if (shown) Qt.callLater(updateGeometry)
    onHeightChanged: if (shown) Qt.callLater(updateGeometry)
    onShownChanged: {
        animateScroll = false
        if (shown) Qt.callLater(settleOpening)
    }

    Flickable {
        id: viewport
        anchors.centerIn: parent
        width: grid.layoutWidth
        height: grid.layoutHeight
        contentWidth: width
        contentHeight: grid.sections.length ? grid.sections[grid.sections.length - 1].top + grid.sections[grid.sections.length - 1].height : 0
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        Behavior on contentY { enabled: grid.animateScroll && !viewport.dragging && !viewport.flicking; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

        Repeater {
            // Geometry changes reposition existing sections instead of
            // replacing the model and destroying their image delegates.
            model: grid.groups
            delegate: Item {
                id: section
                required property var modelData
                required property int index
                readonly property var geometry: grid.sections[index] || ({top: 0, height: 0})
                x: 0
                y: geometry.top
                width: viewport.width - 12
                height: geometry.height
                Text {
                    width: parent.width
                    height: 24
                    horizontalAlignment: Text.AlignHCenter
                    text: section.modelData.name + '  ' + section.modelData.images.length
                    color: section.modelData.id === grid.collectionId ? Color.accent : Color.foreground
                    font.family: Style.fontFamily
                    font.pixelSize: 16
                    elide: Text.ElideRight
                }
                Text {
                    visible: !section.modelData.images.length
                    anchors.horizontalCenter: parent.horizontalCenter
                    y: 64
                    text: section.modelData.id === 'favorites' ? 'Star a theme with Ctrl+F to keep it here.' : 'No themes in this collection'
                    color: Color.muted
                    font.family: Style.fontFamily
                    font.pixelSize: 13
                }
                // Allocate whole tiles only near the viewport, including labels.
                // A large library can contain thousands of memberships offscreen.
                readonly property int firstTile: Math.min(section.modelData.images.length,
                    Math.max(0, Math.floor((viewport.contentY - section.y - 40) / grid.cellHeight) - 1) * grid.columns)
                readonly property int lastTile: Math.min(section.modelData.images.length,
                    Math.max(0, Math.ceil((viewport.contentY + viewport.height - section.y - 40) / grid.cellHeight) + 1) * grid.columns)
                Repeater {
                    model: grid.initialized ? section.modelData.images.slice(section.firstTile, section.lastTile) : []
                    delegate: Item {
                        id: tile
                        required property var modelData
                        required property int index
                        readonly property int absoluteIndex: section.firstTile + index
                        readonly property bool selected: section.modelData.id === grid.collectionId && Model.slug(modelData) === grid.selectedSlug
                        readonly property real absoluteY: section.y + y
                        readonly property bool nearViewport: absoluteY + height >= viewport.contentY - grid.cellHeight && absoluteY <= viewport.contentY + viewport.height + grid.cellHeight
                        x: (absoluteIndex % grid.columns) * grid.cellWidth + 10
                        y: 40 + Math.floor(absoluteIndex / grid.columns) * grid.cellHeight
                        width: grid.cardWidth
                        height: grid.cellHeight
                        Loader {
                            // Keep the current viewport warm while closed; offscreen
                            // tiles never allocate masks, textures or image decoders.
                            active: grid.initialized && tile.nearViewport
                            width: parent.width
                            height: grid.cardHeight
                            sourceComponent: GridCard {
                                Component.onCompleted: { grid.createdCards++; grid.liveCards++ }
                                Component.onDestruction: grid.liveCards--
                                activeTheme: Model.slug(tile.modelData) === grid.activeSlug
                                source: tile.modelData.thumbnailPath || tile.modelData.filePath
                                previewWidth: 480
                                rowFocused: tile.selected
                                onClicked: {
                                    if (tile.selected) grid.activated(tile.modelData.filePath)
                                    else grid.chosen(section.modelData.id, tile.modelData)
                                }
                            }
                        }
                        Text {
                            y: grid.cardHeight + 10
                            width: parent.width
                            height: 24
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: Model.label(tile.modelData) + (grid.favorites.indexOf(Model.slug(tile.modelData)) >= 0 ? '  ★' : '')
                            color: tile.selected ? Color.accent : Color.foreground
                            font.family: Style.fontFamily
                            font.pixelSize: 13
                            elide: Text.ElideRight
                        }
                    }
                }
            }
        }
    }

    // A quiet scroll-position indicator, without extra toolbar controls.
    Rectangle {
        anchors.right: parent.right
        width: 2
        height: Math.max(30, viewport.height * Math.min(1, viewport.height / Math.max(1, viewport.contentHeight)))
        y: viewport.visibleArea.yPosition * viewport.height
        visible: viewport.contentHeight > viewport.height
        color: Color.accent
        opacity: 0.4
    }
}
