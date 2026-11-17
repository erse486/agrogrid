.pragma library
.import "Geometry.js" as Geometry

function build(evaluate, numbered, operation, field, withSamples) {
    const zones = [], samples = []
    const date = new Date().toISOString()
    for (const zone of numbered) {
        const zoneId = Geometry.uuid(evaluate)
        const properties = { zone_id: zoneId, zone_no: zone.number, area_ha: zone.squareMetres / 10000,
                             split_id: operation, source_id: field.id, source_lyr: field.layerId,
                             field_name: field.name, split_at: date }
        zones.push({ type: "Feature", geometry: { type: "Polygon", coordinates: zone.polygon },
                     properties, wkt: zone.wkt })
        if (withSamples) {
            const coordinates = Geometry.pointOnSurface(evaluate, zone.wkt)
            const wkt = Geometry.pointWkt(coordinates)
            Geometry.check(Geometry.truth(Geometry.value(evaluate,
                "contains(geom_from_wkt(@a),geom_from_wkt(@b))", { a: zone.wkt, b: wkt })),
                qsTr("The sample point falls outside the zone."))
            samples.push({ type: "Feature", geometry: { type: "Point", coordinates },
                           properties: { sample_id: Geometry.uuid(evaluate), sample_no: zone.number,
                                         split_id: operation, zone_id: zoneId, zone_no: zone.number,
                                         taken_at: "", status: "planowana", notes: "" }, wkt })
        }
    }
    return { zones, samples }
}

function geoJson(features) {
    return JSON.stringify({ type: "FeatureCollection",
        features: features.map(({ type, geometry, properties }) => ({ type, geometry, properties })) })
}

function verify(evaluate, expected, actual, geometryType) {
    Geometry.check(expected.length === actual.length, qsTr("The GeoPackage contains an incomplete result."))
    for (let index = 0; index < expected.length; ++index) {
        const before = expected[index]
        const after = actual[index]
        for (const key of Object.keys(before.properties)) {
            const value = before.properties[key]
            const read = after.properties[key]
            const displayed = read && typeof read.toISOString === "function" ? read.toISOString() : String(read ?? "")
            const equal = typeof value === "number" ? Math.abs(value - Number(read)) <= Math.abs(value) * 1e-10
                : String(value ?? "") === displayed
            Geometry.check(equal, qsTr("Reading the GeoPackage changed the %1 attribute.").arg(key))
        }
        Geometry.check(Geometry.same(evaluate, before.wkt, after.wkt, geometryType),
                       qsTr("Reading the GeoPackage changed the geometry."))
    }
}
