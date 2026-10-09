import { createLoader } from 'nuqs/server'
import { describe, expect, it } from 'vitest'
import { createTableSearchParams, sortToSorting } from './table-search-params'

const params = createTableSearchParams({ sortable: ['created_at', 'total'], defaultSort: 'created_at:desc' })
const load = createLoader(params)

describe('createTableSearchParams', () => {
  it('reads valid params', () => {
    expect(load({ page: '3', pageSize: '50', sort: 'total:asc', search: 'ana' })).toEqual({ page: 3, pageSize: 50, sort: 'total:asc', search: 'ana' })
  })

  it('falls back to defaults for hand-edited or malicious URLs', () => {
    expect(load({ page: '-2', pageSize: '37', sort: 'password:asc' })).toEqual({ page: 1, pageSize: 20, sort: 'created_at:desc', search: '' })
    expect(load({ page: 'abc', sort: 'total:sideways' })).toMatchObject({ page: 1, sort: 'created_at:desc' })
  })

  it('returns the same object shape the client hook uses (shared query key)', () => {
    expect(Object.keys(load({})).sort()).toEqual(['page', 'pageSize', 'search', 'sort'])
  })
})

describe('sortToSorting', () => {
  it('converts the URL value to TanStack Table sorting state', () => {
    expect(sortToSorting('total:desc')).toEqual([{ id: 'total', desc: true }])
    expect(sortToSorting('created_at:asc')).toEqual([{ id: 'created_at', desc: false }])
  })
})
