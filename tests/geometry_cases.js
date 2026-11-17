const run = (expression, values) => bridge.evaluate(expression, values)
function assert(condition, message) {
    if (!condition)
        throw new Error(message)
}
function throws(fn, message) {
    try { fn() } catch (_) { return }
    throw new Error(message)
}
function transform(wkt, source, target) {
    return source === target ? wkt : Geometry.value(run,
        "geom_to_wkt(transform(geom_from_wkt(@a),@s,@d),17)", { a: wkt, s: source, d: target })
}
function rect(x, y, w, h) {
    return [[x,y], [x+w,y], [x+w,y+h], [x,y+h], [x,y]]
}
function split(fixture, angle, ha, src, metric) {
    const interior = Geometry.pointOnSurface(run, fixture)
    const anchor = Geometry.pointFromWkt(transform(Geometry.pointWkt(interior), src, metric))
    const grid = Grid.create([anchor[0]+17, anchor[1]+19], ha, angle)
    const timer = Date.now()
    const job = Geometry.createSplit(run, fixture, Geometry.polygons(transform(fixture, src, metric)), grid,
        point => Geometry.pointFromWkt(transform(Geometry.pointWkt(point), metric, src)),
        wkt => transform(wkt, src, metric))
    while (job.step()) {}
    const validator = job.validator()
    while (validator.step()) {}
    const elapsed = Date.now() - timer
    return { zones: job.zones, elapsed }
}
const src = "EPSG:32634", x = 500000, y = 5700000
const rectangle = Geometry.polygonWkt([rect(x,y,500,200)])
const triangle = Geometry.polygonWkt([[[x,y],[x+500,y],[x+200,y+220],[x,y]]])
const trapezium = Geometry.polygonWkt([[[x,y],[x+500,y],[x+420,y+220],[x+80,y+220],[x,y]]])
const concave = Geometry.polygonWkt([[[x,y],[x+500,y],[x+500,y+300],[x+260,y+300],[x+260,y+180],[x,y+180],[x,y]]])
const hole = Geometry.polygonWkt([rect(x,y,500,300),rect(x+150,y+70,180,120)])
const outer = Geometry.polygonWkt([rect(x,y,400,400),rect(x+100,y+100,180,100)])
const multi = "MULTIPOLYGON(" + outer.slice(7) + "," +
    Geometry.polygonWkt([rect(x+700,y+300,140,120)]).slice(7) + ")"
const narrow = Geometry.polygonWkt([[[x,y],[x+420,y],[x+420,y+0.0625],[x+100,y+0.0625],[x+100,y+150],[x,y+150],[x,y]]])
const circle = []
for (let i = 0; i < 1000; ++i)
    circle.push([x + 160 * Math.cos(i * 2 * Math.PI / 1000), y + 160 * Math.sin(i * 2 * Math.PI / 1000)])
circle.push(circle[0])
const detailed = Geometry.polygonWkt([circle])
assert(Geometry.polygons(multi).map(p => p.length).join(",") === "2,1", "multipolygon parsing")
assert(Geometry.polygons("GEOMETRYCOLLECTION(" + rectangle + ",POINT(1 2))").length === 1, "collection parsing")
const cases = [
    ...[0,15,27,45,90,135,180].map(angle => [rectangle,angle,1]),
    ...[0.25,0.5,2,3,5,1.25].map(size => [rectangle,27,size]),
    ...[triangle,trapezium,concave,hole,multi,narrow,detailed].map(shape => [shape,27,1]),
    [Geometry.polygonWkt([rect(x,y,100,80)]),15,0.25],
    [transform(hole, src, "EPSG:4326"),27,1,"EPSG:4326",src],
    [transform(multi, src, "EPSG:2180"),45,1,"EPSG:2180",src],
    [Geometry.polygonWkt([rect(310000,6240000,500,200)]),27,1,"EPSG:32756","EPSG:32756"],
    ...[50,100,500,1000].map(count => [Geometry.polygonWkt([rect(x,y,1000,count*10)]),0,1])
]
const reports = []
let maxElapsed = 0
let maxZones = 0
let preview
let largePreview
for (let i = 0; i < cases.length; ++i) {
    const [shape, angle, size] = cases[i]
    const source = cases[i][3] || src
    const target = cases[i][4] || src
    try {
        const result = split(shape, angle, size, source, target)
        preview = i === 2 ? result.zones : preview
        largePreview = i === cases.length - 1 ? result.zones : largePreview
        maxElapsed = Math.max(maxElapsed, result.elapsed)
        maxZones = Math.max(maxZones, result.zones.length)
        if (i >= cases.length - 4)
            reports.push([result.zones.length, result.elapsed])
    } catch (error) {
        throw new Error("Fixture " + i + ": " + error.message)
    }
}
const field = {id:"1", layerId:"fields", name:"Test field"}
const options = { mode:"field", start:1, prefix:"", columns:false, reverse:false }
const numbered = Grid.numberZones(preview, options, [], {})
assert(numbered[0].number === "1", "first number")
assert(Grid.numberZones(preview, Object.assign({}, options, { mode:"continuous" }), ["20","34"], {})[0].number === "35", "continuous")
assert(Grid.numberZones(preview, Object.assign({}, options, { mode:"prefix", prefix:"12", start:7 }), [], {})[0].number === "12-07", "prefix")
assert(Grid.numberZones(preview, Object.assign({}, options, { reverse:true }), [], {})[0].key === numbered[numbered.length-1].key, "reverse")
assert(Grid.numberZones(preview, Object.assign({}, options, { columns:true }), [], {})[0].column === Math.min(...preview.map(z=>z.column)), "columns")
assert(Grid.numberZones(preview, options, [], {[numbered[0].key]:"7"})[0].number === "7", "manual")
throws(() => Grid.numberZones(preview, options, ["1"], {}), "number conflict accepted")
throws(() => split("POLYGON((0 0,5 5,0 5,5 0,0 0))", 27, 1, src, src), "invalid polygon accepted")
throws(() => Grid.create([x,y],0,0), "invalid grid size accepted")
assert(Grid.metricCrs(151,-33) === "EPSG:32756" && Grid.metricCrs(15,85) === "EPSG:32661", "UTM/UPS")
const samples = Output.build(run, numbered, Geometry.uuid(run), field, true)
for (const [features, type] of [[samples.zones,"Polygon"], [samples.samples,"Point"]]) {
    const records = JSON.parse(bridge.roundtrip(Output.geoJson(features), src))
    assert(!records.error, String(records.error))
    Output.verify(run, features, records, type)
    throws(() => Output.verify(run, features, records.slice(1), type), "truncated output accepted")
}
const largeNumbered = Grid.numberZones(largePreview, options, [], {})
for (const count of [10, 100, 500]) {
    const records = Output.build(run, largeNumbered.slice(0, count), Geometry.uuid(run), field, false)
    const saved = JSON.parse(bridge.roundtrip(Output.geoJson(records.zones), src))
    assert(!saved.error, String(saved.error))
    Output.verify(run, records.zones, saved, "Polygon")
}
const screenBounds = { left: 0, top: 0, right: 80, bottom: 80 }
const screenBasis = [{x:0,y:0}, {x:20,y:0}, {x:0,y:20}]
const dragLines = Grid.screenLines(screenBasis, screenBounds, {x:7,y:5})
assert(dragLines.length === 8 && dragLines[0][0].x === 7 && dragLines[4][0].y === 5,
    "screen grid follows drag offset in both directions")
const skewed = Grid.screenLines([{x:0,y:0},{x:20,y:10},{x:5,y:-20}], screenBounds, {x:-17,y:35})
assert(skewed.length > 0 && skewed.every(line => line.every(p => Number.isFinite(p.x) && Number.isFinite(p.y))),
    "rotated and skewed screen grid")
const dense = Grid.screenLines([{x:0,y:0},{x:0.001,y:0},{x:0,y:0.001}], screenBounds, {x:0,y:0})
assert(dense.length <= 82, "screen preview skips subpixel lines")
var mapSettings = { destinationCrs: { authid: "EPSG:3857" } }
var QfGeometryUtils = { point: (x, y) => [x, y] }
let batchCalls = 0
var root = { reprojectWkt: (wkt, from, to) => { ++batchCalls; return transform(wkt, from, to) } }
const originalRings = [[[x,y],[x+100,y]], [[x,y],[x,y+100],[x+40,y+100]]]
const projectedRings = mapRings(originalRings, src)
assert(batchCalls === 1 && projectedRings[0].length === 2 && projectedRings[1].length === 3,
    "map paths are reprojected once and preserve path structure")
for (let i = 0; i < originalRings.length; ++i) {
    for (let j = 0; j < originalRings[i].length; ++j) {
        const expected = Geometry.pointFromWkt(transform(Geometry.pointWkt(originalRings[i][j]), src, "EPSG:3857"))
        assert(projectedRings[i][j].every((value, axis) => Math.abs(value - expected[axis]) < 1e-8),
            "batch projection agrees with individual points")
    }
}
assert(mapRings([], src).length === 0 && batchCalls === 1, "no empty projection")
"PASS: " + cases.length + " geometry cases; up to " + maxZones + " zones in " + maxElapsed +
    " ms; large splits (zones/ms): " + JSON.stringify(reports) +
    "; numbering, UUIDs, points and GeoPackage reads (10/100/500 zones); incomplete and unwritable outputs rejected."
