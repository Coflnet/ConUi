# Component Architecture Diagram

## Application Component Hierarchy

```
AppComponent (app-root)
│
├─── LoginComponent (/login)
│    └─── [Auth UI]
│
└─── ShellComponent (Main Layout)
     ├─── MatToolbar
     │    ├─── Menu Toggle Button
     │    ├─── App Title
     │    ├─── Search Button
     │    ├─── Notifications Button
     │    └─── User Menu Button
     │
     ├─── MatSidenav (Navigation)
     │    └─── MatNavList
     │         ├─── Dashboard Link
     │         ├─── People Link
     │         ├─── Places Link
     │         ├─── Events Link
     │         ├─── Things Link
     │         ├─── Timeline Link
     │         ├─── Relationships Link
     │         └─── Share Link
     │
     └─── Router Outlet (Main Content)
          │
          ├─── DashboardComponent (/dashboard)
          │    ├─── Stats Grid
          │    │    ├─── People Stat Card
          │    │    ├─── Places Stat Card
          │    │    ├─── Events Stat Card
          │    │    └─── Things Stat Card
          │    ├─── Quick Actions Card
          │    │    ├─── Add Person Button
          │    │    ├─── Add Event Button
          │    │    ├─── Add Place Button
          │    │    └─── Add Thing Button
          │    └─── Recent Activity Card
          │
          ├─── PeopleListComponent (/people)
          │    ├─── Header
          │    │    ├─── Page Title
          │    │    └─── Add Person Button
          │    ├─── Search Card
          │    │    └─── MatFormField (Search Input)
          │    └─── Table Card
          │         ├─── Loading State
          │         ├─── Empty State
          │         └─── MatTable
          │              ├─── Name Column
          │              ├─── Description Column
          │              └─── Actions Column
          │                   ├─── View Button
          │                   ├─── Edit Button
          │                   └─── Delete Button
          │
          ├─── EditorComponent (/people/:id, /people/new, /editor)
          │    ├─── NgSelect (Person Search)
          │    ├─── Person Title
          │    ├─── Fields Container
          │    │    └─── FieldComponent (multiple)
          │    │         └─── MatFormField
          │    ├─── New Field Input
          │    │    └─── MatAutocomplete
          │    └─── Add Field Button
          │
          ├─── PlacesListComponent (/places)
          │    └─── [Placeholder - Coming Soon]
          │
          ├─── EventsListComponent (/events)
          │    └─── [Placeholder - Coming Soon]
          │
          ├─── ThingsListComponent (/things)
          │    └─── [Placeholder - Coming Soon]
          │
          ├─── TimelineComponent (/timeline)
          │    └─── [Placeholder - Coming Soon]
          │
          ├─── RelationshipsComponent (/relationships)
          │    └─── [Placeholder - Coming Soon]
          │
          ├─── ShareComponent (/share)
          │    └─── [Placeholder - Coming Soon]
          │
          └─── MapContainerComponent (/map)
               └─── [Leaflet Map Integration]
```

---

## Data Flow Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Components                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │  Dashboard   │  │ People List  │  │   Editor     │     │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘     │
│         │                  │                  │              │
│         └──────────────────┼──────────────────┘              │
│                            │                                 │
└────────────────────────────┼─────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                       Services                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │PersonService │  │SearchService │  │ ShareService │     │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘     │
│         │                  │                  │              │
│         └──────────────────┼──────────────────┘              │
│                            │                                 │
│  ┌──────────────┐  ┌──────┴───────┐  ┌──────────────┐     │
│  │ PlaceService │  │ EventService │  │ ThingService │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                    HTTP Client                               │
│                 (Angular HttpClient)                         │
└────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                     Backend API                              │
│              (Auto-generated Client)                         │
│                                                              │
│  /api/Person        /api/Place       /api/Event            │
│  /api/Thing         /api/Relationship                       │
│  /api/Search        /api/Share                              │
└─────────────────────────────────────────────────────────────┘
```

---

## State Management Flow

```
┌─────────────────────────────────────────────────────────────┐
│                    Component State                           │
│                   (Angular Signals)                          │
│                                                              │
│  Signal<SearchResult[]> people                              │
│  Signal<boolean> loading                                     │
│  Signal<boolean> sidenavOpened                              │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                  User Interaction                            │
│  (clicks, typing, navigation)                               │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                   Event Handlers                             │
│  onSearchChange(), toggleSidenav(), etc.                    │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                   Service Calls                              │
│  searchService.search()                                      │
│  personService.getPersonData()                              │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                  Observable Stream                           │
│  (RxJS operators: debounceTime, switchMap, etc.)           │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                 Update Signal State                          │
│  people.set(results)                                        │
│  loading.set(false)                                         │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                  Template Re-render                          │
│  (Automatic with Signals)                                   │
└─────────────────────────────────────────────────────────────┘
```

---

## Routing Structure

```
┌─────────────────────────────────────────────────────────────┐
│  / (root)                                                    │
└───┬─────────────────────────────────────────────────────────┘
    │
    ├── /login ────────────────► LoginComponent
    │
    └── / (ShellComponent - Layout Wrapper)
        │
        ├── /dashboard ────────────► DashboardComponent
        │
        ├── /people ───────────────► PeopleListComponent
        │   ├── /people/new ───────► EditorComponent
        │   ├── /people/:id ───────► EditorComponent
        │   └── /people/:id/edit ──► EditorComponent
        │
        ├── /places ───────────────► PlacesListComponent
        │
        ├── /events ───────────────► EventsListComponent
        │
        ├── /things ───────────────► ThingsListComponent
        │
        ├── /timeline ─────────────► TimelineComponent
        │
        ├── /relationships ────────► RelationshipsComponent
        │
        ├── /share ────────────────► ShareComponent
        │
        ├── /map ──────────────────► MapContainerComponent
        │
        ├── /editor ───────────────► EditorComponent (legacy)
        │
        ├── /edit/p/:person ───────► EditorComponent (legacy)
        │
        └── / (redirect to /dashboard)
```

---

## Testing Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    E2E Tests (Playwright)                    │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐     │
│  │ navigation   │  │  dashboard   │  │   people     │     │
│  │   .spec.ts   │  │   .spec.ts   │  │  .spec.ts    │     │
│  └──────────────┘  └──────────────┘  └──────────────┘     │
│                                                              │
│  Tests:                                                      │
│  • Route navigation                                          │
│  • Sidebar functionality                                     │
│  • Dashboard stats & actions                                 │
│  • People list & search                                      │
│  • CRUD operations                                           │
│                                                              │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼
┌─────────────────────────────────────────────────────────────┐
│                 Running Application                          │
│              (http://localhost:4200)                         │
└─────────────────────────────────────────────────────────────┘
```

---

## Module Dependencies

```
AppModule (Standalone Architecture)
│
├── Angular Core Modules
│   ├── @angular/core
│   ├── @angular/common
│   ├── @angular/router
│   ├── @angular/forms
│   └── @angular/platform-browser
│
├── Angular Material Modules
│   ├── MatSidenavModule
│   ├── MatToolbarModule
│   ├── MatListModule
│   ├── MatIconModule
│   ├── MatButtonModule
│   ├── MatCardModule
│   ├── MatTableModule
│   ├── MatFormFieldModule
│   ├── MatInputModule
│   └── MatAutocompleteModule
│
├── Third-party Modules
│   ├── @ng-select/ng-select
│   ├── @bluehalo/ngx-leaflet
│   └── @angular/fire (Firebase)
│
└── Application Modules
    ├── Client Services (Auto-generated)
    │   ├── PersonService
    │   ├── PlaceService
    │   ├── EventService
    │   ├── ThingService
    │   ├── RelationshipService
    │   ├── SearchService
    │   ├── ShareService
    │   └── DocumentService
    │
    └── Feature Components
        ├── ShellComponent
        ├── DashboardComponent
        ├── PeopleListComponent
        ├── EditorComponent
        ├── FieldComponent
        └── ... (more components)
```

---

## Build & Deployment Flow

```
┌─────────────────────────────────────────────────────────────┐
│                  Source Code (TypeScript)                    │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              Angular Compiler (ng build)                     │
│  • TypeScript → JavaScript                                   │
│  • Templates → Render Functions                              │
│  • Styles → CSS                                              │
│  • Tree Shaking                                              │
│  • Minification                                              │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              dist/connections/browser/                       │
│  • main.[hash].js                                            │
│  • polyfills.[hash].js                                       │
│  • styles.[hash].css                                         │
│  • index.html                                                │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│                  Deployment Target                           │
│  • Static Hosting (Vercel, Netlify, etc.)                   │
│  • CDN                                                       │
│  • Docker Container                                          │
└─────────────────────────────────────────────────────────────┘
```

---

## Service Worker Flow (Planned)

```
┌─────────────────────────────────────────────────────────────┐
│                  Browser (Client)                            │
│                                                              │
│  ┌────────────────────────────────────────────────┐         │
│  │            Angular Application                 │         │
│  └────────────┬───────────────────────────────────┘         │
│               │                                              │
│               ▼                                              │
│  ┌────────────────────────────────────────────────┐         │
│  │           Service Worker                       │         │
│  │  • Cache API responses                         │         │
│  │  • Offline support                             │         │
│  │  • Background sync                             │         │
│  └────────────┬───────────────────────────────────┘         │
└───────────────┼──────────────────────────────────────────────┘
                │
                ▼
┌─────────────────────────────────────────────────────────────┐
│                     Network                                  │
│  ┌────────────────────────────────────────────────┐         │
│  │              Backend API                       │         │
│  └────────────────────────────────────────────────┘         │
└─────────────────────────────────────────────────────────────┘
```

---

## Component Lifecycle

```
┌─────────────────────────────────────────────────────────────┐
│              Component Creation                              │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              constructor()                                   │
│  • Dependency injection                                      │
│  • Initialize properties                                     │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              ngOnInit()                                      │
│  • Setup subscriptions                                       │
│  • Initial data load                                         │
│  • Configure observables                                     │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              Component Active                                │
│  • User interactions                                         │
│  • Signal updates                                            │
│  • Template rendering                                        │
└───────────────────────┬─────────────────────────────────────┘
                        │
                        ▼
┌─────────────────────────────────────────────────────────────┐
│              ngOnDestroy()                                   │
│  • Cleanup subscriptions                                     │
│  • Release resources                                         │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Design Patterns Used

### 1. **Component Composition**
```
Container Component (Smart)
├── Presentation Component (Dumb)
├── Presentation Component (Dumb)
└── Presentation Component (Dumb)
```

### 2. **Observable Pattern (RxJS)**
```typescript
searchInput$
  .pipe(
    debounceTime(300),
    switchMap(term => searchService.search(term)),
    catchError(() => of([]))
  )
  .subscribe(results => people.set(results));
```

### 3. **Dependency Injection**
```typescript
constructor(
  private searchService: SearchService,
  private router: Router
) {}
```

### 4. **Signal-based State**
```typescript
people = signal<SearchResult[]>([]);
loading = signal(false);

// Update
people.set(newResults);

// Template
{{ people() }}
```

### 5. **Lazy Loading**
```typescript
{
  path: 'dashboard',
  loadComponent: () => import('./dashboard').then(m => m.DashboardComponent)
}
```

---

## Error Handling Flow

```
User Action
    │
    ▼
Service Call
    │
    ├─── Success ──────► Update State ──► Render UI
    │
    └─── Error ────────► catchError() ──► Show Error State
                            │
                            ├─── Retry Option
                            ├─── Error Message
                            └─── Fallback UI
```

---

**Architecture Status:** Implemented ✅  
**Pattern Compliance:** Angular Best Practices ✅  
**Scalability:** High ✅  
**Maintainability:** High ✅
