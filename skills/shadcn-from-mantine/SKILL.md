---
name: shadcn-from-mantine
description: Bridges a Mantine developer's existing mental model to shadcn/ui - components are copied into your repo as editable source instead of installed from npm; styling is Tailwind classes, CSS-variable theme tokens and class-variance-authority variants instead of a theme object, style props, or the Styles API (classNames/styles/vars); behavior comes from Radix UI or Base UI primitives; dark mode is a .dark class swapping CSS variables, not a MantineProvider palette. Use whenever someone with Mantine experience works with shadcn/ui for the first time, asks where shadcn's theme object, MantineProvider, Box, Stack, Group, Component.extend, or the Styles API went, wants the shadcn equivalent of a Mantine component or prop, is migrating from Mantine to shadcn, or asks how theming or customizing a shadcn component works. Not for shadcn CLI commands, components.json, registries or adding components (use the shadcn MCP server), and not for Mantine-only work or MUI/other component libraries.
---

# shadcn/ui, for a Mantine developer

You know Mantine. shadcn/ui is not a different component library of the same kind — it's a different
*kind* of thing. This skill explains the concepts; it never teaches CLI syntax (see "Mechanics" below).

Every explanation here is anchored as: **"In Mantine you'd X. In shadcn, you Y."** Assume the reader
already understands components, props, variants, theming and accessibility — only the Mantine-specific
vocabulary needs translating, not the underlying ideas.

## 1. How to use this skill

- Anchor every answer in the Mantine equivalent the user already knows, then show the shadcn version.
- **The source of truth is the user's own files**, not recollection of shadcn's upstream code. Once a
  component is added, it lives in their repo (usually `components/ui/<name>.tsx`) as plain, editable
  TypeScript + Tailwind. Open that file — and the project's global CSS file holding the theme tokens —
  before explaining how a specific component behaves or is styled. What you say about shadcn "in
  general" may not match what's actually sitting in their repo after they've customized it.
- Don't write shadcn-101 content for a blank slate. The reader doesn't need components or theming
  explained from first principles — just where the Mantine idea they already have went.
- Keep answers short: one concept, one mapping, one small code fragment. Point to
  `references/translation-table.md` for anything not worth inlining.

## 2. Mechanics: use the shadcn MCP server — never guess

Everything about *installing or adding* components, browsing the registry, CLI flags, the
`components.json` shape, blocks, or Tailwind setup is **mechanics**, not a concept, and mechanics is
exactly what goes stale fastest. This skill does not teach it.

- **Check first**: if shadcn MCP tools are available in the session, use them for anything
  install/registry/CLI-shaped.
- **If they're not set up yet**, the one-time setup command is:
  ```
  npx shadcn@latest mcp init --client claude
  ```
  (Claude Code needs a restart, or `/mcp`, to see the new server afterward.)
- **If the user doesn't want to set it up**, read shadcn's current docs at ui.shadcn.com rather than
  recalling CLI details from training — they change between releases.
- **Hard rule**: never invent a CLI flag, a `components.json` key, or a component prop from memory.
  Verify it, every time.
- A separate shadcn mechanics skill (vendor- or community-maintained) may also be installed in this
  session. Defer to it for anything mechanical; this skill stays in its lane.

## 3. The big shifts, at a glance

| Concern | Mantine | shadcn |
|---|---|---|
| Distribution | `npm install @mantine/core` — an external package | CLI copies a `.tsx` file into your own repo — you own it |
| Styling | Theme object + Styles API (`classNames`/`styles`/`vars`) or CSS Modules | Tailwind utility classes |
| Theme tokens | JS object passed to `MantineProvider` | CSS custom properties in `:root` / `.dark` |
| Variants | A fixed `variant`/`size` set, extended via `Component.extend()` or `theme.components` | A `cva()` call *in the file*, which you edit directly |
| Behavior / a11y | Built into `@mantine/core` | Radix UI or Base UI primitives underneath (still real npm deps) |
| Upgrades | `npm update` | No automatic update — you re-pull and diff a component when you want newer upstream code |

## 4. Ownership model

Adding a shadcn component doesn't add a dependency — it writes an actual `.tsx` file into your repo
(by convention, `components/ui/<name>.tsx`). From that moment it's **your code**: committed, reviewed,
and editable like anything else you wrote.

What's still a real npm dependency: the primitive layer (Radix UI or Base UI), `class-variance-authority`
(`cva`), `tailwind-merge`, `clsx`, and whichever icon package the project uses. Everything else — the
actual markup, class names, and composition — is yours.

The implication, coming from Mantine: there's no "library internals" to work around, no specificity
fights, no waiting on upstream for a fix. The trade is that you also don't get free bug fixes via
`npm update` — a component you've copied stays exactly as you left it until you deliberately re-sync it.

**Never edit anything under `node_modules`.** You *do* edit `components/ui/`.

## 5. Styling model

Tailwind utility classes replace Mantine's style props and Styles API:

- Mantine style props (`p="md"`, `mt="sm"`, `c="dimmed"`, `bg="blue.5"`, `w={200}`) → Tailwind classes
  (`p-4`, `mt-2`, `text-muted-foreground`, `bg-blue-500`, `w-[200px]`).
- Mantine's responsive object props (`{ base: 'sm', sm: 'md' }`) → Tailwind breakpoint prefixes
  (`sm:text-base md:text-lg`).
- Mantine's Styles API (`classNames`, `styles`, `vars` on a component) → there are no inner-slot props
  to pass from outside anymore. Since you own the file, you edit the inner element's classes directly
  inside it.
- `cn()` (defined once in `lib/utils.ts`, = `clsx` + `tailwind-merge`) is the closest thing to Mantine's
  own `className` merge behavior: it lets a `className` passed at the call site override a default
  class without creating a specificity conflict.
- **State styling**: Mantine exposes state through `data-*` mod attributes (you already know this
  idea). shadcn's Radix/Base UI primitives emit the same kind of attributes (`data-state="open"`,
  `aria-invalid="true"`, a native `disabled` attribute), and Tailwind reads them directly as variants:
  `data-[state=open]:bg-accent`, `aria-invalid:border-destructive`, `disabled:opacity-50`.
- **No runtime CSS-in-JS.** If you're already on Mantine v7+'s CSS Modules, this isn't a new idea —
  just a different utility-class syntax for the same "no runtime style computation" goal.

## 6. Variants with `cva`

The shape (not meant to be copied verbatim — open the real file in the project):

```ts
const buttonVariants = cva(
  'inline-flex items-center justify-center rounded-md text-sm font-medium transition-colors',
  {
    variants: {
      variant: { default: 'bg-primary text-primary-foreground', outline: 'border border-input' },
      size: { default: 'h-9 px-4', sm: 'h-8 px-3' },
    },
    defaultVariants: { variant: 'default', size: 'default' },
  },
)
```

Mapping: Mantine's `variant`/`size` props plus a `Component.extend()` or `theme.components` override
both become **adding a key to the `cva` map inside the component's own file.** `VariantProps<typeof
buttonVariants>` gives you the typed prop automatically — no separate type to maintain.

## 7. Behavior layer (Radix UI / Base UI)

A shadcn component is a styled wrapper around a Radix UI or Base UI primitive, which supplies focus
management, keyboard handling, and ARIA wiring — the part Mantine handled invisibly inside its own
components. The difference is you can actually see the wrapper, since it's in your repo.

**Polymorphism**: Mantine's `component` prop (render as a different element/component) maps to
`asChild` (Radix-based components, using Radix's `Slot`) or a `render` prop (Base UI–based components).
Which one a given component uses is visible from its own imports at the top of the file.

## 8. Theming and dark mode

Tokens are semantic CSS custom properties — `--background`, `--foreground`, `--primary`,
`--primary-foreground`, `--muted`, `--border`, `--ring`, `--radius`, and similar — defined once in
`:root` and redefined in `.dark`. Tailwind classes like `bg-primary text-primary-foreground` just read
whichever value is currently active.

- Mantine's 10-shade `colors` arrays plus `primaryColor` both collapse down to **one semantic
  CSS-variable pair per role** (`--primary` / `--primary-foreground`), not a shade scale — shadcn's
  default palette is semantic-role-first, not swatch-first.
- **Dark mode is a class toggle, not a provider with its own palette.** A `.dark` class on `<html>`
  swaps which variable values apply; whatever "theme provider" exists in the app only flips that class
  and remembers the choice — it holds no colors itself. This is the direct equivalent of Mantine's
  `MantineProvider` + `useMantineColorScheme`.
- **Rule**: use token classes (`bg-background`, `text-muted-foreground`), never a raw palette class
  like `bg-white` or `text-gray-900` — that bypasses theming entirely, the same way hardcoding a hex
  value instead of reading `theme.colors` would in Mantine. A new brand color needs a variable added in
  *both* `:root` and `.dark`.
- The exact Tailwind `@theme`/config wiring for tokens is mechanics — see §2, the MCP server, or the
  project's own `globals.css`.

## 9. Customizing a component: a decision ladder

1. **One-off**: pass `className` at the call site (the same move as Mantine's own `className` prop).
2. **A new reusable look**: add a `cva` variant inside the file (instead of `Component.extend()`,
   `theme.components`, or a Styles API override).
3. **Change the default everywhere**: edit the base classes or `defaultVariants` in the file (instead
   of `defaultProps` in the Mantine theme).
4. **A domain-specific component**: wrap the primitive in your *own* component, kept outside
   `components/ui/`, so a later re-pull of the upstream file stays a clean diff.

Heavier edits directly inside `components/ui/` make a future re-sync harder to diff — prefer steps 1–2
for small adjustments and step 4 once something is genuinely app-specific, rather than piling
customization onto the owned file indefinitely.

## 10. What isn't in the box

Mantine bundles a lot for free: hooks (`@mantine/hooks`), forms (`@mantine/form`), dates
(`@mantine/dates`), notifications, and a modals manager, all as part of the same ecosystem.

shadcn ships **none of these as packages.** Its components are compositions that wrap *separate*
libraries underneath (a table library, a date-picker library, a toast library, a form library) rather
than bundling equivalents itself. There's no single "shadcn forms" or "shadcn dates" package to reach
for — ask the MCP server (§2) what the project already has, or what the current recommended pairing is,
rather than assuming an equivalent exists.

## 11. Common traps for a Mantine developer

- Hunting for a `theme.components` override slot that simply doesn't exist — the override *is* editing
  the file.
- Passing Mantine-style `classNames`/`styles`/style props to a shadcn component, expecting them to work.
- Being reluctant to edit files under `components/ui/` — that hesitation doesn't apply here; it's your
  code.
- Hardcoding a color instead of using a token class.
- Expecting `npm update` to change anything about an already-copied component.
- Treating `variant` as a closed set defined somewhere upstream — it's just the keys in that file's
  own `cva` call, and you can add one.
- Looking for a `Stack`/`Group`/`Grid`/`SimpleGrid` component. There isn't one — use
  `flex flex-col gap-4`, `flex items-center gap-2`, and `grid grid-cols-*` directly.
- Reaching for Mantine's styling system "temporarily" during a migration, and never actually finishing
  the move to Tailwind.

## 12. Related skill

If `nextjs-project-architecture` is also installed and this project follows it, its own
`references/ui-and-formatting.md` defines *that* project's concrete shadcn layering (`components/ui/`
vs `components/shared/`), token conventions, and `next-themes` wiring — follow it for those specifics.
This skill only covers the underlying concepts and doesn't depend on that one being present.

## 13. Accuracy note

The concepts above are stable across shadcn releases. Exact class names, generated file contents, and
token names can still shift between releases — confirm against the project's own files, or through the
MCP server (§2), rather than trusting a remembered specific.
