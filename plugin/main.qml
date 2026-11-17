import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtCore
import org.qfield.core
import org.qfield.gui
import "Grid.js" as Grid
import "Geometry.js" as Geometry
import "NativeCut.js" as NativeCut

Item {
    id: root

    property var mapCanvas: iface.mapCanvas()
    readonly property var mapSettings: mapCanvas ? mapCanvas.mapSettings : null
    readonly property string projectPath: qgisProject ? String(qgisProject.fileName || "") : ""
    property var layers: []
    property var selectedLayer: null
    property var field: null
    property var hits: []
    property var anchor: null
    property var work: null
    property var validator: null
    property var preview: null
    property var numbered: []
    property var overrides: ({})
    property string mode: "pick"
    property string notice: ""
    property string error: ""
    property real hectares: 1
    property real angle: 0
    property real gridOpacity: 0.78
    property real progress: 0
    property bool busy: false
    property bool saving: false
    property string numbering: "field"
    property bool configuration: false
    property bool panelOpen: false
    property bool fieldLocked: false
    property var featureForm: null
    property var featureActions: []
    property var dragStart: null
    property var dragBasis: null
    property var dragOffset: null
    property var rotationBasis: null
    property var fieldMapCache: null
    property var fieldScreenCache: null
    property var mapZoneRings: []
    property var mapZoneLabels: []
    property var drawSegments: []

    Settings {
        id: settings
        category: "AgroGrid"
        property string projects: "{}"
        property real defaultHectares: 1
        property real defaultOpacity: 0.78
        property string defaultNumbering: "field"
    }

    QfExpressionEvaluator {
        id: evaluator
        mode: QfExpressionEvaluator.ExpressionMode
        project: qgisProject
    }

    QfFeatureModel {
        id: editor
        project: qgisProject
    }

    Button {
        id: launcher
        objectName: "agroGridLauncher"
        text: "AgroGrid"
        width: 48
        height: 48
        padding: 0
        background: Rectangle {
            radius: 24
            color: launcher.down ? "#0c3c31" : "#145648"
            border.color: "#ffffff"
            border.width: 1
        }
        contentItem: Text {
            text: "AG"
            color: "#ffffff"
            font.pixelSize: 17
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        onClicked: root.panelOpen ? root.closePanel() : root.openPanel()
    }

    Component.onCompleted: Qt.callLater(registerActions)
    Component.onDestruction: {
        for (const action of featureActions) {
            if (action.menu && action.item) {
                for (let i = 0; i < action.menu.count; ++i) {
                    if (action.menu.itemAt(i) === action.item) {
                        action.menu.takeItem(i)
                        break
                    }
                }
            }
        }
    }
    onProjectPathChanged: {
        if (panelOpen)
            closePanel()
    }

    Connections {
        target: root.mapSettings
        ignoreUnknownSignals: true
        function onExtentChanged() { root.mapViewChanged() }
        function onRotationChanged() { root.mapViewChanged() }
        function onOutputSizeChanged() { root.mapViewChanged() }
        function onDestinationCrsChanged() {
            root.mapViewChanged()
            root.updateMap()
        }
    }

    Timer {
        id: geometryTimer
        interval: 1
        repeat: true
        onTriggered: root.advance()
    }
    Timer {
        id: redrawTimer
        interval: 40
        onTriggered: root.updateMap()
    }
    Canvas {
        id: drawing
        parent: root.mapCanvas
        anchors.fill: parent
        visible: root.panelOpen && !!root.field
        z: 120
        onPaint: {
            let ctx = getContext("2d")
            ctx.reset()
            if (!root.field || !root.mapSettings)
                return
            function trace(rings, screenSpace) {
                for (const ring of rings) {
                    if (ring.length === 0)
                        continue
                    const start = screenSpace ? ring[0] : root.mapSettings.coordinateToScreen(ring[0])
                    ctx.moveTo(start.x, start.y)
                    for (let i = 1; i < ring.length; ++i) {
                        const point = screenSpace ? ring[i] : root.mapSettings.coordinateToScreen(ring[i])
                        ctx.lineTo(point.x, point.y)
                    }
                    ctx.closePath()
                }
            }
            const outline = root.screenField()
            if (!outline)
                return
            const basis = root.dragOffset ? root.dragBasis : root.rotationBasis
                ? Grid.rotateScreenBasis(root.rotationBasis, root.angle) : null
            const segments = basis ? Grid.screenLines(basis, outline.bounds, root.dragOffset || Qt.point(0, 0))
                                   : root.drawSegments
            ctx.save()
            ctx.beginPath()
            trace(outline.rings, true)
            ctx.clip()
            ctx.globalAlpha = root.gridOpacity
            ctx.strokeStyle = "#126f61"
            ctx.lineWidth = 3
            ctx.beginPath()
            for (const segment of segments) {
                for (let i = 0; i < segment.length; ++i) {
                    const point = basis ? segment[i] : root.mapSettings.coordinateToScreen(segment[i])
                    if (i === 0)
                        ctx.moveTo(point.x, point.y)
                    else
                        ctx.lineTo(point.x, point.y)
                }
            }
            ctx.stroke()
            ctx.strokeStyle = "#a7ffdf"
            ctx.lineWidth = 1.4
            ctx.stroke()
            if (root.preview) {
                ctx.fillStyle = Qt.rgba(0.16, 0.85, 0.64, 0.20)
                ctx.beginPath()
                trace(root.mapZoneRings)
                ctx.fill()
            }
            ctx.restore()
            ctx.beginPath()
            trace(outline.rings, true)
            ctx.strokeStyle = "#0b352c"
            ctx.lineWidth = 5
            ctx.stroke()
            ctx.strokeStyle = "#f3ffad"
            ctx.lineWidth = 2
            ctx.stroke()
            if (root.mapZoneLabels.length <= 300) {
                ctx.font = "bold 13px sans-serif"
                ctx.textAlign = "center"
                ctx.textBaseline = "middle"
                for (const label of root.mapZoneLabels) {
                    const point = root.mapSettings.coordinateToScreen(label.point)
                    ctx.lineWidth = 3
                    ctx.strokeStyle = "#10362c"
                    ctx.strokeText(label.text, point.x, point.y)
                    ctx.fillStyle = "#ffffff"
                    ctx.fillText(label.text, point.x, point.y)
                }
            }
        }
    }

    Binding {
        target: root.mapCanvas
        property: "interactive"
        value: false
        when: !!root.mapCanvas && root.panelOpen && (root.mode === "pick" || root.mode === "drag")
        restoreMode: Binding.RestoreBindingOrValue
    }

    MouseArea {
        parent: root.mapCanvas
        anchors.fill: parent
        enabled: root.panelOpen && !root.busy && !root.saving &&
                 (root.mode === "pick" || (root.mode === "drag" && !!root.field))
        z: 121
        preventStealing: true
        onPressed: mouse => {
            if (root.mode !== "drag")
                return
            root.tryAction(() => root.beginDrag(mouse.x, mouse.y))
        }
        onPositionChanged: mouse => {
            if (pressed && root.dragStart)
                root.moveDrag(mouse.x, mouse.y)
        }
        onReleased: mouse => {
            if (root.mode === "pick")
                root.tryAction(() => root.pick(mouse.x, mouse.y))
            else if (root.dragStart)
                root.tryAction(() => root.finishDrag(mouse.x, mouse.y))
        }
        onCanceled: root.clearDrag()
    }

    Pane {
        id: panel
        objectName: "agroGridPanel"
        parent: iface.mainWindow().contentItem
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Math.max(12, Number(iface.mainWindow().sceneBottomMargin) || 0)
        width: Math.min(620, parent.width - 16)
        height: Math.min(controls.implicitHeight + (footer.visible ? footer.implicitHeight + 4 : 0) + 20,
                         parent.height * 0.48)
        padding: 10
        visible: root.panelOpen
        z: 500
        clip: true

        ColumnLayout {
            anchors.fill: parent
            spacing: 4
            ScrollView {
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: availableWidth
                clip: true
                ColumnLayout {
                    id: controls
                    width: panel.availableWidth
                    spacing: 4

                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "AgroGrid"; font.bold: true; Layout.fillWidth: true }
                        ToolButton {
                            text: root.configuration ? qsTr("Grid") : qsTr("Options")
                            onClicked: root.configuration = !root.configuration
                        }
                        ToolButton { text: qsTr("Close"); onClicked: root.closePanel() }
                    }

                    ComboBox {
                        id: layerPicker
                        visible: !root.configuration && !root.fieldLocked
                        Layout.fillWidth: true
                        enabled: !root.busy && !root.saving
                        model: root.layers.map(layer => layer.name + (layer.readOnly ? qsTr(" (read-only)") : ""))
                        onActivated: index => root.chooseLayer(root.layers[index])
                    }
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        text: root.field ? root.field.name + " · " + root.formatHa(root.field.area) :
                              root.layers.length ? qsTr("Tap a field on the map.") : qsTr("This project has no 2D polygon layers.")
                    }
                    RowLayout {
                        visible: !root.configuration
                        Layout.fillWidth: true
                        Button {
                            Layout.fillWidth: true
                            text: qsTr("Select field")
                            visible: !root.fieldLocked
                            checkable: true
                            checked: root.mode === "pick"
                            enabled: !!root.selectedLayer && !root.busy
                            onClicked: root.mode = "pick"
                        }
                        Button {
                            Layout.fillWidth: true
                            text: qsTr("Map")
                            Accessible.name: qsTr("Pan the map")
                            checkable: true
                            checked: root.mode === "map"
                            onClicked: root.mode = "map"
                        }
                        Button {
                            Layout.fillWidth: true
                            text: qsTr("Grid")
                            Accessible.name: qsTr("Move the grid")
                            checkable: true
                            checked: root.mode === "drag"
                            enabled: !!root.field && !root.busy
                            onClicked: root.mode = "drag"
                        }
                    }
                    RowLayout {
                        visible: !root.configuration
                        Layout.fillWidth: true
                        ComboBox {
                            model: ["0,25", "0,5", "1", "2", "3", "5"]
                            currentIndex: [0.25, 0.5, 1, 2, 3, 5].indexOf(root.hectares)
                            onActivated: index => {
                                root.hectares = [0.25, 0.5, 1, 2, 3, 5][index]
                                areaInput.text = String(root.hectares)
                                root.invalidate()
                                root.savePreferences()
                            }
                        }
                        TextField {
                            id: areaInput
                            Layout.fillWidth: true
                            placeholderText: qsTr("Cell area in ha")
                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            onEditingFinished: root.applyArea()
                        }
                        Label { text: "ha" }
                    }
                    RowLayout {
                        visible: !root.configuration
                        Layout.fillWidth: true
                        Label { text: qsTr("Angle") }
                        Slider {
                            Layout.fillWidth: true
                            from: 0
                            to: 180
                            stepSize: 1
                            value: root.angle
                            onMoved: root.setRotation(value)
                            onPressedChanged: root.tryAction(() => {
                                if (pressed)
                                    root.beginRotation()
                                else if (panel.visible)
                                    root.finishRotation()
                            })
                        }
                        TextField {
                            id: angleInput
                            Layout.preferredWidth: 65
                            inputMethodHints: Qt.ImhFormattedNumbersOnly
                            onEditingFinished: root.applyAngle()
                        }
                        Label { text: "°" }
                    }
                    ColumnLayout {
                        visible: root.configuration
                        Layout.fillWidth: true
                        RowLayout {
                            Label { text: qsTr("Grid opacity") }
                            Slider {
                                Layout.fillWidth: true
                                from: 0.15
                                to: 1
                                value: root.gridOpacity
                                onMoved: {
                                    root.gridOpacity = value
                                    settings.defaultOpacity = value
                                    drawing.requestPaint()
                                }
                            }
                        }
                        ComboBox {
                            id: numberingMode
                            Layout.fillWidth: true
                            model: [qsTr("Restart for each field"), qsTr("Field prefix"),
                                    qsTr("Continue across the project")]
                            onActivated: index => {
                                root.numbering = ["field", "prefix", "continuous"][index]
                                root.updateNumbering()
                            }
                        }
                        RowLayout {
                            Layout.fillWidth: true
                            TextField {
                                id: startNumber
                                Layout.preferredWidth: 100
                                placeholderText: qsTr("Start number")
                                inputMethodHints: Qt.ImhDigitsOnly
                                onEditingFinished: root.updateNumbering()
                            }
                            TextField {
                                id: prefixNumber
                                Layout.fillWidth: true
                                visible: root.numbering === "prefix"
                                placeholderText: qsTr("Field prefix")
                                onEditingFinished: root.updateNumbering()
                            }
                            ComboBox {
                                id: order
                                model: [qsTr("By row"), qsTr("By column")]
                                onActivated: root.updateNumbering()
                            }
                        }
                        CheckBox {
                            id: reverse
                            text: qsTr("Reverse numbering order")
                            onClicked: root.updateNumbering()
                        }
                        Button {
                            text: qsTr("Save as defaults")
                            onClicked: {
                                settings.defaultHectares = root.hectares
                                settings.defaultNumbering = root.numbering
                                settings.defaultOpacity = root.gridOpacity
                                settings.sync()
                            }
                        }
                        Button {
                            text: qsTr("Undo last split")
                            enabled: !root.busy && !root.saving
                            onClicked: undoDialog.open()
                        }
                    }

                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        visible: text !== ""
                        text: root.error || root.notice
                        color: root.error ? (palette.window.hslLightness < 0.5 ? "#ffb4ab" : "#a91b12") : palette.text
                    }
                    ProgressBar {
                        visible: root.busy
                        from: 0
                        to: 1
                        value: root.progress
                        Layout.fillWidth: true
                    }
                }
            }
            RowLayout {
                id: footer
                visible: !root.configuration
                Layout.fillWidth: true
                Button {
                    text: qsTr("Reset")
                    enabled: !!root.field && !root.saving
                    onClicked: root.resetGrid()
                }
                Button {
                    text: root.busy ? qsTr("Cancel") : qsTr("Preview")
                    enabled: !!root.field && !root.saving
                    onClicked: root.busy ? root.cancelPreview() : root.startPreview(false)
                }
                Button {
                    Layout.fillWidth: true
                    text: qsTr("Apply split")
                    highlighted: true
                    enabled: !!root.field && !root.busy && !root.saving
                    onClicked: root.preview ? root.review() : root.startPreview(true)
                }
            }
        }
    }

    Component {
        id: featureAction

        MenuItem {
            required property bool focusedForm
            text: qsTr("Split with grid")
            height: 48
            enabled: !root.saving && !!root.menuSelection(focusedForm)
            onTriggered: root.openSelectedField(focusedForm)
        }
    }

    Dialog {
        id: pickDialog
        parent: iface.mainWindow().contentItem
        anchors.centerIn: parent
        width: Math.min(440, parent.width - 30)
        modal: true
        title: qsTr("Select a field at this location")
        standardButtons: Dialog.Ok | Dialog.Cancel
        ComboBox {
            id: hitPicker
            width: pickDialog.availableWidth
            model: root.hits.map(hit => hit.name + " · " + hit.id)
        }
        onAccepted: root.tryAction(() => root.useField(root.hits[hitPicker.currentIndex]))
    }

    Dialog {
        id: reviewDialog
        parent: iface.mainWindow().contentItem
        anchors.centerIn: parent
        width: Math.min(490, parent.width - 28)
        modal: true
        title: qsTr("Split selected field")
        standardButtons: Dialog.Save | Dialog.Cancel
        onAccepted: root.tryAction(root.save)
        ColumnLayout {
            width: reviewDialog.availableWidth
            Label {
                Layout.fillWidth: true
                wrapMode: Text.Wrap
                text: root.summary() + "\n" + qsTr("Zones will be saved to the selected field's layer. Zone numbers appear in the preview.")
            }
            Label { text: qsTr("Change a zone number") }
            ComboBox {
                id: zonePicker
                Layout.fillWidth: true
                model: root.numbered.map(zone => zone.number)
            }
            RowLayout {
                TextField { id: customNumber; Layout.fillWidth: true; placeholderText: qsTr("Custom number") }
                Button {
                    text: qsTr("Set")
                    onClicked: root.tryAction(() => {
                        const zone = root.numbered[zonePicker.currentIndex]
                        if (!zone || !customNumber.text.trim())
                            return
                        const previous = root.overrides
                        root.overrides = Object.assign({}, previous, { [zone.key]: customNumber.text.trim() })
                        try {
                            root.recount()
                            customNumber.clear()
                            root.error = ""
                        } catch (err) {
                            root.overrides = previous
                            throw err
                        }
                    })
                }
            }
            Label { Layout.fillWidth: true; wrapMode: Text.Wrap; text: root.error }
        }
    }

    Dialog {
        id: undoDialog
        parent: iface.mainWindow().contentItem
        anchors.centerIn: parent
        width: Math.min(440, parent.width - 28)
        modal: true
        title: qsTr("Undo last split")
        standardButtons: Dialog.Ok | Dialog.Cancel
        onAccepted: root.tryAction(root.undo)
        Label {
            width: undoDialog.availableWidth
            wrapMode: Text.Wrap
            text: qsTr("Restore the field to its shape before the last split?")
        }
    }

    function tryAction(action) {
        try {
            action()
        } catch (err) {
            error = String(err.message || err)
            iface.logMessage("AgroGrid: " + error)
        }
    }

    function evaluate(expression, variables) {
        evaluator.variables = variables || {}
        return evaluator.evaluate(expression)
    }

    function crs(name) {
        return QfCoordinateReferenceSystemUtils.fromDescription(name)
    }

    function reprojectWkt(wkt, from, to) {
        if (from === to)
            return wkt
        return Geometry.value(evaluate,
            "geom_to_wkt(transform(geom_from_wkt(@a),@source_crs,@target_crs),17)",
            { a: wkt, source_crs: from, target_crs: to })
    }

    function pointBetween(point, from, to) {
        return from === to ? point : Geometry.pointFromWkt(root.reprojectWkt(Geometry.pointWkt(point), from, to))
    }

    function mapPoint(coordinates, source) {
        const [x, y] = pointBetween(coordinates, source, mapSettings.destinationCrs.authid)
        return QfGeometryUtils.point(x, y)
    }

    function screenCoordinate(x, y, targetCrs) {
        const point = mapSettings.screenToCoordinate(Qt.point(x, y))
        const result = [point.x, point.y]
        Geometry.check(result.every(Number.isFinite), qsTr("Could not transform the map point."))
        return pointBetween(result, mapSettings.destinationCrs.authid, targetCrs)
    }

    function screenBasis(degrees) {
        const grid = Grid.create(anchor, hectares, degrees)
        const points = [Grid.coordinate(grid, 0, 0), Grid.coordinate(grid, 1, 0),
                        Grid.coordinate(grid, 0, 1)]
        return mapRings([points], field.metric)[0].map(point => mapSettings.coordinateToScreen(point))
    }

    function beginRotation() {
        if (!field)
            return
        clearDrag()
        redrawTimer.stop()
        rotationBasis = screenBasis(0)
    }

    function setRotation(value) {
        angle = value
        angleInput.text = String(value)
        if (!rotationBasis) {
            invalidate()
            savePreferences()
            return
        }
        if (work || preview || error || notice)
            cancelPreview()
        drawing.requestPaint()
    }

    function finishRotation() {
        if (rotationBasis) {
            rotationBasis = null
            updateMap()
        }
        savePreferences()
    }

    function beginDrag(x, y) {
        if (rotationBasis)
            finishRotation()
        dragBasis = screenBasis(angle)
        dragStart = Qt.point(x, y)
    }

    function moveDrag(x, y) {
        if (x === dragStart.x && y === dragStart.y && !dragOffset)
            return
        if (!dragOffset && (work || preview || error || notice))
            cancelPreview()
        dragOffset = Qt.point(x - dragStart.x, y - dragStart.y)
        drawing.requestPaint()
    }

    function finishDrag(x, y) {
        const start = dragStart
        clearDrag()
        if (x === start.x && y === start.y)
            return
        const from = screenCoordinate(start.x, start.y, field.metric)
        const to = screenCoordinate(x, y, field.metric)
        anchor = [anchor[0] + to[0] - from[0], anchor[1] + to[1] - from[1]]
        if (work || preview || error || notice)
            cancelPreview()
        redrawTimer.stop()
        updateMap()
    }

    function clearDrag() {
        if (!dragStart)
            return
        dragStart = null
        dragBasis = null
        dragOffset = null
        drawing.requestPaint()
    }

    function mapViewChanged() {
        fieldScreenCache = null
        clearDrag()
        if (rotationBasis && field)
            tryAction(() => { rotationBasis = screenBasis(0) })
        drawing.requestPaint()
    }

    function projectSettings() {
        const values = JSON.parse(settings.projects)
        return values[projectPath] || { operations: [], prefs: {} }
    }

    function writeSettings(value) {
        const values = JSON.parse(settings.projects)
        values[projectPath] = value
        settings.projects = JSON.stringify(values)
        settings.sync()
    }

    function savePreferences() {
        if (!projectPath || !panelOpen)
            return
        const state = projectSettings()
        state.prefs = { layerId: selectedLayer ? selectedLayer.id : "", hectares, angle, numbering,
                        start: startNumber.text, prefix: prefixNumber.text,
                        order: order.currentIndex, reverse: reverse.checked }
        writeSettings(state)
    }

    function registerActions() {
        iface.addItemToPluginsToolbar(launcher)
        featureForm = iface.findItemByObjectName("featureForm")
        if (!featureForm)
            return
        for (const option of [{ name: "featureMenu", focused: true },
                              { name: "featureListMenu", focused: false }]) {
            const menu = iface.findItemByObjectName(option.name)
            if (!menu || typeof menu.insertItem !== "function")
                continue
            const item = featureAction.createObject(root, { focusedForm: option.focused })
            if (item) {
                menu.insertItem(option.focused ? 1 : 0, item)
                featureActions.push({ menu, item })
            }
        }
    }

    function menuSelection(focusedForm) {
        const selection = featureForm ? featureForm.selection : null
        const model = featureForm ? featureForm.model : null
        if (!selection || !model)
            return null
        let layer, feature
        if (focusedForm && selection.focusedItem >= 0) {
            layer = selection.focusedLayer
            feature = selection.focusedFeature
        } else if (!focusedForm && model.selectedCount === 1) {
            layer = model.selectedLayer
            feature = model.selectedFeatures[0]
        } else if (!focusedForm && model.selectedCount === 0 && model.count === 1) {
            const index = model.index(0, 0)
            layer = model.data(index, QfMultiFeatureListModel.LayerRole)
            feature = model.data(index, QfMultiFeatureListModel.FeatureRole)
        }
        if (!layer || !feature || !feature.geometry || !layer.crs || !layer.crs.authid)
            return null
        const sourceWkt = feature.geometry.asWkt(17)
        return /^(multi)?polygon\s*\(/i.test(sourceWkt) ? { layer, feature, sourceWkt } : null
    }

    function openSelectedField(focusedForm) {
        tryAction(() => {
            const entry = menuSelection(focusedForm)
            if (!entry)
                return
            const candidate = fieldCandidate(entry.layer, entry.feature, entry.sourceWkt)
            featureForm.state = "Hidden"
            openPanel({ layer: entry.layer, candidate })
        })
        if (error && !panelOpen)
            iface.mainWindow().displayToast(error)
    }

    function openPanel(selection) {
        tryAction(() => {
            Geometry.check(projectPath && mapSettings, qsTr("Open a QField project first."))
            recoverPending(projectSettings())
            const prefs = projectSettings().prefs
            hectares = prefs.hectares || settings.defaultHectares
            angle = prefs.angle || 0
            gridOpacity = settings.defaultOpacity
            numbering = prefs.numbering || settings.defaultNumbering
            areaInput.text = String(hectares)
            angleInput.text = String(angle)
            numberingMode.currentIndex = ["field", "prefix", "continuous"].indexOf(numbering)
            startNumber.text = prefs.start || "1"
            prefixNumber.text = prefs.prefix || ""
            order.currentIndex = prefs.order || 0
            reverse.checked = !!prefs.reverse
            fieldLocked = !!selection
            layers = selection ? [selection.layer] : findLayers()
            let index = layers.findIndex(layer => layer.id === prefs.layerId)
            if (index < 0 && layers.length)
                index = 0
            layerPicker.currentIndex = index
            chooseLayer(index < 0 ? null : layers[index])
            panelOpen = true
            if (selection)
                useField(selection.candidate)
        })
        if (error && !panelOpen)
            iface.mainWindow().displayToast(error)
    }

    function closePanel() {
        panelOpen = false
        fieldLocked = false
        cancelPreview()
        field = null
        selectedLayer = null
        mode = "pick"
        configuration = false
        clearDrag()
        rotationBasis = null
        drawSegments = []
        fieldMapCache = null
        fieldScreenCache = null
    }

    function findLayers() {
        const source = QfProjectUtils.mapLayers(qgisProject)
        return Object.values(source).filter(layer => {
            if (!layer || !layer.isValid || Number(layer.type) !== 0)
                return false
            const it = QfLayerUtils.createFeatureIteratorFromExpression(layer, "$geometry IS NOT NULL")
            try {
                return it.hasNext() && /^(multi)?polygon\s*\(/i.test(it.next().geometry.asWkt(17))
            } finally {
                it.close()
            }
        }).sort((left, right) => left.name.localeCompare(right.name, "en"))
    }

    function chooseLayer(layer) {
        cancelPreview()
        field = null
        selectedLayer = layer
        mode = "pick"
        error = ""
        savePreferences()
    }

    function pick(x, y) {
        if (!selectedLayer)
            return
        const source = selectedLayer.crs.authid
        Geometry.check(source, qsTr("The layer does not have a recognized coordinate reference system."))
        const coordinates = screenCoordinate(x, y, source)
        const nearby = screenCoordinate(x + 3, y + 3, source)
        const radius = Math.max(Math.abs(nearby[0] - coordinates[0]), Math.abs(nearby[1] - coordinates[1]))
        const rectangle = QfGeometryUtils.createRectangleFromPoints(
            QfGeometryUtils.point(coordinates[0] - radius, coordinates[1] - radius),
            QfGeometryUtils.point(coordinates[0] + radius, coordinates[1] + radius))
        const it = QfLayerUtils.createFeatureIteratorFromRectangle(selectedLayer, rectangle)
        const matches = []
        try {
            while (it.hasNext()) {
                const feature = it.next()
                const sourceWkt = feature.geometry.asWkt(17)
                if (Geometry.truth(evaluate("intersects(geom_from_wkt(@a),geom_from_wkt(@b))",
                                           { a: sourceWkt, b: Geometry.pointWkt(coordinates) }))) {
                    matches.push(fieldCandidate(selectedLayer, feature, sourceWkt))
                }
            }
        } finally {
            it.close()
        }
        Geometry.check(matches.length > 0, qsTr("There is no field from the selected layer at this location."))
        error = ""
        if (matches.length === 1)
            useField(matches[0])
        else {
            hits = matches
            pickDialog.open()
        }
    }

    function fieldCandidate(layer, feature, sourceWkt) {
        const id = String(feature.id)
        Geometry.check(/^-?\d+$/.test(id), qsTr("QField did not provide a field ID."))
        return { id, sourceWkt, source: layer.crs.authid, layerId: layer.id,
                 name: QfFeatureUtils.displayName(layer, feature) || qsTr("Field %1").arg(id) }
    }

    function useField(candidate) {
        const sourcePolygons = Geometry.polygons(candidate.sourceWkt)
        Geometry.check(sourcePolygons.length && Geometry.valid(evaluate, candidate.sourceWkt),
                       qsTr("The field boundary has invalid geometry."))
        const interior = Geometry.pointOnSurface(evaluate, candidate.sourceWkt)
        const position = pointBetween(interior, candidate.source, "EPSG:4326")
        const metric = Grid.metricCrs(position[0], position[1])
        const metricWkt = root.reprojectWkt(candidate.sourceWkt, candidate.source, metric)
        const metricPolygons = Geometry.polygons(metricWkt)
        const metricArea = Geometry.area(evaluate, metricWkt)
        Geometry.check(metricArea > 0, qsTr("Could not measure the field area."))
        const destination = pointBetween(interior, candidate.source, metric)
        field = Object.assign({}, candidate, { sourcePolygons, metricPolygons, metric,
                                               area: metricArea, center: destination })
        anchor = destination
        mode = "map"
        invalidate()
        updateMap()
        savePreferences()
    }

    function applyArea() {
        const amount = Number(areaInput.text.replace(",", "."))
        if (!Number.isFinite(amount) || amount <= 0) {
            error = qsTr("Cell area must be greater than zero.")
            areaInput.text = String(hectares)
            return
        }
        if (hectares !== amount) {
            hectares = amount
            invalidate()
            savePreferences()
        }
    }

    function applyAngle() {
        const amount = Number(angleInput.text.replace(",", "."))
        if (!angleInput.text.trim() || !Number.isFinite(amount) || amount < 0 || amount > 180) {
            error = qsTr("Enter an angle from 0 to 180°.")
            angleInput.text = String(angle)
            return
        }
        if (angle !== amount) {
            angle = amount
            invalidate()
            savePreferences()
        }
    }

    function cancelPreview() {
        geometryTimer.stop()
        busy = false
        work = null
        validator = null
        preview = null
        numbered = []
        overrides = ({})
        notice = ""
        error = ""
        mapZoneRings = []
        mapZoneLabels = []
        drawing.requestPaint()
    }

    function invalidate() {
        clearDrag()
        rotationBasis = null
        if (work || preview || error || notice)
            cancelPreview()
        if (!redrawTimer.running)
            redrawTimer.start()
    }

    function resetGrid() {
        anchor = field.center
        angle = 0
        angleInput.text = "0"
        invalidate()
        savePreferences()
    }

    function cacheFieldOutline() {
        const crs = mapSettings.destinationCrs.authid
        if (!fieldMapCache || fieldMapCache.field !== field || fieldMapCache.crs !== crs) {
            const rings = []
            for (const polygon of field.sourcePolygons) {
                polygon.forEach((ring, index) => {
                    let winding = 0
                    const [ox, oy] = ring[0]
                    for (let i = 1; i < ring.length; ++i)
                        winding += (ring[i - 1][0] - ox) * (ring[i][1] - oy) -
                                   (ring[i][0] - ox) * (ring[i - 1][1] - oy)
                    rings.push((winding > 0) === (index === 0) ? ring : ring.slice().reverse())
                })
            }
            fieldMapCache = { field, crs, rings: mapRings(rings, field.source) }
            fieldScreenCache = null
        }
    }

    function screenField() {
        if (!fieldMapCache || fieldMapCache.field !== field)
            return null
        if (!fieldScreenCache) {
            const bounds = { left: Infinity, top: Infinity, right: -Infinity, bottom: -Infinity }
            const rings = fieldMapCache.rings.map(ring => ring.map(point => {
                const screen = mapSettings.coordinateToScreen(point)
                bounds.left = Math.min(bounds.left, screen.x)
                bounds.right = Math.max(bounds.right, screen.x)
                bounds.top = Math.min(bounds.top, screen.y)
                bounds.bottom = Math.max(bounds.bottom, screen.y)
                return screen
            }))
            bounds.left = Math.max(0, bounds.left)
            bounds.right = Math.min(drawing.width, bounds.right)
            bounds.top = Math.max(0, bounds.top)
            bounds.bottom = Math.min(drawing.height, bounds.bottom)
            fieldScreenCache = { rings, bounds }
        }
        return fieldScreenCache
    }

    function updateMap() {
        if (!field || !panelOpen)
            return
        tryAction(() => {
            cacheFieldOutline()
            const grid = Grid.create(anchor, hectares, angle)
            const box = Grid.range(grid, field.metricPolygons, 1)
            const segments = []
            function line(startColumn, startRow, endColumn, endRow) {
                const steps = Math.min(24, Math.max(1, Math.ceil(grid.size *
                    Math.hypot(endColumn - startColumn, endRow - startRow) / 200)))
                const points = []
                for (let i = 0; i <= steps; ++i)
                    points.push(Grid.coordinate(grid, startColumn + (endColumn - startColumn) * i / steps,
                                                startRow + (endRow - startRow) * i / steps))
                return points
            }
            for (let col = box.west; col <= box.east; ++col)
                segments.push(line(col, box.south, col, box.north))
            for (let row = box.south; row <= box.north; ++row)
                segments.push(line(box.west, row, box.east, row))
            drawSegments = mapRings(segments, field.metric)
            const zoneRings = []
            if (preview)
                for (const zone of preview.zones)
                    for (const ring of zone.polygon)
                        zoneRings.push(ring)
            mapZoneRings = mapRings(zoneRings, field.source)
            mapZoneLabels = numbered.length > 300 ? [] : numbered.map(zone =>
                ({ text: zone.number, point: mapPoint(zone.labelPoint, field.source) }))
        })
        drawing.requestPaint()
    }

    function mapRings(rings, source) {
        if (rings.length && source !== mapSettings.destinationCrs.authid) {
            const lines = "MULTILINESTRING(" +
                rings.map(ring => "(" + ring.map(point => point.join(" ")).join(",") + ")").join(",") + ")"
            const match = /^multilinestring\s*\(\s*\(([\s\S]+)\)\s*\)$/i.exec(
                root.reprojectWkt(lines, source, mapSettings.destinationCrs.authid))
            Geometry.check(match, qsTr("Could not transform the grid to the map's coordinate reference system."))
            rings = match[1].split(/\)\s*,\s*\(/).map(line => line.split(",").map(Geometry.coordinate))
        }
        return rings.map(ring => ring.map(point => QfGeometryUtils.point(point[0], point[1])))
    }

    function startPreview(showReview) {
        tryAction(() => {
            cancelPreview()
            applyArea()
            applyAngle()
            Geometry.check(!error, error)
            const sourceField = field
            const grid = Grid.create(anchor, hectares, angle)
            work = Geometry.createSplit(evaluate, sourceField.sourceWkt, sourceField.metricPolygons, grid,
                point => pointBetween(point, sourceField.metric, sourceField.source),
                wkt => root.reprojectWkt(wkt, sourceField.source, sourceField.metric))
            busy = true
            mode = "map"
            progress = 0
            work.showReview = showReview
            geometryTimer.start()
        })
    }

    function advance() {
        try {
            const deadline = Date.now() + 12
            do {
                if (!validator && !work.step())
                    validator = work.validator()
                if (validator && !validator.step()) {
                    geometryTimer.stop()
                    busy = false
                    preview = work
                    work = null
                    validator = null
                    for (const zone of preview.zones)
                        zone.labelPoint = Geometry.pointOnSurface(evaluate, zone.wkt)
                    recount()
                    updateMap()
                    notice = summary()
                    if (preview.showReview)
                        review()
                    return
                }
            } while (Date.now() < deadline)
            progress = validator ? 0.96 : work.progress() * 0.95
        } catch (err) {
            cancelPreview()
            error = String(err.message || err)
        }
    }

    function updateNumbering() {
        savePreferences()
        tryAction(() => {
            if (preview) {
                recount()
                updateMap()
            }
            error = ""
        })
    }

    function recount() {
        const options = { mode: numbering, start: Number(startNumber.text), prefix: prefixNumber.text,
                          columns: order.currentIndex === 1, reverse: reverse.checked }
        const operations = projectSettings().operations.filter(entry => !entry.files && !entry.undone)
        const occupied = (numbering === "field" ? [] : operations)
            .reduce((all, entry) => all.concat(entry.numbers), [])
        numbered = Grid.numberZones(preview.zones, options, occupied, overrides)
    }

    function formatHa(squareMetres) {
        return Number(squareMetres / 10000).toLocaleString(Qt.locale("en_US"), "f", 4) + " ha"
    }

    function summary() {
        if (!preview || !field)
            return ""
        const areas = preview.zones.map(zone => zone.squareMetres)
        return qsTr("Zones: %1 · Cell: %2 · Angle: %3°\nField: %4 · Total: %5 · Min: %6 · Max: %7")
            .arg(areas.length).arg(formatHa(hectares * 10000)).arg(angle)
            .arg(formatHa(field.area)).arg(formatHa(areas.reduce((sum, area) => sum + area, 0)))
            .arg(formatHa(Math.min(...areas))).arg(formatHa(Math.max(...areas)))
    }

    function review() {
        tryAction(() => {
            recount()
            error = ""
            customNumber.clear()
            reviewDialog.open()
        })
    }

    function editableLayer(layerId) {
        const layer = QfProjectUtils.mapLayers(qgisProject)[layerId]
        Geometry.check(layer && layer.isValid && !layer.readOnly,
                       qsTr("The field layer is unavailable for editing."))
        Geometry.check(Number(qgisProject.transactionMode) === 0,
                       qsTr("Disable project transaction grouping in QGIS to split this field."))
        Geometry.check(!layer.editBuffer(), qsTr("Finish the current edits to the field layer in QField first."))
        const cloudAction = String(layer.customProperty("QFieldSync/cloud_action", "")).toUpperCase()
        Geometry.check(cloudAction !== "NO_ACTION" && cloudAction !== "REMOVE",
                       qsTr("QFieldCloud synchronization is disabled for this layer in QFieldSync."))
        return layer
    }

    function nativeGeometry(wkt) {
        return QfGeometryUtils.createGeometryFromWkt(wkt)
    }

    function snapshot(feature) {
        const wkt = feature.geometry.asWkt(17)
        return /^(multi)?polygon\s*\(/i.test(wkt)
            ? { id: String(feature.id), wkt,
                attributes: JSON.stringify(feature.fields.names.map(name => feature.attribute(name))) } : null
    }

    function nativeEdit(layer, action) {
        Geometry.check(!layer.editBuffer() && layer.startEditing(),
                       qsTr("QField could not start editing the field layer."))
        try {
            action()
            Geometry.check(layer.commitChanges(), qsTr("The layer rejected the changes. Check the QField log."))
        } finally {
            if (layer.editBuffer())
                layer.rollBack()
            editor.currentLayer = null
            layer.triggerRepaint()
        }
    }

    function nativeApi(layer) {
        return {
            check: Geometry.check,
            persist: state => root.writeSettings(state),
            read: id => root.snapshot(layer.getFeature(Number(id))),
            same: (part, wkt) => !!part && (part.wkt === wkt || Geometry.same(evaluate, part.wkt, wkt, "Polygon")),
            nearby: wkt => {
                const bounds = QfGeometryUtils.boundingBox(root.nativeGeometry(wkt))
                const iterator = QfLayerUtils.createFeatureIteratorFromRectangle(layer, bounds)
                const parts = []
                try {
                    while (iterator.hasNext()) {
                        const part = root.snapshot(iterator.next())
                        if (part)
                            parts.push(part)
                    }
                } finally {
                    iterator.close()
                }
                return parts
            },
            edit: action => root.nativeEdit(layer, action),
            add: operation => {
                editor.currentLayer = layer
                const original = layer.getFeature(Number(operation.fieldId))
                editor.feature = original
                Geometry.check(!editor.geometryEditingLocked,
                               qsTr("Geometry editing is locked for the selected field."))
                for (const piece of operation.pieces) {
                    editor.feature = QfFeatureUtils.createFeature(layer, root.nativeGeometry(piece))
                    editor.updateAttributesFromFeature(original)
                    Geometry.check(!editor.featureAdditionLocked && QfLayerUtils.addFeature(layer, editor.feature),
                                   qsTr("The layer rejected a new zone."))
                }
            },
            change: (id, wkt) => {
                editor.currentLayer = layer
                editor.feature = layer.getFeature(Number(id))
                Geometry.check(!editor.geometryEditingLocked && editor.changeGeometry(root.nativeGeometry(wkt))
                               && editor.save(false), qsTr("QField could not change the field geometry."))
                const current = root.snapshot(layer.getFeature(Number(id)))
                Geometry.check(current && (current.wkt === wkt || Geometry.same(evaluate, current.wkt, wkt, "Polygon")),
                               qsTr("QField did not record the geometry change in its edit buffer."))
            },
            remove: parts => {
                editor.currentLayer = layer
                for (const part of parts) {
                    editor.feature = layer.getFeature(Number(part.id))
                    Geometry.check(!editor.featureDeletionLocked && layer.deleteFeature(Number(part.id)),
                                   qsTr("The layer did not allow zone %1 to be deleted.").arg(part.id))
                }
            }
        }
    }

    function recoverPending(state) {
        if (state.pendingCut)
            NativeCut.settleCut(nativeApi(editableLayer(state.pendingCut.layerId)), state)
        if (state.pendingUndo) {
            const operation = state.operations.find(entry => entry.id === state.pendingUndo)
            NativeCut.undo(nativeApi(editableLayer(operation.layerId)), state, operation)
        }
    }

    function save() {
        if (saving || !field || !preview)
            return
        saving = true
        try {
            error = ""
            recount()
            const state = projectSettings()
            recoverPending(state)
            const layer = editableLayer(field.layerId)
            const api = nativeApi(layer)
            const original = api.read(field.id)
            Geometry.check(layer.crs.authid === field.source && api.same(original, field.sourceWkt),
                           qsTr("The field has changed since it was selected. Select it again."))
            const type = Number(layer.wkbType())
            Geometry.check(type === 3 || type === 6, qsTr("Splitting supports 2D polygon layers."))
            const zones = numbered.slice().sort((a, b) => b.squareMetres - a.squareMetres)
            const wkts = zones.map(zone => {
                const wkt = type === 3 ? zone.wkt : "MULTIPOLYGON(" + zone.wkt.slice(7) + ")"
                return nativeGeometry(wkt).asWkt(17)
            })
            const operation = {
                id: Geometry.uuid(evaluate), layerId: field.layerId, fieldId: field.id,
                original: original.wkt, retained: wkts[0], pieces: wkts.slice(1),
                numbers: numbered.map(zone => zone.number)
            }
            NativeCut.cut(api, state, operation)
            closePanel()
            iface.mainWindow().displayToast(qsTr("Zones saved to the field layer: %1. Use ‘Upload local changes’ to sync.")
                                           .arg(zones.length))
        } finally {
            saving = false
        }
    }

    function undo() {
        const state = projectSettings()
        const recoveringUndo = !!state.pendingUndo
        recoverPending(state)
        if (!recoveringUndo) {
            const latest = state.operations.slice().reverse().find(entry => !entry.files && !entry.undone)
            Geometry.check(latest, qsTr("There is no saved split to undo."))
            NativeCut.undo(nativeApi(editableLayer(latest.layerId)), state, latest)
        }
        closePanel()
        iface.mainWindow().displayToast(qsTr("Field restored. Use ‘Upload local changes’ to sync."))
    }
}
