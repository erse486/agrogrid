"""Exercise the native-cut journal against a real GeoPackage layer and QGIS edit signals."""
import json
import os
from pathlib import Path
from tempfile import TemporaryDirectory

from qgis.PyQt.QtCore import QObject, pyqtSlot
from qgis.PyQt import sip
from PyQt6.QtQml import QJSEngine
from qgis.core import (
    QgsApplication, QgsCoordinateTransformContext, QgsGeometry, QgsVectorFileWriter, QgsVectorLayer, QgsVectorLayerUtils,
)

ROOT = Path(__file__).resolve().parents[1]
ORIGINAL = "POLYGON((0 0,20 0,20 10,0 10,0 0))"
LEFT = "POLYGON((0 0,10 0,10 10,0 10,0 0))"
RIGHT = "POLYGON((10 0,20 0,20 10,10 10,10 0))"


class LayerAdapter(QObject):
    def __init__(self, layer, original_id):
        super().__init__()
        self.layer = layer
        self.original_id = original_id
        self.events = []
        for signal, name in (
            (layer.committedFeaturesAdded, "add"),
            (layer.committedFeaturesRemoved, "remove"),
            (layer.committedGeometriesChanges, "geometry"),
            (layer.editingStopped, "stop"),
        ):
            signal.connect(lambda *_, tag=name: self.events.append(tag))

    @staticmethod
    def snapshot(feature):
        if not feature.isValid():
            return None
        return {
            "id": str(feature.id()),
            "wkt": feature.geometry().asWkt(17),
            "attributes": json.dumps([feature["fid"], feature["name"]]),
        }

    @pyqtSlot(str, result=str)
    def read(self, feature_id):
        return json.dumps(self.snapshot(self.layer.getFeature(int(feature_id))))

    @pyqtSlot(result=str)
    def allParts(self):
        return json.dumps([self.snapshot(feature) for feature in self.layer.getFeatures()])

    @pyqtSlot(str, str, result=bool)
    def same(self, actual, expected):
        return QgsGeometry.fromWkt(actual).isTopologicallyEqual(QgsGeometry.fromWkt(expected))

    @pyqtSlot(result=bool)
    def start(self):
        return self.layer.startEditing()

    @pyqtSlot(result=bool)
    def commit(self):
        return self.layer.commitChanges()

    @pyqtSlot()
    def rollback(self):
        if self.layer.isEditable():
            self.layer.rollBack()

    @pyqtSlot(str, result=bool)
    def add(self, wkt):
        feature = QgsVectorLayerUtils.createFeature(
            self.layer, QgsGeometry.fromWkt(wkt), {1: self.layer.getFeature(self.original_id)["name"]}
        )
        return self.layer.addFeature(feature)

    @pyqtSlot(str, str, result=bool)
    def change(self, feature_id, wkt):
        return self.layer.changeGeometry(int(feature_id), QgsGeometry.fromWkt(wkt))

    @pyqtSlot(str, result=bool)
    def remove(self, feature_id):
        return self.layer.deleteFeature(int(feature_id))


def run_case(directory, fail, multi):
    def wkt(value):
        return "MULTIPOLYGON(" + value[7:] + ")" if multi else value

    layer_type = "MultiPolygon" if multi else "Polygon"
    memory = QgsVectorLayer(layer_type + "?crs=EPSG:2180&field=name:string", "fields", "memory")
    initial = QgsVectorLayerUtils.createFeature(memory, QgsGeometry.fromWkt(wkt(ORIGINAL)), {0: "Field 73"})
    assert memory.dataProvider().addFeatures([initial])[0]
    path = os.path.join(directory, "fields.gpkg")
    options = QgsVectorFileWriter.SaveVectorOptions()
    options.driverName = "GPKG"
    assert QgsVectorFileWriter.writeAsVectorFormatV3(memory, path, QgsCoordinateTransformContext(), options)[0] == 0
    layer = QgsVectorLayer(path, "fields", "ogr")
    original_id = next(layer.getFeatures()).id()
    adapter = LayerAdapter(layer, original_id)
    engine = QJSEngine()
    global_object = engine.globalObject()
    global_object.setProperty("layer", engine.newQObject(adapter))
    global_object.setProperty("mode", fail)
    data = {"id": "cut", "fieldId": str(original_id), "original": wkt(ORIGINAL),
            "retained": wkt(LEFT), "pieces": [wkt(RIGHT)]}
    global_object.setProperty("operationJson", json.dumps(data))
    source = (ROOT / "plugin" / "NativeCut.js").read_text(encoding="utf-8")
    script = r"""
    function qsTr(value) { return value }
    function check(condition, message) { if (!condition) throw new Error(message) }
    const operation = JSON.parse(operationJson)
    let state = { operations: [] }
    let saved
    let phase = 0
    const api = {
        check, persist: state => { saved = JSON.stringify(state) },
        read: id => JSON.parse(layer.read(id)), nearby: () => JSON.parse(layer.allParts()),
        same: (part, wkt) => !!part && layer.same(part.wkt, wkt),
        edit: action => {
            check(layer.start(), "Start edit")
            try {
                action()
                check(layer.commit(), "Commit")
                if (mode === "addFailure" && ++phase === 1)
                    throw new Error("Simulated partial commit")
            } finally {
                layer.rollback()
            }
        },
        add: op => op.pieces.forEach(wkt => check(layer.add(wkt), "Add")),
        change: (id, wkt) => check(layer.change(id, wkt), "Change"),
        remove: parts => parts.forEach(part => check(layer.remove(part.id), "Remove"))
    }
    if (mode === "addFailure") {
        let failed = false
        try { cut(api, state, operation) } catch (error) { failed = true }
        check(failed, "Fault was not reported")
        check(api.nearby().length === 1 && api.same(api.read(operation.fieldId), operation.original), "Source intact")
        check(!JSON.parse(saved).pendingCut && !state.operations.length, "Recovery persisted")
    } else {
        cut(api, state, operation)
        check(api.nearby().length === 2 && api.same(api.read(operation.fieldId), operation.retained), "Cut persisted")
        check(api.nearby().every(part => JSON.parse(part.attributes)[1] === "Field 73"), "Attributes carried over")
        state = JSON.parse(saved)
        if (mode === "undoFailure") {
            const regularRemove = api.remove
            api.remove = () => { throw new Error("Simulated delete failure") }
            let failed = false
            try { undo(api, state, state.operations[0]) } catch (error) { failed = true }
            check(failed && api.same(api.read(operation.fieldId), operation.original), "Original restored after failure")
            state = JSON.parse(saved)
            api.remove = regularRemove
        }
        undo(api, state, state.operations[0])
        check(api.nearby().length === 1 && api.same(api.read(operation.fieldId), operation.original), "Undo persisted")
        check(state.operations[0].undone && !state.pendingUndo, "Undo journal")
    }
    """
    result = engine.evaluate(source.split("\n", 1)[1] + script)
    if result.isError():
        raise RuntimeError(result.property("stack").toString() + "\n" + result.toString())
    fresh = QgsVectorLayer(path, "fields reopened", "ogr")
    assert fresh.featureCount() == 1
    assert adapter.same(fresh.getFeature(original_id).geometry().asWkt(17), wkt(ORIGINAL))
    changes = [event for event in adapter.events if event != "stop"]
    assert changes == (["add", "remove"] if fail == "addFailure" else ["add", "geometry", "geometry", "remove"])
    assert adapter.events.count("stop") >= len(changes)
    sip.delete(fresh)
    sip.delete(layer)


if __name__ == "__main__":
    QgsApplication.setPrefixPath(os.environ["QGIS_PREFIX_PATH"], True)
    app = QgsApplication([], False)
    app.initQgis()
    for mode, multi in (("normal", False), ("normal", True), ("addFailure", False), ("undoFailure", True)):
        with TemporaryDirectory() as directory:
            run_case(directory, mode, multi)
    print("PASS: GeoPackage, native edit signals, Polygon and MultiPolygon, failed add recovery, undo retry.")
