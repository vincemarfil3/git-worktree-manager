'use client'
// Standard. Page info, page-size select, prev/next. Works on 1-based pages for humans.
import { ChevronLeft, ChevronRight } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'

type TablePaginationProps = {
  pageIndex: number // 0-based
  pageSize: number
  rowCount: number
  onPageChange: (pageIndex: number) => void
  onPageSizeChange: (pageSize: number) => void
  pageSizeOptions?: number[]
  selectedCount?: number
}

export function TablePagination({
  pageIndex, pageSize, rowCount, onPageChange, onPageSizeChange, pageSizeOptions = [10, 20, 50, 100], selectedCount,
}: TablePaginationProps) {
  const pageCount = Math.max(1, Math.ceil(rowCount / pageSize))
  const from = rowCount === 0 ? 0 : pageIndex * pageSize + 1
  const to = Math.min(rowCount, (pageIndex + 1) * pageSize)

  return (
    <div className="flex flex-wrap items-center justify-between gap-4 px-2 text-sm">
      <p className="text-muted-foreground tabular-nums">
        {selectedCount ? `${selectedCount} selected · ` : ''}
        {from}–{to} of {rowCount}
      </p>
      <div className="flex items-center gap-4">
        <div className="flex items-center gap-2">
          <span className="text-muted-foreground">Rows</span>
          <Select value={String(pageSize)} onValueChange={(v) => onPageSizeChange(Number(v))}>
            <SelectTrigger size="sm" className="w-20" aria-label="Rows per page">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {pageSizeOptions.map((s) => (
                <SelectItem key={s} value={String(s)}>
                  {s}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <span className="tabular-nums">
          Page {pageIndex + 1} of {pageCount}
        </span>
        <div className="flex gap-1">
          <Button variant="outline" size="icon" onClick={() => onPageChange(pageIndex - 1)} disabled={pageIndex <= 0} aria-label="Previous page">
            <ChevronLeft className="size-4" aria-hidden="true" />
          </Button>
          <Button variant="outline" size="icon" onClick={() => onPageChange(pageIndex + 1)} disabled={pageIndex + 1 >= pageCount} aria-label="Next page">
            <ChevronRight className="size-4" aria-hidden="true" />
          </Button>
        </div>
      </div>
    </div>
  )
}
