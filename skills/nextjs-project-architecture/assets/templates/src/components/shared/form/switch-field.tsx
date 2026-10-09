'use client'
// Starter. On/off setting that applies immediately in meaning (e.g. "Send receipt email").
import { useId } from 'react'
import { Controller, type Control, type FieldPath, type FieldValues } from 'react-hook-form'
import { Switch } from '@/components/ui/switch'
import { FieldShell, fieldIds, type BaseFieldProps } from './field-shell'

type SwitchFieldProps<T extends FieldValues, TOut> = Omit<BaseFieldProps, 'placeholder'> & {
  control: Control<T, unknown, TOut>
  name: FieldPath<T>
}

export function SwitchField<T extends FieldValues, TOut>({
  control, name, label, description, disabled, required, hideLabel, className,
}: SwitchFieldProps<T, TOut>) {
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
            <Switch
              id={id}
              ref={field.ref}
              name={field.name}
              checked={field.value === true}
              onCheckedChange={field.onChange}
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
