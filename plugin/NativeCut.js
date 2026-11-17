.pragma library

function cut(api, state, operation) {
    operation.before = api.nearby(operation.original).map(part => part.id)
    state.pendingCut = operation
    api.persist(state)

    try {
        api.edit(() => api.add(operation))
        operation.parts = addedParts(api, operation)
        api.check(operation.parts.length === operation.pieces.length,
                  qsTr("The layer did not save all new zones."))
        api.check(api.same(api.read(operation.fieldId), operation.original),
                  qsTr("The selected field geometry has changed."))
        api.edit(() => api.change(operation.fieldId, operation.retained))
        api.check(api.same(api.read(operation.fieldId), operation.retained),
                  qsTr("The layer did not save the geometry of the original field feature."))
        finishCut(api, state, operation)
    } catch (error) {
        if (settleCut(api, state))
            return
        throw error
    }
}

function addedParts(api, operation) {
    const existing = new Set(operation.before)
    const parts = api.nearby(operation.original).filter(part => !existing.has(part.id))
    const expected = new Set(operation.pieces)
    const seen = new Set()
    const matches = []
    for (const part of parts) {
        const wkt = expected.has(part.wkt) ? part.wkt :
            operation.pieces.find(piece => api.same(part, piece))
        if (!wkt)
            continue
        api.check(!seen.has(wkt), qsTr("The layer contains duplicate zones. Review them before trying again."))
        seen.add(wkt)
        matches.push(part)
    }
    return matches
}

function finishCut(api, state, operation) {
    delete operation.before
    delete operation.pieces
    delete state.pendingCut
    state.operations.push(operation)
    api.persist(state)
}

function settleCut(api, state) {
    const operation = state.pendingCut
    if (!operation)
        return false
    const parts = addedParts(api, operation)
    const original = api.read(operation.fieldId)
    if (api.same(original, operation.retained) && parts.length === operation.pieces.length) {
        operation.parts = parts
        finishCut(api, state, operation)
        return true
    }
    api.check(api.same(original, operation.original),
              qsTr("The field changed during the split. Review the layer before trying again."))
    if (parts.length) {
        api.edit(() => api.remove(parts))
        api.check(!addedParts(api, operation).length,
                  qsTr("The layer did not remove the unfinished split."))
    }
    delete state.pendingCut
    api.persist(state)
    return false
}

function undo(api, state, operation) {
    const original = api.read(operation.fieldId)
    const recovering = state.pendingUndo === operation.id
    const restored = recovering && api.same(original, operation.original)
    api.check(restored || api.same(original, operation.retained),
              qsTr("The original feature has changed since the split."))
    const remaining = []
    for (const part of operation.parts) {
        const current = api.read(part.id)
        if (restored && !current)
            continue
        api.check(api.same(current, part.wkt) && current.attributes === part.attributes,
                  qsTr("The zones have changed since the split."))
        remaining.push(part)
    }
    state.pendingUndo = operation.id
    api.persist(state)
    if (!restored) {
        api.edit(() => api.change(operation.fieldId, operation.original))
        api.check(api.same(api.read(operation.fieldId), operation.original),
                  qsTr("The layer did not restore the field boundary."))
    }
    if (remaining.length) {
        api.edit(() => api.remove(remaining))
        api.check(remaining.every(part => !api.read(part.id)),
                  qsTr("The layer did not remove all zones."))
    }
    operation.undone = true
    delete state.pendingUndo
    api.persist(state)
}
