import os
import tempfile
from pathlib import Path

from PyQt6.QtCore import QObject, QUrl
from PyQt6.QtQml import QQmlComponent, QQmlEngine, QQmlExpression
from PyQt6.QtWidgets import QApplication

ROOT = Path(__file__).resolve().parents[1]


def add_module(root, uri, definitions):
    folder = root.joinpath(*uri.split("."))
    folder.mkdir(parents=True, exist_ok=True)
    index = ["module " + uri]
    for name, (singleton, source) in definitions.items():
        (folder / (name + ".qml")).write_text(source, encoding="utf-8")
        index.append(("singleton " if singleton else "") + f"{name} 1.0 {name}.qml")
    (folder / "qmldir").write_text("\n".join(index) + "\n", encoding="utf-8")


def create(engine, data, path):
    component = QQmlComponent(engine)
    component.setData(data.encode(), QUrl.fromLocalFile(str(path)))
    result = component.create()
    if result is None:
        raise RuntimeError("\n".join(item.toString() for item in component.errors()))
    return result


def smoke():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    os.environ.setdefault("QT_QUICK_CONTROLS_STYLE", "Material")
    app = QApplication([])
    app.setOrganizationName("AgroGridTest")
    app.setApplicationName("QML Smoke")
    engine = QQmlEngine()
    warnings = []
    engine.warnings.connect(lambda errors: warnings.extend(item.toString() for item in errors))
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        add_module(directory, "org.qfield.core", {
            "QfProjectUtils": (True, "pragma Singleton\nimport QtQuick\nQtObject { function mapLayers(p) { return ({}) } }"),
            "QfGeometryUtils": (True, "pragma Singleton\nimport QtQuick\nQtObject { function point(x, y) { return Qt.point(x, y) } }"),
        })
        add_module(directory, "org.qfield.gui", {
            "QfFeatureModel": (False, "import QtQuick\nQtObject { property var project }"),
            "QfExpressionEvaluator": (False, """import QtQuick
            QtObject {
                enum Mode { ExpressionMode }
                property int mode
                property var project
                property var variables
                function evaluate(expression) {
                    iface.recordProjection()
                    return variables.a
                }
            }"""),
        })
        engine.addImportPath(str(directory))
        prefab = create(engine, """import QtQuick
        import QtQuick.Controls
        ApplicationWindow {
            id: window
            visible: true
            width: 390
            height: 760
            property int projections: 0
            property QtObject project: QtObject { property string fileName: "/synthetic/agrogrid.qgs" }
            property QtObject pluginInterface: QtObject {
                function mapCanvas() { return map }
                function mainWindow() { return window }
                function addItemToPluginsToolbar(item) {}
                function findItemByObjectName(name) { return null }
                function recordProjection() { ++window.projections }
                function logMessage(message) {}
            }
            Item {
                id: map
                objectName: "testMap"
                anchors.fill: parent
                property bool interactive: true
                property QtObject mapSettings: QtObject {
                    signal extentChanged()
                    property var destinationCrs: ({ authid: "EPSG:3857" })
                    function coordinateToScreen(point) { return Qt.point(point.x, point.y) }
                    function screenToCoordinate(point) { return Qt.point(point.x, point.y) }
                }
            }
        }""", directory / "Harness.qml")
        iface = prefab.property("pluginInterface")
        # The iface returns the ApplicationWindow in QField, whose contentItem hosts dialogs.
        engine.rootContext().setContextProperty("iface", iface)
        engine.rootContext().setContextProperty("qgisProject", prefab.property("project"))
        component = QQmlComponent(engine, QUrl.fromLocalFile(str(ROOT / "plugin" / "main.qml")))
        plugin = component.create()
        if plugin is None:
            raise RuntimeError("\n".join(item.toString() for item in component.errors()))
        def run(source):
            command = QQmlExpression(engine.rootContext(), plugin, source)
            result = command.evaluate()[0]
            if command.hasError():
                raise RuntimeError(command.error().toString())
            return result

        run("openPanel()")
        app.processEvents()
        if plugin.property("error") or warnings:
            raise RuntimeError("\n".join([plugin.property("error"), *warnings]))
        controls = plugin.findChildren(QObject) + prefab.findChildren(QObject)
        texts = {control.property("text") for control in controls
                 if control.metaObject().indexOfProperty("text") >= 0}
        titles = {control.property("title") for control in controls
                  if control.metaObject().indexOfProperty("title") >= 0}
        assert "Apply split" in texts
        assert {"Split selected field", "Undo last split"} <= titles
        map_item = prefab.findChild(QObject, "testMap")
        assert plugin.property("panelOpen") and not map_item.property("interactive"), (
            plugin.property("panelOpen"), map_item.property("interactive"), plugin.property("mode"), plugin.property("error")
        )
        run("""{
            const polygons = [[[[0, 0], [200, 0], [200, 200], [0, 200], [0, 0]]]]
            field = { source: "EPSG:2180", metric: "EPSG:2180",
                      sourcePolygons: polygons, metricPolygons: polygons }
            anchor = [0, 0]
            mode = "drag"
            updateMap()
            beginDrag(10, 10)
        }""")
        app.processEvents()
        assert prefab.property("projections") == 3, plugin.property("error")
        run("{ for (let i = 0; i < 80; ++i) moveDrag(10 + i, 10 + i); }")
        app.processEvents()
        assert prefab.property("projections") == 3
        assert run("anchor[0] === 0 && dragOffset.x === 79")
        run("finishDrag(90, 110)")
        assert prefab.property("projections") == 6, plugin.property("error")
        assert run("anchor[0] === 80 && anchor[1] === 100 && dragOffset === null")
        run("{ beginDrag(20, 20); moveDrag(35, 40); mapViewChanged(); }")
        assert run("dragStart === null && anchor[0] === 80 && anchor[1] === 100")
        run("beginRotation()")
        app.processEvents()
        baseline = prefab.property("projections")
        run("{ for (let i = 0; i < 80; ++i) setRotation(i); }")
        app.processEvents()
        assert prefab.property("projections") == baseline
        assert run("angle === 79 && rotationBasis !== null")
        run("finishRotation()")
        assert prefab.property("projections") == baseline + 1
        assert run("angle === 79 && rotationBasis === null")
        run("closePanel()")
        app.processEvents()
        assert map_item.property("interactive")
        if warnings:
            raise RuntimeError("\n".join(warnings))
        # Explicit destruction avoids teardown diagnostics from the context.
        plugin.deleteLater()
        app.processEvents()
        print("PASS: English panel, 80 drag and 80 rotation updates without reprojection, exact preview on release.")


if __name__ == "__main__":
    smoke()
