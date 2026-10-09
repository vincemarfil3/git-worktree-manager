'use client'
// Starter. Multi-line text.
import { useId } from 'react'
import { Controller, type Control, type FieldPath, type FieldValues } from 'react-hook-form'
import { Textarea } from '@/components/ui/textarea'
import { FieldShell, fieldIds, type BaseFieldProps } from './field-shell'

type TextareaFieldProps<T extends FieldValues, TOut> = BaseFieldProps & {
  control: Control<T, unknown, TOut>
  name: FieldPath<T>
  rows?: number
  maxLength?: number
}

export function TextareaField<T extends FieldValues, TOut>({
  control, name, label, description, placeholder, disabled, required, hideLabel, className, rows = 4, maxLength,
}: TextareaFieldProps<T, TOut>) {
  const id = useId()
  return (
    <Controller
      control={control}
      name={name}
      render={({ field, fieldState }) => {
        const error = fieldState.error?.message
        const { describedBy } = fieldIds(id, !!description, !!error)
        const value = (field.value as string | undefined) ?? ''
        return (
          <FieldShell id={id} label={label} description={description} error={error} required={required} hideLabel={hideLabel} className={className}>
            <Textarea
              id={id}
              ref={field.ref}
              name={field.name}
              value={value}
              onChange={field.onChange}
              onBlur={field.onBlur}
              rows={rows}
              maxLength={maxLength}
              placeholder={placeholder}
              disabled={disabled ?? field.disabled}
              aria-invalid={!!error}
              aria-describedby={describedBy}
            />
            {maxLength && (
              <p className="text-right text-xs text-muted-foreground tabular-nums">
                {value.length}/{maxLength}
              </p>
            )}
          </FieldShell>
        )
      }}
    />
  )
}
