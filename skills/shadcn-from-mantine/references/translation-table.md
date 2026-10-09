# Mantine → shadcn translation table

Concept-by-concept lookup. Read `SKILL.md` first for *why* these map this way — this file is the
detail reference once you know which Mantine API you're translating.

Exact class names, token names, and generated file contents can shift between shadcn releases; this
table is about the stable *shape* of the mapping, not a snapshot to trust verbatim against a specific
installed version. Confirm against the project's own files or the shadcn MCP server when precision
matters.

## Setup

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `MantineProvider` wrapping the app | No single wrapping "UI provider." Global CSS file (theme tokens + Tailwind base) does the theme part; an optional, separate theme-toggle provider only tracks light/dark. | Mantine couples "provide the theme" and "the theme" into one object; shadcn splits them. |
| `@mantine/core` import | `components/ui/*` — files already in your repo after the CLI copies them | Not an ongoing import from node_modules for the component's own markup. |

## Theme

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `createTheme({...})` object | The CSS variable block in the global stylesheet (`:root` / `.dark`) | JS object → CSS, is the core shift. |
| `primaryColor: 'blue'` | `--primary` / `--primary-foreground` | |
| `colors: { blue: [10 shades] }` | One semantic token per role, not a 10-shade scale (plus the ordinary Tailwind color palette is still available for non-themed, one-off uses) | |
| `theme.spacing` / `theme.spacing.md` | The Tailwind spacing scale (`p-4`, `gap-2`, …) | |
| `theme.radius` / `defaultRadius` | `--radius` | |
| `theme.fontFamily` / `theme.headings` | Tailwind font config in `tailwind.config` / `@theme`, plus plain HTML elements — no `<Text>`/`<Title>` component by default | You can still add one if you want that ergonomic back. |
| `theme.breakpoints` | Tailwind's breakpoints (`sm:`, `md:`, `lg:`, …) | |

## Styling APIs

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| Style props (`p`, `m`, `c`, `bg`, `w`, `h`, `ta`, …) | Tailwind utility classes (`p-4`, `m-2`, `text-muted-foreground`, `bg-primary`, `w-full`, `h-10`, `text-center`) | |
| Styles API: `classNames={{ root: '...', label: '...' }}` | No inner-slot prop from outside — edit the inner element's classes directly inside the owned file | Because you own the file, the "slot" concept collapses: there's only one place the classes live. |
| Styles API: `styles={{ root: { ... } }}` (inline style objects) | Tailwind classes, or an inline `style` prop only for truly dynamic/computed values | |
| Styles API: `vars={() => ({...})}` (CSS variable overrides per-instance) | A `className` with Tailwind arbitrary-value syntax, or a local CSS variable set via `style` | |
| `sx` prop (Mantine v6, or v7+ with the optional `@mantine/emotion` package) | `className` + `cn()` | Mantine v7 dropped `sx` from core; if the project is on plain v7/v8 without `@mantine/emotion`, there's nothing to migrate away from here at all. |
| Responsive object props: `{ base: 'sm', sm: 'md', lg: 'xl' }` | Breakpoint-prefixed classes: `text-sm sm:text-base lg:text-xl` | |

## Layout

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `<Box>` | A plain element (`div`, `span`, …) with classes | |
| `<Stack gap="md">` | `flex flex-col gap-4` | |
| `<Group gap="sm">` / `<Flex>` | `flex items-center gap-2` | |
| `<Grid>` / `<SimpleGrid cols={3}>` | `grid grid-cols-3 gap-4` | |
| `<Container size="md">` | `container` class / `max-w-*` + `mx-auto` | |
| `<Center>` | `flex items-center justify-center` | |
| `<Space h="md" />` | A margin/gap utility on the adjacent element, or an empty spacer `div` with a height class | No dedicated spacer component by default. |
| `<Divider />` | shadcn's `Separator` primitive | |

## Variants and defaults

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `variant="filled"` / `size="lg"` props | Keys in the component's own `cva()` call | |
| `Component.extend({ defaultProps, classNames, vars })` | Edit the component's file directly | There's no separate "extend" step — you just edit the source. |
| `theme.components.Button.defaultProps` | `defaultVariants` in the `cva()` call, or the base classes themselves | |
| `theme.components.Button.classNames` / `.styles` | Edit the classes inside the file | |

## State styling

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `data-*` mod attributes (Mantine already uses these) | Same idea: Tailwind reads the Radix/Base UI primitive's own `data-*`/`aria-*` attributes as variants (`data-[state=open]:...`, `aria-invalid:...`, `disabled:...`) | This is the one area where Mantine's own model already matches shadcn's — least translation needed. |

## Polymorphism and refs

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `component` prop (render as a different element/component) | `asChild` (Radix-based components, via Radix `Slot`) or a `render` prop (Base UI–based components) | Check the component file's own imports to see which primitive layer it uses. |

## Dark mode

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `MantineProvider` + `useMantineColorScheme()` | A `.dark` class toggle on `<html>`, plus a small hook/provider that only flips the class and remembers the choice | The provider holds no colors either way — Mantine's theme object supplies them in both cases; shadcn's CSS variables do. |
| `ColorSchemeScript` (prevents flash of wrong theme) | Script embedded in the root layout/HTML that sets the class before paint | Same problem, same style of fix. |

## Responsive helpers

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `useMediaQuery('(max-width: 768px)')` | Prefer a Tailwind breakpoint class (`hidden md:block`) over JS when the result is purely visual | Reach for a JS media-query hook only when actual logic (not just display) depends on it. |
| `hiddenFrom` / `visibleFrom` props | `hidden md:block` / `block md:hidden` | |

## Ecosystem (no bundled equivalent)

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `@mantine/form` | No bundled form package — ask the MCP server what the project already uses (commonly React Hook Form + Zod) | Conceptual only; don't guess the specific library. |
| `@mantine/dates` | No bundled date-picker package — a separate date-picker library composed into a shadcn component | |
| `@mantine/notifications` | No bundled toast package — a separate toast library (commonly Sonner) composed into a shadcn component | |
| Modals manager | No bundled modal-manager — compose Dialog/AlertDialog primitives directly per use case | |

## Icons

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `@tabler/icons-react` | `lucide-react` — the default, not just "commonly used" | shadcn's own docs, generated blocks, and nearly every registry component assume `lucide-react` is already installed; `npx shadcn init` wires it up by default. Tabler still works (same `size-4` Tailwind sizing, same SVG-component shape), but every block copied from the registry would need its icon imports swapped first. Keep Tabler only if there's existing Tabler-based code not worth touching; default to Lucide otherwise. |

## Upgrades

| Mantine | shadcn/Tailwind equivalent | Note |
|---|---|---|
| `npm update @mantine/core` | No automatic update path — re-pull a component via the CLI/MCP server and diff it against your edited copy when you want newer upstream code | This is the direct consequence of the ownership model in `SKILL.md` §4. |
