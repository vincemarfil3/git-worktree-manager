// Starter. Label + control + description + error, with the ids and aria wiring every field needs.
// Fields do no layout; FormGrid/FormSection handle it.
import { Label } from '@/components/ui/label'
import { cn } from '@/lib/utils'

export type BaseFieldProps = {
  label: string
  description?: string
  placeholder?: string
  disabled?: boolean
  /** Display-only asterisk; the actual rule lives in the Zod schema */
  required?: boolean
  /** Visually hide the label (still read by screen readers) */
  hideLabel?: boolean
  /** Layout only (e.g. col-span-2) */
  className?: string
}

export function fieldIds(id: string, hasDescription: boolean, hasError: boolean) {
  const descriptionId = `${id}-description`
  const errorId = `${id}-error`
  const describedBy = [hasDescription && descriptionId, hasError && errorId].filter(Boolean).join(' ') || undefined
  return { descriptionId, errorId, describedBy }
}

type FieldShellProps = {
  id: string
  label: string
  description?: string
  error?: string
  required?: boolean
  hideLabel?: boolean
  className?: string
  /** Checkbox/switch render the label beside the control */
  inline?: boolean
  children: React.ReactNode
}

export function FieldShell({ id, label, description, error, required, hideLabel, className, inline, children }: FieldShellProps) {
  const { descriptionId, errorId } = fieldIds(id, !!description, !!error)
  const labelEl = (
    <Label htmlFor={id} className={cn(hideLabel && 'sr-only')}>
      {label}
      {required && <span aria-hidden="true" className="text-destructive"> *</span>}
    </Label>
  )

  return (
    <div className={cn('grid gap-2', className)} data-invalid={error ? true : undefined}>
      {inline ? (
        <div className="flex items-center gap-2">
          {children}
          {labelEl}
        </div>
      ) : (
        <>
          {labelEl}
          {children}
        </>
      )}
      {description && (
        <p id={descriptionId} className="text-sm text-muted-foreground">
          {description}
        </p>
      )}
      {error && (
        <p id={errorId} role="alert" className="text-sm text-destructive">
          {error}
        </p>
      )}
    </div>
  )
}
