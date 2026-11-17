.pragma library
.import "Grid.js" as Grid

function check(condition, message) {
    if (!condition)
        throw new Error(message)
}

function value(evaluate, expression, variables) {
    const result = evaluate(expression, variables)
    check(result !== "" && result !== null && result !== undefined,
          qsTr("QGIS did not return a geometry calculation result."))
    return result
}

function truth(result) {
    return result === true || result === "true" || result === "1" || result === 1
}

function number(evaluate, expression, variables) {
    const result = Number(value(evaluate, expression, variables))
    check(Number.isFinite(result), qsTr("The geometry measurement is invalid."))
    return result
}

function coordinate(text) {
    const point = text.trim().split(/\s+/).map(Number)
    check(point.length === 2 && point.every(Number.isFinite),
          qsTr("Only 2D coordinates are supported."))
    return point
}

function rings(text) {
    return text.replace(/^\s*\(|\)\s*$/g, "").split(/\)\s*,\s*\(/)
        .map(ring => ring.replace(/^\s*\(|\)\s*$/g, "").split(",").map(coordinate))
}

function polygons(wkt) {
    const text = String(wkt).trim()
    if (/EMPTY\s*$/i.test(text) || /^(multi)?(point|linestring)\b/i.test(text))
        return []
    if (/^polygon\s*\(/i.test(text))
        return [rings(text.replace(/^polygon\s*/i, ""))]
    if (/^multipolygon\s*\(/i.test(text))
        return text.replace(/^multipolygon\s*\(|\)\s*$/gi, "")
            .split(/\)\)\s*,\s*\(\(/).map((polygon, index, items) =>
                rings((index ? "((" : "") + polygon + (index < items.length - 1 ? "))" : "")))
    if (/^geometrycollection\s*\(/i.test(text)) {
        const content = text.slice(text.indexOf("(") + 1, -1)
        const parts = []
        let level = 0, start = 0
        for (let i = 0; i < content.length; ++i) {
            if (content[i] === "(") ++level
            if (content[i] === ")") --level
            if (content[i] === "," && level === 0) {
                parts.push(content.slice(start, i))
                start = i + 1
            }
        }
        return parts.concat(content.slice(start)).reduce((all, part) => all.concat(polygons(part)), [])
    }
    throw new Error(qsTr("A 2D Polygon or MultiPolygon with straight edges is required."))
}

function polygonWkt(polygon) {
    return "POLYGON(" + polygon.map(ring => "(" + ring.map(point => point.join(" ")).join(",") + ")").join(",") + ")"
}

function pointWkt(point) {
    return "POINT(" + point.join(" ") + ")"
}

function pointFromWkt(wkt) {
    const match = /^point\s*\(([^()]+)\)$/i.exec(wkt)
    check(match, qsTr("Could not read the point."))
    return coordinate(match[1])
}

function area(evaluate, geometry) {
    return number(evaluate, "area(geom_from_wkt(@a))", { a: geometry })
}

function valid(evaluate, geometry) {
    return truth(value(evaluate, "is_valid(geom_from_wkt(@a))", { a: geometry }))
}

function pointOnSurface(evaluate, geometry) {
    return pointFromWkt(value(evaluate, "geom_to_wkt(point_on_surface(geom_from_wkt(@a)),17)", { a: geometry }))
}

function createSplit(evaluate, source, metricPolygons, grid, toSource, toMetric) {
    const bounds = Grid.range(grid, metricPolygons, 1)
    const edges = new Map()
    const sourceArea = area(evaluate, source)
    const zones = []
    let row = bounds.south
    let column = bounds.west
    let checked = 0
    const sourceTolerance = sourceArea * 1e-8
    check(sourceArea > 0 && valid(evaluate, source), qsTr("The field geometry is invalid."))
    return {
        zones,
        progress: () => checked / bounds.count,
        step: function () {
            if (row >= bounds.north)
                return false
            const ring = Grid.cell(grid, column, row, toSource, edges)
            const result = value(evaluate,
                "with_variable('f',geom_from_wkt(@a),with_variable('c',geom_from_wkt(@b)," +
                "CASE WHEN NOT intersects(@f,@c) THEN 'SKIP' ELSE geom_to_wkt(intersection(@f,@c),17) END))",
                { a: source, b: polygonWkt([ring]) })
            const pieces = result === "SKIP" ? [] : polygons(result)
            // A multipolygon intersection may have disconnected pieces. Sort spatially before assigning IDs.
            pieces.sort((left, right) => polygonWkt(left).localeCompare(polygonWkt(right), "en"))
            pieces.forEach((polygon, part) => {
                const wkt = polygonWkt(polygon)
                if (area(evaluate, wkt) <= 0)
                    return
                check(valid(evaluate, wkt), qsTr("The intersection returned an invalid zone."))
                const squareMetres = area(evaluate, toMetric(wkt))
                check(squareMetres > 0, qsTr("A zone has zero area after transformation."))
                zones.push({ column, row, part, key: [column, row, part].join("/"),
                             polygon, wkt, squareMetres })
            })
            ++checked
            if (++column >= bounds.east) {
                column = bounds.west
                ++row
            }
            return checked < bounds.count
        },
        validator: function () {
            check(zones.length > 1, qsTr("The grid does not split the field. Move it or change the cell area."))
            let parts = zones.map(zone => zone.wkt)
            const sum = parts.reduce((total, wkt) => total + area(evaluate, wkt), 0)
            let next = [], index = 0
            return {
                step: function () {
                    if (parts.length === 1) {
                        const union = parts[0]
                        const difference = number(evaluate,
                            "with_variable('d',sym_difference(geom_from_wkt(@a),geom_from_wkt(@b))," +
                            "CASE WHEN is_empty(@d) THEN 0 ELSE area(@d) END)", { a: union, b: source })
                        check(difference <= sourceTolerance &&
                              Math.abs(sum - area(evaluate, union)) <= sourceTolerance,
                              qsTr("The validation found gaps, overlaps or a change to the field boundary."))
                        return false
                    }
                    next.push(index + 1 === parts.length ? parts[index] :
                        value(evaluate, "geom_to_wkt(union(geom_from_wkt(@a),geom_from_wkt(@b)),17)",
                              { a: parts[index], b: parts[index + 1] }))
                    index += 2
                    if (index >= parts.length) {
                        parts = next
                        next = []
                        index = 0
                    }
                    return true
                }
            }
        }
    }
}

function uuid(evaluate) {
    const id = String(value(evaluate, "uuid()", {})).replace(/[{}]/g, "")
    check(/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id),
          qsTr("QGIS did not return a valid UUID."))
    return id
}

function same(evaluate, expected, actual, type) {
    const expression = type === "Point" ? "distance(geom_from_wkt(@a),geom_from_wkt(@b)) = 0"
        : "relate(geom_from_wkt(@a),geom_from_wkt(@b),'T*F**FFF*')"
    return truth(value(evaluate, expression, { a: expected, b: actual }))
}
