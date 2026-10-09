# Forms — React Hook Form + Zod

Use this stack for multi-field, dynamic, or heavily validated forms. For one or two fields with a Server Action, `<form action>` + `useActionState` is lighter (see `decisions.md` section 5). Starter: build the shared components below on demand; Standard: expected home for all form logic.

Goal: feature forms are just `<Form>` plus shared fields. No `useForm` wiring, error rendering, or submit-state logic in features.

## Files — `components/shared/form/`

Shipped in `assets/templates/src/components/shared/form/` (usage: `GUIDE.md` section 5): `form.tsx`, `use-app-form.ts`, `field-shell.tsx`, `text-field`, `money-field`, `textarea-field`, `select-field`, `checkbox-field`, `switch-field`, `submit-button`, `form-error`, `form-layout` (FormSection, FormGrid), `map-server-errors.ts`, `index.ts`. Zod helpers in `lib/validation.ts`.

Not shipped yet, build on demand by copying `text-field.tsx`: `combobox-field` (Popover + Command), `radio-group-field`, `date-field`, `otp-field`, `rich-text/`.

Fields use `FieldShell` (Label + description + error + aria wiring) instead of shadcn's newer `Field` primitives, so they do not depend on a specific shadcn release.

## Typing: `useAppForm` + `control`

TypeScript cannot infer form types from React context, so:
- `useAppForm(schema, defaultValues)` wraps `useForm` + `zodResolver` + app defaults (`mode: 'onTouched'`). Input and output types are inferred from `z.ZodType<Out, In>`, so `onSubmit` receives transformed values (e.g. `''` -> `undefined`). `defaultValues` is required.
- Feature passes the result to `<Form form={form} onSubmit={...}>` (provider, submit handling, root error).
- Fields receive `control={form.control}`; `name` is typed as a path of the form values → typos are compile errors.

## Field contract

Base props: `control`, `name`, `label`, `description`, `placeholder`, `disabled`, `required` (display-only asterisk; the rule lives in Zod), `hideLabel` (sr-only), `className` (layout only).

Every field:
- Wraps RHF `Controller`, renders inside shadcn `Field` primitives (label, control, description, error).
- **Forwards `field.ref` to the real input** — required for focus-first-invalid-field.
- Calls `field.onBlur` for touched state.
- Stable id via `useId`; `aria-describedby` → description + error; `aria-invalid` when errored.
- Shows only the first error message.

## shadcn primitive mapping

| Field | Primitive |
|---|---|
| text | Input |
| textarea | Textarea |
| number / money | Input with `inputMode="decimal"` — never `type="number"` |
| select (short list) | Select |
| combobox (long/searchable) | Popover + Command |
| checkbox / switch / radio | Checkbox / Switch / RadioGroup |
| date (+ range variant) | Popover + Calendar |
| otp | InputOTP |
| rich text | Tiptap + Toggle, Tooltip, Separator, Popover |
| submit | Button + spinner |
| root error | Alert |

## Form values vs API payload

- `features/<name>/schemas.ts`: hand-written Zod; output type must satisfy the generated request type so backend changes break compilation.
- `features/<name>/mappers.ts`: `toPayload(values)` typed against the generated request type.
- Money: string in the form, validated by a shared `moneyString(currency)` Zod helper (decimal, max decimals per currency); converted in `toPayload`.
- Dates: `Date` in form → ISO string (timestamps) or `YYYY-MM-DD` (date-only) in payload.
- Optional inputs: normalize `''` → `undefined` in the schema.
- Global Zod error map for default messages.

## Submit lifecycle

- `onSubmit` awaits `mutation.mutateAsync(toPayload(values))` so `isSubmitting` covers the whole request → submit button auto-disables (prevents double charges).
- Success: `form.reset(savedValues)` so dirty state is accurate; invalidate queries in the mutation.
- Optional unsaved-changes warning when `isDirty` on long forms.

## Server error mapping — `map-server-errors.ts`

Input: normalized `ApiError`. Options (passed as `<Form serverErrors={...}>`): `fieldMap` (API path -> form path, e.g. `customer_name` -> `customerName`), `codeToField`, `fallbackMessage`. A field error is applied only if its top-level name exists in `defaultValues`; otherwise it goes to the root error.
- FastAPI-style 422 (see `backends.md` for other error shapes; adapt `extractFieldErrors`): each `detail[]` item has `loc` like `["body", "items", 0, "qty"]` → drop `"body"` → `items.0.qty` → `setError(path, { message })`. Unknown paths → root error.
- Business errors (409 etc.): map known error codes to specific fields; else root error.
- 5xx/unknown → root error with generic message. Never silently dropped.
- Focus the first errored field.

## Layout

Fields do no layout. `FormSection` (title + description) and `FormGrid` (responsive columns) handle it.

## Rich text — Tiptap

Files `components/shared/form/rich-text/`: `rich-text-field.tsx` (RHF adapter), `rich-text-editor.tsx` (pure value/onChange, reusable outside forms), `toolbar.tsx`, `toolbar-presets.ts`, `extensions.ts`; plus `components/shared/rich-text-viewer.tsx`.

- Presets: minimal (bold, italic, lists, link), standard (+ headings, blockquote, undo/redo), full (+ tables, images — only on real need). Each preset loads only its extensions.
- `immediatelyRender: false`; load via `next/dynamic`.
- Empty editor emits `''` (check `editor.isEmpty`), not `<p></p>` — keeps Zod simple.
- Set content on external value changes (reset/load) only when it differs from current content (prevents cursor jumps).
- `disabled` → `editor.setEditable(false)`.
- Stored format: HTML (consistent with backend). Links: block `javascript:`, render `rel="noopener noreferrer"`. Strip pasted styles.
- Character count extension when `maxLength` is set.
- Sanitize HTML server-side before saving (BFF or FastAPI with `nh3`) and again when rendering in the viewer. CSP is a second layer.
- Styling: `prose dark:prose-invert`, shared by editor and viewer.
- A11y: toolbar buttons `aria-label` + `aria-pressed`; editable area `aria-labelledby` + `aria-invalid`.
