// Standard. Loading / error / empty rows. Distinguish "no data yet" (offer create) from "no results" (offer clear filters).
import { Button } from '@/components/ui/button'
import { Skeleton } from '@/components/ui/skeleton'
import { TableCell, TableRow } from '@/components/ui/table'

export function SkeletonRows({ rows, columns }: { rows: number; columns: number }) {
  return (
    <>
      {Array.from({ length: rows }, (_, r) => (
        <TableRow key={r} aria-hidden="true">
          {Array.from({ length: columns }, (_, c) => (
            <TableCell key={c}>
              <Skeleton className="h-4 w-full" />
            </TableCell>
          ))}
        </TableRow>
      ))}
    </>
  )
}

export function ErrorRow({ columns, onRetry }: { columns: number; onRetry?: () => void }) {
  return (
    <TableRow>
      <TableCell colSpan={columns} className="h-32 text-center">
        <div className="flex flex-col items-center gap-2">
          <p className="text-sm text-muted-foreground">Could not load data.</p>
          {onRetry && (
            <Button variant="outline" size="sm" onClick={onRetry}>
              Try again
            </Button>
          )}
        </div>
      </TableCell>
    </TableRow>
  )
}

export type EmptyState = { message: string; action?: React.ReactNode }

export function EmptyRow({ columns, empty }: { columns: number; empty: EmptyState }) {
  return (
    <TableRow>
      <TableCell colSpan={columns} className="h-32 text-center">
        <div className="flex flex-col items-center gap-2">
          <p className="text-sm text-muted-foreground">{empty.message}</p>
          {empty.action}
        </div>
      </TableCell>
    </TableRow>
  )
}
