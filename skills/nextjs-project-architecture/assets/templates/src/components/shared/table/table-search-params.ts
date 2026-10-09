// Standard. URL params for any server-mode table: page, pageSize, sort, search.
// Pure module (no 'use client'): page.tsx uses it with createLoader, the client leaf with useTableUrlState.
// Same parsers on both sides -> same query key -> hydrated cache hit on first paint.
// Invalid values from hand-edited URLs fall back to defaults, so they never reach the backend.
import { createParser, parseAsString } from 'nuqs/server'

type Options<TCol extends string> = {
  /** Columns the BACKEND can sort by. Anything else in the URL is ignored. */
  sortable: readonly TCol[]
  defaultSort: `${TCol}:${'asc' | 'desc'}`
  defaultPageSize?: number
  pageSizes?: readonly number[]
}

export function createTableSearchParams<TCol extends string>({
  sortable, defaultSort, defaultPageSize = 20, pageSizes = [10, 20, 50, 100],
}: Options<TCol>) {
  const allowedSorts = new Set<string>(sortable.flatMap((c) => [`${c}:asc`, `${c}:desc`]))

  return {
    page: createParser<number>({
      parse: (v) => {
        const n = Number(v)
        return Number.isInteger(n) && n >= 1 ? n : null
      },
      serialize: String,
    }).withDefault(1),
    pageSize: createParser<number>({
      parse: (v) => (pageSizes.includes(Number(v)) ? Number(v) : null),
      serialize: String,
    }).withDefault(defaultPageSize),
    sort: createParser<string>({
      parse: (v) => (allowedSorts.has(v) ? v : null),
      serialize: (v) => v,
    }).withDefault(defaultSort),
    search: parseAsString.withDefault(''),
  }
}

export type TableSearchParams = ReturnType<typeof createTableSearchParams>

/** "created_at:desc" -> [{ id: "created_at", desc: true }] */
export function sortToSorting(sort: string) {
  const [id, dir] = sort.split(':')
  return id ? [{ id, desc: dir === 'desc' }] : []
}
