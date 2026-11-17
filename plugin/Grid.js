.pragma library

// Coordinates are [east, north]. Grid indices are measured from a movable anchor.

function create(anchor, hectares, degrees) {
    const size = Math.sqrt(hectares) * 100
    if (!Number.isFinite(size) || size <= 0 || !Number.isFinite(degrees)
            || degrees < 0 || degrees > 180 || !anchor.every(Number.isFinite))
        throw new Error(qsTr("The cell area, angle or grid position is invalid."))
    const radians = degrees * Math.PI / 180
    return { anchor, size, cosine: Math.cos(radians), sine: Math.sin(radians) }
}

function coordinate(grid, column, row) {
    return [grid.anchor[0] + grid.size * (column * grid.cosine - row * grid.sine),
            grid.anchor[1] + grid.size * (column * grid.sine + row * grid.cosine)]
}

function rotateScreenBasis(basis, degrees) {
    const radians = degrees * Math.PI / 180
    const cosine = Math.cos(radians), sine = Math.sin(radians)
    const origin = basis[0]
    const east = { x: basis[1].x - origin.x, y: basis[1].y - origin.y }
    const north = { x: basis[2].x - origin.x, y: basis[2].y - origin.y }
    return [origin,
        { x: origin.x + east.x * cosine + north.x * sine, y: origin.y + east.y * cosine + north.y * sine },
        { x: origin.x - east.x * sine + north.x * cosine, y: origin.y - east.y * sine + north.y * cosine }]
}

// An affine screen approximation is only used between pointer press and release.
function screenLines(basis, bounds, offset) {
    if (bounds.left >= bounds.right || bounds.top >= bounds.bottom)
        return []
    const origin = { x: basis[0].x + offset.x, y: basis[0].y + offset.y }
    const column = { x: basis[1].x - basis[0].x, y: basis[1].y - basis[0].y }
    const row = { x: basis[2].x - basis[0].x, y: basis[2].y - basis[0].y }
    const determinant = column.x * row.y - column.y * row.x
    const columnSpacing = Math.abs(determinant) / Math.hypot(row.x, row.y)
    const rowSpacing = Math.abs(determinant) / Math.hypot(column.x, column.y)
    if (!Number.isFinite(columnSpacing) || !Number.isFinite(rowSpacing) || determinant === 0)
        return []

    let west = Infinity, east = -Infinity, south = Infinity, north = -Infinity
    for (const x of [bounds.left, bounds.right]) {
        for (const y of [bounds.top, bounds.bottom]) {
            const dx = x - origin.x, dy = y - origin.y
            const i = (dx * row.y - dy * row.x) / determinant
            const j = (column.x * dy - column.y * dx) / determinant
            west = Math.min(west, i)
            east = Math.max(east, i)
            south = Math.min(south, j)
            north = Math.max(north, j)
        }
    }

    const lines = []
    function screenPoint(i, j) {
        return { x: origin.x + i * column.x + j * row.x,
                 y: origin.y + i * column.y + j * row.y }
    }
    // Subpixel lines disappear in a zoomed-out view. Keep a stable subset.
    const columnStep = Math.max(1, Math.ceil(2 / columnSpacing))
    const rowStep = Math.max(1, Math.ceil(2 / rowSpacing))
    if (![west, east, south, north, columnStep, rowStep].every(Number.isFinite))
        return []
    for (let i = Math.ceil(west / columnStep); i <= Math.floor(east / columnStep); ++i) {
        if (!Number.isSafeInteger(i))
            break
        lines.push([screenPoint(i * columnStep, south), screenPoint(i * columnStep, north)])
    }
    for (let j = Math.ceil(south / rowStep); j <= Math.floor(north / rowStep); ++j) {
        if (!Number.isSafeInteger(j))
            break
        lines.push([screenPoint(west, j * rowStep), screenPoint(east, j * rowStep)])
    }
    return lines
}

function range(grid, polygons, margin) {
    let west = Infinity, east = -Infinity, south = Infinity, north = -Infinity
    for (const polygon of polygons) {
        for (const [x, y] of polygon[0]) {
            const dx = x - grid.anchor[0], dy = y - grid.anchor[1]
            const column = (dx * grid.cosine + dy * grid.sine) / grid.size
            const row = (-dx * grid.sine + dy * grid.cosine) / grid.size
            west = Math.min(west, column)
            east = Math.max(east, column)
            south = Math.min(south, row)
            north = Math.max(north, row)
        }
    }
    west = Math.floor(west) - margin
    east = Math.ceil(east) + margin
    south = Math.floor(south) - margin
    north = Math.ceil(north) + margin
    const count = (east - west) * (north - south)
    if (![west, east, south, north, count].every(Number.isSafeInteger) || count < 1 || count > 4096)
        throw new Error(qsTr("The grid exceeds 4,096 cells. Increase the cell area."))
    return { west, east, south, north, count }
}

function cell(grid, column, row, project, cache) {
    function edge(x, y, horizontal) {
        const key = [x, y, horizontal].join("/")
        if (!cache.has(key)) {
            const coordinates = []
            const steps = Math.max(2, Math.min(32, Math.ceil(grid.size / 25)))
            for (let i = 0; i <= steps; ++i)
                coordinates.push(project(coordinate(grid, x + (horizontal ? i / steps : 0),
                                                          y + (horizontal ? 0 : i / steps))))
            cache.set(key, coordinates)
        }
        return cache.get(key)
    }
    return edge(column, row, true).slice(0, -1)
        .concat(edge(column + 1, row, false).slice(0, -1),
                edge(column, row + 1, true).slice(1).reverse(),
                edge(column, row, false).slice().reverse())
}

function metricCrs(longitude, latitude) {
    if (!Number.isFinite(longitude) || !Number.isFinite(latitude)
            || Math.abs(longitude) > 180 || Math.abs(latitude) > 90)
        throw new Error(qsTr("Could not select a metric coordinate reference system."))
    if (latitude >= 84)
        return "EPSG:32661"
    if (latitude < -80)
        return "EPSG:32761"
    const zone = Math.min(60, Math.floor((longitude + 180) / 6) + 1)
    return "EPSG:" + ((latitude >= 0 ? 32600 : 32700) + zone)
}

function numberZones(zones, options, occupied, overrides) {
    const ordered = zones.slice().sort((left, right) => {
        const row = right.row - left.row
        const column = left.column - right.column
        const order = options.columns ? column || row : row || column
        return (options.reverse ? -1 : 1) * (order || left.part - right.part)
    })
    const used = new Set(occupied.map(String))
    let next = options.start
    if (options.mode === "continuous")
        for (const value of used)
            if (/^\d+$/.test(value))
                next = Math.max(next, Number(value) + 1)
    if (!Number.isSafeInteger(next) || next < 1 ||
            (options.mode === "prefix" && !options.prefix.trim()))
        throw new Error(qsTr("Enter a positive starting number and a prefix if required."))
    const manual = new Set()
    for (const zone of ordered) {
        const value = overrides[zone.key]
        if (value !== undefined) {
            if (used.has(value) || manual.has(value))
                throw new Error(qsTr("Duplicate zone number: %1").arg(value))
            manual.add(value)
        }
    }
    return ordered.map(zone => {
        const value = overrides[zone.key]
        if (!Number.isSafeInteger(next))
            throw new Error(qsTr("The zone number is outside the supported range."))
        let number = options.mode === "prefix"
            ? options.prefix.trim() + "-" + String(next).padStart(2, "0") : String(next)
        while (manual.has(number) && value === undefined) {
            ++next
            number = options.mode === "prefix"
                ? options.prefix.trim() + "-" + String(next).padStart(2, "0") : String(next)
        }
        if (value === undefined)
            ++next
        else
            number = value
        if (used.has(number))
            throw new Error(qsTr("Duplicate zone number: %1").arg(number))
        used.add(number)
        return Object.assign({}, zone, { number })
    })
}
