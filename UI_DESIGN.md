# UI/UX Design Overview

## Application Visual Structure

```
┌─────────────────────────────────────────────────────────────┐
│ ☰  Connections              🔍  🔔  👤                       │ ← Toolbar
├─────────────────────────────────────────────────────────────┤
│         │                                                    │
│ 📊 Dash │  ┌──────────────────────────────────────────┐    │
│ 👥 Peop │  │                                          │    │
│ 📍 Plac │  │           MAIN CONTENT AREA              │    │
│ 📅 Even │  │                                          │    │
│ 📦 Thin │  │         (Dashboard, Lists, Details)       │    │
│ ⏱️ Time │  │                                          │    │
│ 🔗 Rela │  │                                          │    │
│ 🤝 Shar │  │                                          │    │
│         │  └──────────────────────────────────────────┘    │
│ Sidebar │                                                    │
│ 250px   │              Content Area                         │
└─────────────────────────────────────────────────────────────┘
```

---

## Screen-by-Screen Breakdown

### 1. Dashboard View

```
┌─────────────────────────────────────────────────────────────┐
│  Dashboard                                                   │
│                                                              │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐      │
│  │ 👥       │ │ 📍       │ │ 📅       │ │ 📦       │      │
│  │ People   │ │ Places   │ │ Events   │ │ Things   │      │
│  │    0     │ │    0     │ │    0     │ │    0     │      │
│  └──────────┘ └──────────┘ └──────────┘ └──────────┘      │
│                                                              │
│  Quick Actions                                               │
│  ┌────────────────────────────────────────────────────┐    │
│  │ [+ Add Person] [+ Add Event] [+ Add Place]         │    │
│  │ [+ Add Thing]                                       │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  Recent Activity                                             │
│  ┌────────────────────────────────────────────────────┐    │
│  │  No recent activity.                                │    │
│  │  Start by adding some people or events!            │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

**Features:**
- 4 stat cards (clickable to navigate)
- Color-coded (green, blue, orange, purple)
- Hover effects (lift up, shadow)
- Quick action buttons with icons
- Empty state for recent activity

---

### 2. People List View

```
┌─────────────────────────────────────────────────────────────┐
│  People                                    [+ Add Person]    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │ 🔍 Search people                                    │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │ NAME              │ DESCRIPTION      │ ACTIONS      │    │
│  ├───────────────────┼──────────────────┼──────────────┤    │
│  │ 👤 John Doe       │ Software Dev     │ 👁️ ✏️ 🗑️     │    │
│  │ 👤 Jane Smith     │ Teacher          │ 👁️ ✏️ 🗑️     │    │
│  │ 👤 Bob Johnson    │ Farmer           │ 👁️ ✏️ 🗑️     │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

**OR if empty:**

```
┌─────────────────────────────────────────────────────────────┐
│  People                                    [+ Add Person]    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │ 🔍 Search people                                    │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │                                                      │    │
│  │                    👥 (large icon)                   │    │
│  │                                                      │    │
│  │                  No people found                     │    │
│  │                                                      │    │
│  │             [Add Your First Person]                  │    │
│  │                                                      │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

**Features:**
- Search bar with icon
- Material table
- Person icon for each row
- Action buttons (view, edit, delete)
- Hover effect on rows
- Empty state with CTA

---

### 3. Person Detail View (Future - Plan)

```
┌─────────────────────────────────────────────────────────────┐
│  ← Back to People                           [Save] [Delete]  │
│                                                              │
│  John Doe                                                    │
│  ┌─ Basic Info ─┬─ Relationships ─┬─ Events ─┬─ Docs ─┐   │
│  │                                                       │   │
│  │  📷 Photo                                            │   │
│  │  ┌────────┐                                          │   │
│  │  │        │   Name: John Doe                         │   │
│  │  │  [📷]  │   Born: Jan 1, 1980                      │   │
│  │  │        │   Place: New York, USA                   │   │
│  │  └────────┘   Gender: Male                           │   │
│  │                                                       │   │
│  │  📝 Attributes                                        │   │
│  │  ─────────────────────────────────────────           │   │
│  │  Occupation: Software Developer                      │   │
│  │  Email: john@example.com                             │   │
│  │  Phone: +1 555-0100                                  │   │
│  │                                                       │   │
│  │  [+ Add Field]                                        │   │
│  │                                                       │   │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

**Features:**
- Breadcrumb navigation
- Tab navigation
- Photo upload
- Inline editing (click to edit)
- Expandable sections
- Quick add fields

---

### 4. Timeline View (Future - Plan)

```
┌─────────────────────────────────────────────────────────────┐
│  Timeline                                                    │
│                                                              │
│  🔍 Filter: [All] [People] [Events] [Places]               │
│     Date Range: [1900] ───────────────── [2024]            │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │                                                      │    │
│  │  1980 ●─────────────────────────────────────        │    │
│  │       │ John Doe born in New York                   │    │
│  │       │                                              │    │
│  │  1985 ●                                              │    │
│  │       │ Started school at PS 123                    │    │
│  │       │                                              │    │
│  │  2000 ●─────────────────────────────────────        │    │
│  │       │ Graduated from NYU                          │    │
│  │       │                                              │    │
│  │  2024 ●                                              │    │
│  │       │ Current                                      │    │
│  │                                                      │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

**Features:**
- Interactive timeline
- Event markers
- Filter controls
- Date range slider
- Zoom and pan
- Click to view details

---

### 5. Family Tree View (Future - Plan)

```
┌─────────────────────────────────────────────────────────────┐
│  Family Tree - John Doe                                      │
│                                                              │
│  Controls: [+] [-] [Expand All] [Collapse] [Center]         │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │                                                      │    │
│  │              Grandpa Joe ♂    Grandma Sue ♀         │    │
│  │                    └──────┬──────┘                   │    │
│  │                           │                          │    │
│  │              Dad Mike ♂ ──┴── Mom Lisa ♀            │    │
│  │                    └──────┬──────┘                   │    │
│  │                           │                          │    │
│  │                   ┌───────┼───────┐                 │    │
│  │                   │       │       │                 │    │
│  │              John ♂   Jane ♀  Jack ♂               │    │
│  │                                                      │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

**Features:**
- Hierarchical tree layout
- Gender indicators
- Relationship lines
- Zoom controls
- Click to expand/collapse
- Drag to pan

---

### 6. Relationship Graph View (Future - Plan)

```
┌─────────────────────────────────────────────────────────────┐
│  Relationships                                               │
│                                                              │
│  Center: [John Doe ▼]  Depth: [2 ▼]  Type: [All ▼]         │
│                                                              │
│  ┌────────────────────────────────────────────────────┐    │
│  │                                                      │    │
│  │            ○ Jane (Spouse)                          │    │
│  │           /                                          │    │
│  │          /                                           │    │
│  │    ● John Doe                                        │    │
│  │          \                                           │    │
│  │           \                                          │    │
│  │            ○ Mike (Father)                           │    │
│  │             \                                        │    │
│  │              ○ Lisa (Mother)                         │    │
│  │                                                      │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  Legend:                                                     │
│  ─── Family   ─ ─ Work   ··· Social                        │
└─────────────────────────────────────────────────────────────┘
```

**Features:**
- Force-directed graph
- Color-coded relationship types
- Adjustable depth
- Interactive nodes
- Legend
- Drag to rearrange

---

### 7. Share Management View (Future - Plan)

```
┌─────────────────────────────────────────────────────────────┐
│  Share & Collaborate                        [+ New Invitation]│
│                                                              │
│  Sent Invitations                                            │
│  ┌────────────────────────────────────────────────────┐    │
│  │ To: alice@example.com                              │    │
│  │ Entities: 5 people, 3 places                       │    │
│  │ Status: ⏳ Pending         [Resend] [Cancel]       │    │
│  ├────────────────────────────────────────────────────┤    │
│  │ To: bob@example.com                                │    │
│  │ Entities: 10 people, 2 events                      │    │
│  │ Status: ✓ Accepted                                 │    │
│  └────────────────────────────────────────────────────┘    │
│                                                              │
│  Received Invitations                                        │
│  ┌────────────────────────────────────────────────────┐    │
│  │ From: carol@example.com                            │    │
│  │ Entities: 8 people, 5 places, 3 events             │    │
│  │ Status: ⏳ Pending         [Accept] [Reject]       │    │
│  └────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

**Features:**
- Invitation list
- Status indicators
- Entity counts
- Action buttons
- Two-way view (sent/received)

---

## Color Palette

### Primary Colors
- **Primary (Toolbar, Buttons):** Indigo (#3F51B5)
- **Accent:** Pink (#E91E63)
- **Warn (Delete, Errors):** Red (#F44336)

### Stat Card Colors
- **People:** Green (#4CAF50)
- **Places:** Blue (#2196F3)
- **Events:** Orange (#FF9800)
- **Things:** Purple (#9C27B0)

### Neutral Colors
- **Background:** Light Grey (#F5F5F5)
- **Card Background:** White (#FFFFFF)
- **Text Primary:** Dark Grey (rgba(0,0,0,0.87))
- **Text Secondary:** Medium Grey (rgba(0,0,0,0.6))
- **Border:** Light Grey (rgba(0,0,0,0.12))

---

## Typography

### Font Family
- **Primary:** Roboto (Material Design standard)
- **Fallback:** -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif

### Font Sizes
- **Page Title:** 2rem (32px)
- **Card Title:** 1.25rem (20px)
- **Body:** 1rem (16px)
- **Small:** 0.875rem (14px)
- **Stat Numbers:** 2rem (32px)

### Font Weights
- **Light:** 300 (page titles)
- **Regular:** 400 (body text)
- **Medium:** 500 (emphasis, names)
- **Bold:** 700 (headings)

---

## Spacing

### Grid System
- **Base Unit:** 8px
- **Small Gap:** 8px
- **Medium Gap:** 16px
- **Large Gap:** 24px
- **XL Gap:** 32px

### Component Spacing
- **Card Padding:** 16px
- **Content Max Width:** 1400px
- **Sidebar Width:** 250px
- **Toolbar Height:** 64px

---

## Icons

### Material Icons
All icons from Material Icons font:
- **Dashboard:** dashboard
- **People:** people
- **Places:** place
- **Events:** event
- **Things:** category
- **Timeline:** timeline
- **Relationships:** hub
- **Share:** share
- **Add:** add, person_add, add_location, etc.
- **Actions:** visibility, edit, delete
- **UI:** menu, search, notifications, account_circle

---

## Responsive Breakpoints

```typescript
// Material Design breakpoints
xs: 0-599px       // Phone
sm: 600-959px     // Tablet portrait
md: 960-1279px    // Tablet landscape
lg: 1280-1919px   // Desktop
xl: 1920px+       // Large desktop
```

### Responsive Behavior
- **< 600px:** Sidebar hidden by default, overlay mode
- **600-959px:** Sidebar visible, can collapse
- **960px+:** Sidebar always visible (default)

---

## Animations & Transitions

### Card Hover
```scss
transition: transform 0.2s, box-shadow 0.2s;
transform: translateY(-4px);
box-shadow: 0 4px 8px rgba(0,0,0,0.2);
```

### Button Click
```scss
Material ripple effect (built-in)
```

### Route Transitions
```scss
fade-in animation (200ms)
```

### Loading States
```scss
Material spinner (indeterminate progress)
```

---

## Accessibility

### ARIA Labels
All buttons and interactive elements have aria-labels:
```html
<button aria-label="Toggle menu">
<button aria-label="Add person">
<input aria-label="Search people">
```

### Keyboard Navigation
- **Tab:** Navigate between elements
- **Enter/Space:** Activate buttons
- **Ctrl+F:** Focus search (implemented in editor)
- **Esc:** Close dialogs/modals

### Color Contrast
- All text meets WCAG AA standards (4.5:1)
- Interactive elements have visible focus indicators

---

## Component States

### Loading
```
┌────────────────────┐
│                    │
│   ⏳ Loading...    │
│                    │
└────────────────────┘
```

### Empty
```
┌────────────────────┐
│     📭 (icon)      │
│   No items found   │
│   [Add New Item]   │
└────────────────────┘
```

### Error
```
┌────────────────────┐
│     ⚠️ (icon)      │
│   Error loading    │
│   [Try Again]      │
└────────────────────┘
```

---

## Future Enhancements

### Dark Mode
- Toggle in user menu
- All colors inverted
- Preserve accessibility

### Mobile App
- Same UI with Capacitor
- Native navigation
- Offline support

### PWA
- Service worker
- Offline mode
- Install prompt

---

**Design System Status:** Implemented ✅  
**UI Components:** 8 built, 6 planned  
**Responsive:** Yes ✅  
**Accessible:** WCAG AA Ready ✅
