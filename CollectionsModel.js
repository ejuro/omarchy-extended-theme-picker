function slug(image) {
  return String(image.fileName || image.filePath.split('/').pop()).replace(/\.[^.]+$/, '')
}

function label(image) {
  return slug(image).replace(/[-_]+/g, ' ').replace(/\b\w/g, function(c) { return c.toUpperCase() })
}

function groups(images, data, query, currentImage) {
  // User overlays can supply a different preview extension than stock.
  // Keep a theme once, preferring the path the caller marked current.
  var unique = []
  var indices = new Map()
  images.forEach(function(image) {
    var name = slug(image)
    if (!indices.has(name)) {
      indices.set(name, unique.length)
      unique.push(image)
    } else if (image.filePath === currentImage) unique[indices.get(name)] = image
  })
  var stock = data.stock || []
  var stockNames = new Set(stock)
  var definitions = [
    { id: 'favorites', name: 'Favorites', themes: data.favorites || [] },
    { id: 'defaults', name: 'Omarchy defaults', themes: stock },
    { id: 'custom', name: 'Custom', themes: null }
  ].concat(data.collections || [])
  var needle = String(query || '').toLowerCase().trim()
  return definitions.map(function(group) {
    var collectionMatches = group.name.toLowerCase().indexOf(needle) >= 0
    var members = new Set(group.themes || [])
    return { id: group.id, name: group.name, images: unique.filter(function(image) {
      var name = slug(image)
      var member = group.id === 'custom' ? !stockNames.has(name) : members.has(name)
      return member && (!needle || collectionMatches || label(image).toLowerCase().indexOf(needle) >= 0 || name.toLowerCase().indexOf(needle) >= 0)
    }) }
  }).filter(function(group) { return !needle || group.images.length > 0 })
}

function position(images, remembered, current) {
  var index = images.findIndex(function(image) { return slug(image) === remembered })
  if (index < 0) index = images.findIndex(function(image) { return image.filePath === current })
  return Math.max(0, index)
}

function openingSelection(groups, activeSlug, lastCollection) {
  var containing = groups.filter(function(g) { return g.images.some(function(i) { return slug(i) === activeSlug }) })
  var group = containing.find(function(g) { return g.id === 'favorites' })
    || containing.find(function(g) { return g.id === lastCollection })
    || containing.find(function(g) { return g.id === 'custom' || g.id === 'defaults' })
    || containing[0]
  if (!group) group = groups.find(function(g) { return g.id === lastCollection && g.images.length })
    || groups.find(function(g) { return g.images.length }) || groups[0]
  if (!group) return null
  return { group: group.id, image: group.images.find(function(i) { return slug(i) === activeSlug }) || group.images[0] || null }
}

function neighbors(images, selected) {
  // One unique instance of each neighboring theme, wrapping at either end.
  var count = images.length
  if (!count) return []
  var left = Math.min(5, Math.floor((count - 1) / 2))
  var right = Math.min(5, count - 1 - left)
  var result = []
  for (var offset = -left; offset <= right; offset++) {
    var index = (selected + offset + count) % count
    result.push({ image: images[index], index: index, offset: offset })
  }
  return result
}

function toggle(values, value) {
  return values.indexOf(value) >= 0 ? values.filter(function(v) { return v !== value }) : values.concat([value])
}

function gridMove(groups, groupIndex, index, columns, direction) {
  if (!groups.length) return null
  var group = groups[groupIndex]
  var count = group.images.length
  var column = Math.max(0, index) % columns
  var target = index
  var forward = direction === 'right' || direction === 'down'
  if (count) {
    if (direction === 'left') target--
    else if (direction === 'right') target++
    else if (direction === 'up') target -= columns
    else if (Math.floor(index / columns) < Math.floor((count - 1) / columns)) target = Math.min(index + columns, count - 1)
    else target = count
    if (target >= 0 && target < count) return { group: group.id, image: group.images[target] }
  }
  for (var i = groupIndex + (forward ? 1 : -1); i >= 0 && i < groups.length; i += forward ? 1 : -1) {
    var items = groups[i].images
    if (!items.length) continue
    if (direction === 'down') target = Math.min(column, items.length - 1)
    else if (direction === 'up') target = Math.min(Math.floor((items.length - 1) / columns) * columns + column, items.length - 1)
    else target = forward ? 0 : items.length - 1
    return { group: groups[i].id, image: items[target] }
  }
  return count ? { group: group.id, image: group.images[index] } : null
}

function gridSections(groups, columns, cellHeight) {
  var top = 0
  return groups.map(function(group) {
    var height = 40 + Math.max(1, Math.ceil(group.images.length / columns)) * cellHeight
    var section = { id: group.id, name: group.name, images: group.images, top: top, height: height }
    top += height + 32
    return section
  })
}

if (typeof module !== 'undefined') module.exports = { slug, label, groups, position, openingSelection, neighbors, toggle, gridMove, gridSections }
