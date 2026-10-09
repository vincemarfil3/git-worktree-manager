'use client'
// Starter. Text-like inputs: text, email, password, tel, url, search.
// For numbers typed by users, use type="text" + inputMode (never type="number") and a Zod helper (intFromText).
import { useId } from 'react'
import { Controller, type Control, type FieldPath, type FieldValues } from 'react-hook-form'
import { Input } from '@/components/ui/input'
import { FieldShell, fieldIds, type BaseFieldProps } from './field-shell'

type TextFieldProps<T extends FieldValues, TOut> = BaseFieldProps & {
  control: Control<T, unknown, TOut>
  name: FieldPath<T>
  type?: 'text' | 'email' | 'password' | 'tel' | 'url' | 'search'
  inputMode?: React.HTMLAttributes<HTMLInputElement>['inputMode']
  autoComplete?: string
  maxLength?: number
}

export function TextField<T extends FieldValues, TOut>({
  control, name, label, description, placeholder, disabled, required, hideLabel, className,
  type = 'text', inputMode, autoComplete, maxLength,
}: TextFieldProps<T, TOut>) {
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
            <Input
              id={id}
              ref={field.ref} // required so focus-first-invalid-field works
              name={field.name}
              value={(field.value as string | undefined) ?? ''}
              onChange={field.onChange}
              onBlur={field.onBlur}
              type={type}
              inputMode={inputMode}
              autoComplete={autoComplete}
              maxLength={maxLength}
              placeholder={placeholder}
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
