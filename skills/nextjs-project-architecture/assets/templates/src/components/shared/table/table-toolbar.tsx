'use client'
// Standard. Search (debounced) + filter slot + actions slot.
import { Search } from 'lucide-react'
import { useEffect, useState } from 'react'
import { Input } from '@/components/ui/input'

type TableToolbarProps = {
  search: string
  onSearchChange: (value: string) => void
  searchPlaceholder?: string
  /** Feature filters (selects, date ranges) */
  filters?: React.ReactNode
  /** Primary actions, e.g. "New order" */
  actions?: React.ReactNode
  debounceMs?: number
}

export function TableToolbar({ search, onSearchChange, searchPlaceholder = 'Search…', filters, actions, debounceMs = 300 }: TableToolbarProps) {
  const [value, setValue] = useState(search)

  // Keep the input in sync when the URL changes from outside (back button, clear filters)
  useEffect(() => setValue(search), [search])

  // Debounce so the query key (and the request) changes once, not per keystroke
  useEffect(() => {
    if (value === search) return
    const t = setTimeout(() => onSearchChange(value.trim()), debounceMs)
    return () => clearTimeout(t)
  }, [value, search, onSearchChange, debounceMs])

  return (
    <div className="flex flex-wrap items-center justify-between gap-2">
      <div className="flex flex-1 flex-wrap items-center gap-2">
        <div className="relative w-full max-w-xs">
          <Search className="pointer-events-none absolute left-2.5 top-1/2 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
          <Input type="search" value={value} onChange={(e) => setValue(e.target.value)} placeholder={searchPlaceholder} aria-label={searchPlaceholder} className="pl-8" />
        </div>
        {filters}
      </div>
      {actions && <div className="flex items-center gap-2">{actions}</div>}
    </div>
  )
}
