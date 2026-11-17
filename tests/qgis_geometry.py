import json
import os
import traceback
from pathlib import Path
from tempfile import TemporaryDirectory

from qgis.PyQt.QtCore import QDateTime, QObject, Qt, pyqtSlot
try:
    from PyQt6.QtQml import QJSEngine
except ImportError:
    from PyQt5.QtQml import QJSEngine
from qgis.core import (
    Qgis, QgsApplication, QgsCoordinateReferenceSystem, QgsExpression,
    QgsExpressionContext, QgsExpressionContextScope, QgsExpressionContextUtils,
    QgsFeatureSink, QgsGeometry, QgsJsonUtils, QgsMemoryProviderUtils,
    QgsProject, QgsVectorFileWriter, QgsVectorLayer,
)

ROOT = Path(__file__).resolve().parents[1]


class Bridge(QObject):
    @pyqtSlot(str, "QVariantMap", result=str)
    def evaluate(self, expression, variables):
        context = QgsExpressionContext()
        context.appendScope(QgsExpressionContextUtils.globalScope())
        scope = QgsExpressionContextScope()
        for name, value in variables.items():
            scope.setVariable(name, value)
        context.appendScope(scope)
        query = QgsExpression(expression)
        query.prepare(context)
        result = query.evaluate(context)
        if query.hasParserError() or query.hasEvalError():
            self.last_error = (expression, {key: value for key, value in variables.items() if key != 'a'},
                query.parserErrorString() or query.evalErrorString())
            return ""
        if isinstance(result, bool):
            return "true" if result else "false"
        return str(result) if result is not None and str(result) != "NULL" else ""

    @pyqtSlot(str, str, result=str)
    def roundtrip(self, geojson, crs):
        try:
            return self._roundtrip(geojson, crs)
        except Exception as error:
            traceback.print_exc()
            return json.dumps({"error": str(error)})

    def _roundtrip(self, geojson, crs):
        fields = QgsJsonUtils.stringToFields(geojson)
        features = QgsJsonUtils.stringToFeatureList(geojson, fields)
        source = QgsMemoryProviderUtils.createMemoryLayer("AgroGrid", fields,
            features[0].geometry().wkbType(), QgsCoordinateReferenceSystem(crs))
        success, _ = source.dataProvider().addFeatures(features)
        assert success
        with TemporaryDirectory(ignore_cleanup_errors=True) as directory:
            path = str(Path(directory) / "test.gpkg")
            config = QgsVectorFileWriter.SaveVectorOptions()
            config.driverName = "GPKG"
            config.layerName = "wynik"
            context = QgsProject.instance().transformContext()
            writer = QgsVectorFileWriter.create(path, fields, source.wkbType(), source.crs(),
                context, config, QgsFeatureSink.RegeneratePrimaryKey)
            assert writer.hasError() == QgsVectorFileWriter.NoError
            for feature in source.getFeatures():
                assert writer.addFeature(feature, QgsFeatureSink.FastInsert)
            del writer
            result = QgsVectorLayer(path, "AgroGrid", "ogr")
            assert result.isValid() and result.crs().authid() == crs
            def serialize(value):
                if isinstance(value, QDateTime):
                    return value.toUTC().toString(Qt.DateFormat.ISODateWithMs)
                return None if str(value) == "NULL" else value

            actual = [{"wkt": item.geometry().asWkt(17), "properties": {
                field.name(): serialize(item[field.name()])
                for field in fields}} for item in result.getFeatures()]
            del result
            bad = QgsVectorFileWriter.create(str(Path(path) / "blocked.gpkg"),
                fields, source.wkbType(), source.crs(), context, config)
            assert bad.hasError() != QgsVectorFileWriter.NoError
            del bad
            return json.dumps(actual, default=str, ensure_ascii=False)


def evaluate(engine, code, name):
    result = engine.evaluate(code, name)
    if result.isError():
        line = result.property("lineNumber").toInt()
        raise RuntimeError(f"{name}:{line}: {result.toString()}")
    return result


def main():
    os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
    app = QgsApplication([], False)
    app.setPrefixPath(os.environ["QGIS_PREFIX_PATH"], True)
    app.initQgis()
    engine = QJSEngine()
    bridge = Bridge()
    bridge.last_error = None
    engine.globalObject().setProperty("bridge", engine.newQObject(bridge))
    evaluate(engine, 'String.prototype.arg = function (value) { return this.replace(/%[1-9]/, value) }; function qsTr(s) { return s }', "Qt helpers")
    try:
        for module, exports in {
            "Grid": "create, coordinate, screenLines, range, cell, metricCrs, numberZones",
            "Geometry": "area, check, coordinate, createSplit, pointFromWkt, pointOnSurface, pointWkt, polygons, polygonWkt, same, truth, uuid, valid, value",
            "Output": "build, geoJson, verify",
        }.items():
            source = (ROOT / "plugin" / (module + ".js")).read_text(encoding="utf-8")
            code = "\n".join(line for line in source.splitlines() if not line.startswith((".pragma", ".import")))
            evaluate(engine, f"var {module} = (() => {{\n{code}\nreturn {{ {exports} }} }})()", module)
        qml = (ROOT / "plugin" / "main.qml").read_text(encoding="utf-8")
        map_rings = qml[qml.index("    function mapRings("):qml.index("    function startPreview(")]
        evaluate(engine, map_rings, "main.qml mapRings")
        print("QGIS", Qgis.QGIS_VERSION, flush=True)
        result = evaluate(engine, (ROOT / "tests" / "geometry_cases.js").read_text(encoding="utf-8"), "geometry_cases.js")
        print(result.toString(), flush=True)
    except RuntimeError:
        if bridge.last_error:
            print(bridge.last_error, flush=True)
        raise


if __name__ == "__main__":
    main()
