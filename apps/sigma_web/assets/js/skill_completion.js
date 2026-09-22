export function filterSkillCandidates(candidates, value) {
  if (!Array.isArray(candidates) || typeof value !== 'string' || !value.startsWith('/skill ')) return []

  const query = value.slice('/skill '.length).split(/\s/, 1)[0].toLowerCase()

  return candidates.filter((candidate) => {
    if (candidate?.kind !== 'skill') return false
    const searchable = [candidate.name, candidate.description, candidate.source, candidate.reference]
      .filter((item) => typeof item === 'string')
      .join(' ')
      .toLowerCase()
    return searchable.includes(query)
  })
}

export function insertSkillCandidate(value, candidate) {
  const reference = candidate?.reference
  if (typeof value !== 'string' || typeof reference !== 'string' || !value.startsWith('/skill ')) return value

  const remainder = value.slice('/skill '.length)
  const separator = remainder.search(/\s/)
  const argumentsSuffix = separator < 0 ? ' ' : remainder.slice(separator)
  return `/skill ${reference}${argumentsSuffix}`
}

export function searchableRemoteSources(sources) {
  if (!Array.isArray(sources)) return []

  return sources.filter((source) => {
    return source?.status === 'configured' && (source.enabled ?? source['enabled?']) !== false
  })
}
