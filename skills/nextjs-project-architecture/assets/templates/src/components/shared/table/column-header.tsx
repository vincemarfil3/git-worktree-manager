'use client'
// Standard. Sortable header button. aria-sort is set on the <th> by DataTable.
import { ArrowDown, ArrowUp, ArrowUpDown } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { cn } from '@/lib/utils'

type ColumnHeaderProps = {
  title: string
  /** false | 'asc' | 'desc' from column.getIsSorted() */
  sorted: false | 'asc' | 'desc'
  canSort: boolean
  onToggle?: (event: unknown) => void
  align?: 'start' | 'end'
}

export function ColumnHeader({ title, sorted, canSort, onToggle, align }: ColumnHeaderProps) {
  if (!canSort) return <span className={cn(align === 'end' && 'block text-right')}>{title}</span>
  const Icon = sorted === 'asc' ? ArrowUp : sorted === 'desc' ? ArrowDown : ArrowUpDown
  return (
    <Button variant="ghost" size="sm" onClick={onToggle} className={cn('-ml-3 h-8', align === 'end' && 'ml-auto -mr-3 flex')}>
      {title}
      <Icon className="size-4" aria-hidden="true" />
    </Button>
  )
}
