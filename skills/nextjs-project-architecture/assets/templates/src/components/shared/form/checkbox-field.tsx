'use client'
// Starter. Single boolean checkbox, label beside the box.
import { useId } from 'react'
import { Controller, type Control, type FieldPath, type FieldValues } from 'react-hook-form'
import { Checkbox } from '@/components/ui/checkbox'
import { FieldShell, fieldIds, type BaseFieldProps } from './field-shell'

type CheckboxFieldProps<T extends FieldValues, TOut> = Omit<BaseFieldProps, 'placeholder'> & {
  control: Control<T, unknown, TOut>
  name: FieldPath<T>
}

export function CheckboxField<T extends FieldValues, TOut>({
  control, name, label, description, disabled, required, hideLabel, className,
}: CheckboxFieldProps<T, TOut>) {
  const id = useId()
  return (
    <Controller
      control={control}
      name={name}
      render={({ field, fieldState }) => {
        const error = fieldState.error?.message
        const { describedBy } = fieldIds(id, !!description, !!error)
        return (
          <FieldShell id={id} label={label} description={description} error={error} required={required} hideLabel={hideLabel} className={className} inline>
            <Checkbox
              id={id}
              ref={field.ref}
              name={field.name}
              checked={field.value === true}
              onCheckedChange={(v) => field.onChange(v === true)}
              onBlur={field.onBlur}
              disabled={disabled ?? field.disabled}
              aria-invalid={!!error}
              aria-describedby={describedBy}
            />
          </FieldShell>
        )
      }}
    />
  )
}
