'use client'
// Standard. "…" menu at the end of a row. Destructive actions ask for confirmation first.
import { MoreHorizontal } from 'lucide-react'
import { useState } from 'react'
import { Button } from '@/components/ui/button'
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from '@/components/ui/dropdown-menu'
import { ConfirmDialog } from './confirm-dialog'

export type RowAction = {
  label: string
  onSelect: () => void | Promise<unknown>
  destructive?: boolean
  /** Shown in the confirm dialog for destructive actions */
  confirm?: { title: string; description?: string; confirmLabel?: string }
  disabled?: boolean
}

export function RowActions({ actions, label = 'Row actions' }: { actions: RowAction[]; label?: string }) {
  const [pending, setPending] = useState<RowAction | null>(null)

  return (
    <>
      <DropdownMenu>
        <DropdownMenuTrigger asChild>
          <Button variant="ghost" size="icon" aria-label={label}>
            <MoreHorizontal className="size-4" aria-hidden="true" />
          </Button>
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end">
          {actions.map((a) => (
            <DropdownMenuItem
              key={a.label}
              disabled={a.disabled}
              variant={a.destructive ? 'destructive' : 'default'}
              onSelect={() => (a.destructive || a.confirm ? setPending(a) : void a.onSelect())}
            >
              {a.label}
            </DropdownMenuItem>
          ))}
        </DropdownMenuContent>
      </DropdownMenu>

      <ConfirmDialog
        open={pending !== null}
        onOpenChange={(open) => !open && setPending(null)}
        title={pending?.confirm?.title ?? `${pending?.label ?? 'Continue'}?`}
        description={pending?.confirm?.description ?? 'This action cannot be undone.'}
        confirmLabel={pending?.confirm?.confirmLabel ?? pending?.label ?? 'Confirm'}
        destructive={pending?.destructive}
        onConfirm={async () => {
          await pending?.onSelect()
          setPending(null)
        }}
      />
    </>
  )
}
