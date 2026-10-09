'use client'
// Starter. Money stays a STRING in the form (validate with moneyString()); convert in toPayload. Never type="number".
import { useId } from 'react'
import { Controller, type Control, type FieldPath, type FieldValues } from 'react-hook-form'
import { Input } from '@/components/ui/input'
import { FieldShell, fieldIds, type BaseFieldProps } from './field-shell'

type MoneyFieldProps<T extends FieldValues, TOut> = BaseFieldProps & {
  control: Control<T, unknown, TOut>
  name: FieldPath<T>
  /** ISO code shown as a prefix, e.g. "PHP" */
  currency: string
}

export function MoneyField<T extends FieldValues, TOut>({
  control, name, label, description, placeholder = '0.00', disabled, required, hideLabel, className, currency,
}: MoneyFieldProps<T, TOut>) {
  const id = useId()
  return (
    <Controller
      control={control}
      name={name}
      render={({ field, fieldState }) => {
        const error = fieldState.error?.message
        const { describedBy } = fieldIds(id, !!description, !!error)
        return (
          <FieldShell id={id} label={label} description={description} error={error} required={required} hideLabel={hideLabel} className={className}>
            <div className="relative">
              <span aria-hidden="true" className="pointer-events-none absolute inset-y-0 left-3 flex items-center text-sm text-muted-foreground">
                {currency}
              </span>
              <Input
                id={id}
                ref={field.ref}
                name={field.name}
                value={(field.value as string | undefined) ?? ''}
                onChange={field.onChange}
                onBlur={field.onBlur}
                inputMode="decimal"
                autoComplete="off"
                placeholder={placeholder}
                disabled={disabled ?? field.disabled}
                className="pl-14 text-right tabular-nums"
                aria-invalid={!!error}
                aria-describedby={describedBy}
              />
            </div>
          </FieldShell>
        )
      }}
    />
  )
}
