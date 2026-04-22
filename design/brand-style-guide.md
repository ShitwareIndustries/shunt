# shunt — Product Brand Style Guide

> Product-specific brand guidelines for **shunt**, the LLM load balancer by Shitware Industries.
> Extends the company brand guidelines from [BAN-44](/BAN/issues/BAN-44) and [BAN-18](/BAN/issues/BAN-18).

## 1. Brand Positioning

**shunt** is an LLM load balancer that routes requests to the model instance with the hottest KV cache. It saves money and cuts latency by reusing what other solutions throw away.

**Product identity**: A tool you run, not a product you buy. Terminal-native. Code-first. Zero fluff.

**Tagline**: "Ship it. We dare you."

**License**: AGPL v3

---

## 2. Visual Identity

### 2.1 Relationship to Parent Brand

shunt inherits the Shitware Industries design system (colors, typography, spacing, components) with these product-specific adaptations:

| Element | Parent Brand | shunt Override |
|---------|-------------|----------------|
| Primary accent | Crimson Red `#dc143c` | Same — Crimson Red is the core accent |
| Secondary accent | Gold `#ffd700` | Used for cache-hit metrics and savings percentages |
| Product wordmark | Company wordmark | `$ shunt` terminal command lockup |
| Hero style | Various | Terminal demo aesthetic is mandatory |
| Motion | Minimal | Typing animation in terminal; respects `prefers-reduced-motion` |

### 2.2 Product Wordmark

**Primary lockup**: `$ shunt`

- `$` in Silver `#c0c0c0`, JetBrains Mono 700
- `shunt` in Snow White `#f8f8f8`, JetBrains Mono 700
- Subtitle: "LLM load balancer" in Inter 400, Silver `#c0c0c0`

**Variants**:

| Variant | Format | Use Case |
|---------|--------|----------|
| Dark bg (primary) | SVG | Landing page, GitHub README, presentations |
| Light bg | SVG | Documentation, print, light themes |
| Monochrome | SVG | Watermarks, single-color contexts |
| Favicon | SVG + PNG | Browser tab, PWA icon (`>` prompt in Crimson on Basalt) |

### 2.3 Iconography

shunt uses **Lucide** icons (open source, MIT). Product-specific icon choices:

| Concept | Icon | Style |
|---------|------|-------|
| Cache reuse / recycling | `refresh-cw` | 24px, Crimson Red |
| OpenAI compatibility | `plug` | 24px, Crimson Red |
| Built in Zig | `zap` | 24px, Crimson Red |
| Cost savings | `trending-down` | 24px, Crimson Red |
| Low latency | `timer` | 24px, Crimson Red |
| Open source | `scale` | 24px, Crimson Red |
| Routing / shunting | `git-branch` | 24px, Crimson Red |
| Dashboard | `layout-dashboard` | 24px, Crimson Red |

Icon rules:
- Always 24px at standard scale
- Crimson Red on dark backgrounds, Basalt Black on light backgrounds
- No filled variants — outline/line only
- No decorative icons without a label

---

## 3. Color Usage for shunt

### 3.1 Product-Specific Color Roles

| Role | Token | Hex | Usage |
|------|-------|-----|-------|
| Cache hit indicator | `--color-gold` | `#ffd700` | Cache hit percentages, savings metrics |
| Route arrow | `--color-crimson` | `#dc143c` | The `→` in terminal output, routing indicators |
| Success / delivered | `--color-success` | `#22c55e` | ✓ Response delivered, healthy nodes |
| Terminal background | `--color-void` | `#0d0d0d` | Code blocks, terminal windows |
| Terminal frame | `--color-obsidian` | `#2a2a2a` | Terminal title bar |
| Metric highlight | `--color-gold` | `#ffd700` | Savings %, latency numbers |

### 3.2 Dashboard Color Map

| Dashboard Element | Color | Rationale |
|-------------------|-------|-----------|
| Healthy node | `#22c55e` (green) | Standard status indicator |
| Degraded node | `#ffd700` (gold) | Warning — partial cache |
| Offline node | `#dc143c` (crimson) | Error / unavailable |
| Active route line | `#dc143c` (crimson) | Brand accent, draws the eye |
| Cache bar fill | `#ffd700` (gold) | Cache = gold = value |
| Latency sparkline | `#c0c0c0` (silver) | Subtle, not competing with accent |
| Request counter | `#f8f8f8` (snow) | Primary data, maximum contrast |

---

## 4. Typography for shunt

### 4.1 Product-Specific Type Usage

| Context | Font | Size | Weight | Color |
|---------|------|------|--------|-------|
| Product wordmark | JetBrains Mono | 18px | 700 | Silver (`$`) + Snow White (`shunt`) |
| Terminal prompt | JetBrains Mono | 15px | 400 | Silver |
| Terminal arrows (`→`) | JetBrains Mono | 15px | 400 | Crimson Red |
| Terminal percentages | JetBrains Mono | 15px | 400 | Gold |
| Terminal success (`✓`) | JetBrains Mono | 15px | 400 | Green |
| Hero headline | Inter | 48px | 900 | Snow White |
| Hero subhead | Inter | 18px | 400 | Silver |
| Feature title | Inter | 20px | 700 | Snow White |
| Feature body | Inter | 16px | 400 | Fog |
| Code badge | JetBrains Mono | 13px | 400 | Cloud |

### 4.2 Code Blocks and Terminal Windows

All terminal/demo windows follow this visual structure:

```
┌─ terminal ───────────────────────────────┐
│ ● ● ●                     [_] [□] [×]   │  ← Obsidian title bar, 32px height
├───────────────────────────────────────────┤
│                                           │
│  $ shunt --model gpt-4o                   │  ← Void background
│                                           │
│  → Routing to node-3 (cache hit 94%)     │  ← Mono 15px
│                                           │
└───────────────────────────────────────────┘
```

- Border: 1px Graphite `#3a3a3a`
- Border radius: 8px
- Title bar: Obsidian `#2a2a2a`, three dots at 12px left offset
  - Red dot: `#dc143c` 8px circle
  - Yellow dot: `#ffd700` 8px circle
  - Green dot: `#22c55e` 8px circle
- Body background: Void `#0d0d0d`
- Body padding: 24px
- No horizontal scrollbar — wrap long lines

---

## 5. Landing Page Structure

### 5.1 Sections (top to bottom)

1. **Header** — sticky nav with `$ shunt` logo, nav links, CTA
2. **Hero** — product name, tagline, two CTA buttons
3. **Terminal Demo** — animated terminal showing shunt in action
4. **Features Grid** — 3-column grid of key features
5. **How It Works** — 3-step flow with numbered steps
6. **Metrics / Social Proof** — key stats in large type
7. **Code Example** — installation and config snippets
8. **Footer** — links, license, company attribution

### 5.2 Responsive Breakpoints

| Breakpoint | Width | Columns | Notes |
|------------|-------|---------|-------|
| Mobile | <768px | 1 | Stacked layout, full-width buttons, hamburger nav |
| Tablet | 768–1023px | 2 | 2-column feature grid, wider terminal |
| Desktop | ≥1024px | 3 | Full layout, max-width 1200px container |

### 5.3 Animation and Motion

- Terminal typing: character-by-character at 30ms intervals
- Must respect `prefers-reduced-motion: reduce` — skip to final state
- No scroll-jacking, no parallax, no auto-playing video
- Hover transitions: 150ms cubic-bezier(0.4, 0, 0.2, 1)
- No animations on text content — only the terminal demo

---

## 6. Component Patterns

### 6.1 Buttons

| Type | Style | Usage |
|------|-------|-------|
| **Primary CTA** | Crimson Red fill, Snow White text, Inter 600 16px, 12px 24px padding, 8px radius | "Install shunt →", main actions |
| **Secondary** | Transparent bg, 1px Graphite border, Silver text, Inter 500 16px | "Read the docs", cancel actions |
| **Code copy** | Graphite bg, Snow White text, JetBrains Mono 12px | Copy-to-clipboard buttons |

### 6.2 Cards

- Background: Obsidian `#2a2a2a`
- Border: 1px Graphite `#3a3a3a`
- Border radius: 8px
- Padding: 24px
- Hover: no transform, subtle border color shift to Silver (no elevation change)

### 6.3 Badges / Tags

| Type | Style |
|------|-------|
| Version | JetBrains Mono 12px, Graphite bg, Cloud text |
| License | JetBrains Mono 12px, Graphite bg, Cloud text |
| Status | JetBrains Mono 12px, colored bg (green/gold/crimson), Snow text |

---

## 7. Dashboard Mockup Specification

### 7.1 Layout

```
┌──────────────────────────────────────────────────────────┐
│  $ shunt dashboard                          [Docs] [⚙]  │
├──────────┬───────────────────────────────────────────────┤
│          │                                               │
│  NODES   │  ┌─ Request Flow ──────────────────────────┐  │
│          │  │                                         │  │
│  ● n-1   │  │  Client → [shunt] → node-3 (94% cache) │  │
│  ● n-2   │  │                                         │  │
│  ● n-3 ◉ │  └─────────────────────────────────────────┘  │
│  ○ n-4   │                                               │
│          │  ┌─ Cache Stats ──────┐ ┌─ Latency ────────┐  │
│          │  │ Hits: 94.2%       │ │ Avg: 47ms        │  │
│          │  │ Misses: 5.8%      │ │ P99: 89ms        │  │
│          │  │ Saved: $2,847/mo  │ │ Cold: 312ms      │  │
│          │  └───────────────────┘ └──────────────────┘  │
│          │                                               │
├──────────┴───────────────────────────────────────────────┤
│  Recent Requests                                         │
│  ┌───────────────────────────────────────────────────┐   │
│  │ GET /v1/chat/completions  → node-3  47ms  200 OK │   │
│  │ GET /v1/chat/completions  → node-1  62ms  200 OK │   │
│  │ GET /v1/chat/completions  → node-3  43ms  200 OK │   │
│  └───────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────┘
```

### 7.2 Dashboard Elements

| Element | Type | Specs |
|---------|------|-------|
| Node list | Sidebar | 200px wide, Obsidian bg, node status dots |
| Active node indicator | Filled dot | Gold `#ffd700` for active, Green for healthy, Crimson for offline, Graphite for idle |
| Request flow panel | Card | Shows routing path with Crimson arrows |
| Cache stats | 2-column cards | Gold for hit %, Snow for labels |
| Latency | 2-column card | Silver for ms values, Gold for savings |
| Request log | Table | JetBrains Mono 13px, alternating row bg (Void/Obsidian) |

---

## 8. Accessibility

- All text must meet WCAG 2.1 AA contrast ratios
- Snow White on Basalt Black: 17.4:1 (AAA)
- Crimson Red on Basalt Black: 5.9:1 (AA large text only)
- Crimson Red on Snow White: 4.1:1 (fails AA for small text — use Basalt Black text instead)
- Gold on Basalt Black: 14.7:1 (AAA)
- Silver on Basalt Black: 10.3:1 (AAA)
- Focus indicators: 2px Crimson outline with 2px offset
- `prefers-reduced-motion` must disable all animations
- All interactive elements must be keyboard-navigable
- Terminal demo must have a text alternative (aria-label describing the content)
- SVG icons must have `aria-hidden="true"` when decorative, or `role="img"` + `aria-label` when meaningful

---

## 9. File Manifest

| File | Purpose |
|------|---------|
| `/root/shunt/design/brand-style-guide.md` | This document |
| `/root/shunt/design/logo.svg` | Product logo and wordmark |
| `/root/shunt/design/landing/index.html` | Landing page markup |
| `/root/shunt/design/landing/style.css` | Landing page styles |
| `/root/shunt/design/dashboard-mockup.html` | Dashboard screenshot placeholder |

---

## 10. Design Principles (Product-Specific)

1. **Terminal is the brand** — every visual element should feel like it belongs in a developer's workflow
2. **Show, don't tell** — the terminal demo does more than any feature list
3. **Dark mode is the default** — light mode is a graceful fallback, not a co-equal
4. **Metrics over marketing** — "$2,847/mo saved" beats "cost-effective"
5. **One accent color** — Crimson Red is the only color that should pop. Gold for data, green for status, silver for structure
6. **No illustration, no decoration** — if it doesn't convey information, it doesn't belong
7. **CLI authenticity** — the `$ shunt` wordmark is a command, not a logo. Treat it that way
