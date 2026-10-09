'use client'
// Starter. Short option lists (under ~15). For long/searchable lists build a ComboboxField (Popover + Command).
import { useId } from 'react'
import { Controller, type Control, type FieldPath, type FieldValues } from 'react-hook-form'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { FieldShell, fieldIds, type BaseFieldProps } from './field-shell'

export type SelectOption = { value: string; label: string }

type SelectFieldProps<T extends FieldValues, TOut> = BaseFieldProps & {
  control: Control<T, unknown, TOut>
  name: FieldPath<T>
  options: readonly SelectOption[]
}

export function SelectField<T extends FieldValues, TOut>({
  control, name, label, description, placeholder = 'Select…', disabled, required, hideLabel, className, options,
}: SelectFieldProps<T, TOut>) {
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
            <Select
              name={field.name}
              value={(field.value as string | undefined) ?? ''}
              onValueChange={field.onChange}
              onOpenChange={(open) => !open && field.onBlur()}
              disabled={disabled ?? field.disabled}
            >
              <SelectTrigger id={id} ref={field.ref} aria-invalid={!!error} aria-describedby={describedBy} className="w-full">
                <SelectValue placeholder={placeholder} />
              </SelectTrigger>
              <SelectContent>
                {options.map((o) => (
                  <SelectItem key={o.value} value={o.value}>
                    {o.label}
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </FieldShell>
        )
      }}
    />
  )
}
