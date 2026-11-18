# AgroGrid for QField

AgroGrid splits a selected field into zones using a square grid. Set the cell area in hectares, slide or rotate the grid over the field, and preview the result before saving. The largest fragment keeps the original feature ID. The other fragments are added to the same layer.

## Install

Download [AgroGrid v0.1.5](dist/agrogrid-v0.1.5.zip), or copy the direct ZIP URL into **QField → Settings → Plugins → Install plugin from URL**. Then enable **AgroGrid** in the plugin manager.

```text
https://raw.githubusercontent.com/erse486/agrogrid/b46b3bdc14a0fdb4cceb45366c6fac3c2b9be61e/dist/agrogrid-v0.1.5.zip
```

The English build uses the same plugin ID as AgroGrid 0.1.4. Installing it replaces the earlier AgroGrid in QField.

## Split a field

1. Tap a field on the map and choose **⋮ → Split with grid**. You can also open AgroGrid using the **AG** button and select a field there.
2. Enter the cell area in hectares. Switch to **Grid** to drag the grid or use the **Angle** slider to rotate it. Switch to **Map** to pan or zoom.
3. Tap **Preview** to check the zones. Zone numbers appear in the preview. Saved features use the existing layer's fields and defaults.
4. Tap **Apply split → Save**. For a QFieldCloud project, use **Upload local changes** to send the edits. The layer must be editable and configured for offline editing in QFieldSync.
5. Use **Options → Undo last split** to restore the field if the split zones are still unchanged. QField records that undo as another layer edit.

AgroGrid supports editable 2D Polygon and MultiPolygon layers with project transaction grouping disabled. The grid supports up to 4,096 cells within its calculation bounds.

## Build and test

Run `python pack.py` to build and verify the installable ZIP. Run `tests/qgis_geometry.py` and `tests/qgis_native_cut.py` with QGIS Python to check geometry and native layer edits. Run `tests/qml_smoke.py` with PyQt6 to check the English panel and grid gestures.

The Polish 0.1.4 build was used successfully on an iPhone. The English 0.1.5 build was checked on desktop using Qt and QGIS. Android and the English build on iOS are awaiting device testing.
