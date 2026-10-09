// Starter. useForm + zodResolver + app defaults. Input and output types are inferred from the schema,
// so transforms (e.g. '' -> undefined, "12" -> 12) are typed correctly in onSubmit.
import { zodResolver } from '@hookform/resolvers/zod'
import { useForm, type DefaultValues, type FieldValues, type UseFormProps } from 'react-hook-form'
import type { z } from 'zod'

export function useAppForm<TIn extends FieldValues, TOut extends FieldValues>(
  schema: z.ZodType<TOut, TIn>,
  // REQUIRED: RHF needs it for reset/dirty tracking, and mapServerErrors uses it to know which fields exist
  defaultValues: DefaultValues<TIn>,
  options?: Omit<UseFormProps<TIn, unknown, TOut>, 'resolver' | 'defaultValues'>,
) {
  return useForm<TIn, unknown, TOut>({
    resolver: zodResolver(schema),
    defaultValues,
    mode: 'onTouched',
    ...options,
  })
}
