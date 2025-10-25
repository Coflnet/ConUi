# Implementation Plan & Status

## Executive Summary

This document outlines the transformation of the Connections Angular app from a basic person data editor into a comprehensive genealogy and historical records management system.

**Target Use Cases:**
- Family tree documentation for multiple people
- Historic village/community member tracking
- Personal data management with easy sharing
- Collaborative genealogy research

---

## ✅ COMPLETED (Phase 1)

### 1. Testing Infrastructure
- ✅ Playwright installed and configured
- ✅ E2E test structure created (`/e2e` directory)
- ✅ Test scripts added to package.json
- ✅ Basic test coverage:
  - Navigation between sections
  - Dashboard functionality
  - People list and search

### 2. Modern Application Shell
- ✅ Created `ShellComponent` with responsive sidebar
- ✅ Material Design toolbar with search, notifications, user menu
- ✅ Collapsible sidebar navigation
- ✅ Professional layout with proper spacing

### 3. Dashboard
- ✅ Stats cards for People, Places, Events, Things
- ✅ Quick action buttons
- ✅ Recent activity section (empty state ready)
- ✅ Fully responsive grid layout

### 4. People Management
- ✅ `PeopleListComponent` with table view
- ✅ Search functionality with debouncing
- ✅ Empty state handling
- ✅ Action buttons (view, edit, delete)
- ✅ Integration with SearchService

### 5. Routing Structure
- ✅ Nested routes under shell component
- ✅ Lazy loading for feature modules
- ✅ Route guards ready for authentication
- ✅ All main routes defined

### 6. Placeholder Components
- ✅ Places list
- ✅ Events list
- ✅ Things list
- ✅ Timeline viewer
- ✅ Relationships viewer
- ✅ Share management

---

## 🚧 IN PROGRESS / NEXT STEPS

### Immediate Priorities

#### 1. Enhanced Person Detail View
**Status:** To be implemented  
**Components:**
- Tab-based interface (Basic Info, Relationships, Events, Timeline, Documents)
- Inline editing with auto-save
- Photo upload
- Quick relationship adder

**Backend Needs:**
- ✅ Already available: `PersonService.getPersonData()`
- ⚠️ **Recommended:** `GET /api/Person/{id}/full` - Returns person with relationships and events in one call

#### 2. Relationship Management
**Status:** Backend ready, UI needed  
**Components:**
- Visual relationship builder
- Relationship type selector (family, professional, social)
- Bidirectional relationship creation
- Certainty/confidence slider

**Backend Needs:**
- ✅ Already available: `RelationshipService` with CRUD operations
- ✅ Bidirectional relationships supported
- ⚠️ **Recommended:** `GET /api/Relationship/suggestions/{personId}` - ML-based relationship suggestions

#### 3. Places Management
**Status:** Placeholder exists  
**Components:**
- Hierarchical place list (country → region → city → street)
- Map integration for coordinate selection
- Place search with autocomplete
- Associated people/events display

**Backend Needs:**
- ✅ Already available: `PlaceService` with hierarchy support
- ✅ Lat/long storage available
- ⚠️ **Recommended:** Add geocoding endpoint or integrate external service

---

## 📋 PLANNED PHASES

### Phase 2: Core Entities (2-3 weeks)

#### Places Management
- [ ] Hierarchical tree view
- [ ] Map picker component (Leaflet already installed)
- [ ] Place detail view with timeline
- [ ] Batch import from CSV

#### Events Timeline
- [ ] List view with filters (date range, person, place)
- [ ] Calendar view integration
- [ ] Event detail modal
- [ ] Quick event creation

#### Things Management
- [ ] Grid/list toggle view
- [ ] Ownership history timeline
- [ ] Photo gallery
- [ ] Category filters

**Backend Enhancements Needed:**
```typescript
// Dashboard stats
GET /api/Dashboard/stats
Response: { people: 0, places: 0, events: 0, things: 0 }

// Paginated search
GET /api/Search?query=...&limit=20&offset=0&type=person
Response: { results: [...], total: 100 }

// Place geocoding (optional)
POST /api/Place/geocode
Body: { address: "..." }
Response: { lat: 0, lng: 0, confidence: 0.9 }
```

---

### Phase 3: Visualizations (2-3 weeks)

#### Family Tree
- [ ] D3.js-based tree visualization
- [ ] Zoom and pan controls
- [ ] Click to expand/collapse branches
- [ ] Export as SVG/PNG

#### Interactive Timeline
- [ ] Horizontal timeline with event markers
- [ ] Multi-person comparison view
- [ ] Historical context integration
- [ ] Filter by event type

#### Relationship Graph
- [ ] Force-directed graph layout
- [ ] Color coding by relationship type
- [ ] Strength indicators (certainty)
- [ ] Interactive editing

**Backend Enhancements Needed:**
```typescript
// Tree data structure
GET /api/Person/{id}/tree?generations=3
Response: { person: {...}, ancestors: [...], descendants: [...] }

// Timeline data
GET /api/Person/{id}/timeline?from=1900-01-01&to=2024-12-31
Response: [ { date, type, title, description, relatedEntities } ]

// Graph data
GET /api/Relationship/graph?centerPersonId=...&depth=2
Response: { nodes: [...], edges: [...] }
```

---

### Phase 4: Collaboration & Sharing (2 weeks)

#### Share Management UI
- [ ] Create invitation modal
- [ ] Invitation list with status
- [ ] Accept/reject invitation workflow
- [ ] Selective sharing (choose entities)

#### Conflict Resolution
- [ ] Side-by-side diff view
- [ ] Merge options (keep mine, theirs, both)
- [ ] Conflict notification badge
- [ ] Auto-merge rules

#### Data Provenance
- [ ] Source attribution display
- [ ] Edit history timeline
- [ ] Contributor badges
- [ ] Trust scores

**Backend Support:**
- ✅ `ShareService` already implements invitations
- ✅ Conflict detection available
- ✅ Provenance tracking exists
- ⚠️ **Recommended:** Add WebSocket support for real-time collaboration

---

### Phase 5: Import/Export (1 week)

#### GEDCOM Support
- [ ] GEDCOM 5.5.1 parser
- [ ] Import wizard with preview
- [ ] Conflict detection during import
- [ ] Export to GEDCOM

#### Batch Operations
- [ ] CSV import template generator
- [ ] Field mapping interface
- [ ] Validation and error reporting
- [ ] Rollback capability

#### Export Options
- [ ] PDF reports (family tree, timeline)
- [ ] Excel export for data analysis
- [ ] HTML static site generator
- [ ] Print-friendly layouts

**Backend Enhancements Needed:**
```typescript
// Batch import
POST /api/Batch/import
Body: { format: 'gedcom|csv', data: '...', options: {...} }
Response: { imported: 100, errors: [...], conflicts: [...] }

// Export
POST /api/Export/generate
Body: { format: 'gedcom|csv|pdf', entities: [...] }
Response: { downloadUrl: '...' }
```

---

### Phase 6: Polish & UX (1-2 weeks)

#### Onboarding
- [ ] Welcome tour with tooltips
- [ ] Quick start wizard
- [ ] Sample data option
- [ ] Tutorial videos

#### Productivity Features
- [ ] Keyboard shortcuts (Ctrl+K command palette)
- [ ] Undo/redo stack
- [ ] Bulk edit mode
- [ ] Templates for common scenarios

#### Themes & Customization
- [ ] Dark mode
- [ ] Custom color schemes
- [ ] Layout preferences
- [ ] Font size adjustment

#### Performance
- [ ] Virtual scrolling for large lists
- [ ] Image lazy loading
- [ ] Service worker for offline mode
- [ ] IndexedDB caching

---

## Backend Recommendations Summary

### High Priority (Phase 2)
1. **Dashboard Stats Endpoint**
   ```
   GET /api/Dashboard/stats
   ```
   *Reason:* Dashboard shows 0 for all counts currently

2. **Paginated Search**
   ```
   GET /api/Search?limit=20&offset=0
   ```
   *Reason:* Performance with large datasets

3. **Aggregated Person Data**
   ```
   GET /api/Person/{id}/full
   ```
   *Reason:* Reduce multiple API calls

### Medium Priority (Phase 3)
4. **Tree Data Structure**
   ```
   GET /api/Person/{id}/tree?generations=3
   ```
   *Reason:* Required for family tree visualization

5. **Timeline Data**
   ```
   GET /api/Person/{id}/timeline
   ```
   *Reason:* Optimized for timeline rendering

### Nice to Have
6. **Relationship Suggestions** (ML-based)
7. **Geocoding Integration**
8. **WebSocket for Real-time Updates**
9. **Full-text Search** (Elasticsearch/similar)

---

## Testing Strategy

### Current Test Coverage
- ✅ Navigation (all routes)
- ✅ Dashboard (stats, quick actions)
- ✅ People list (display, search)
- 🚧 Person CRUD (partial)

### Planned Test Coverage

#### Unit Tests
- [ ] Components (80%+ coverage)
- [ ] Services (mock API calls)
- [ ] Pipes and utilities
- [ ] Validators

#### E2E Tests
- [x] Navigation flow
- [x] Dashboard interaction
- [ ] Complete person creation flow
- [ ] Relationship creation
- [ ] Share invitation workflow
- [ ] Conflict resolution
- [ ] Import/export
- [ ] Search functionality
- [ ] Timeline interaction
- [ ] Family tree navigation

#### Integration Tests
- [ ] API service integration
- [ ] Authentication flow
- [ ] File upload
- [ ] Real-time updates

---

## Performance Targets

- **First Contentful Paint:** < 1.5s
- **Time to Interactive:** < 3s
- **Lighthouse Score:** > 90
- **Bundle Size:** < 500KB (initial)
- **API Response Time:** < 200ms (p95)

---

## Accessibility Checklist

- [x] ARIA labels on all controls
- [x] Keyboard navigation
- [ ] Screen reader testing
- [ ] Color contrast (WCAG AA)
- [ ] Focus indicators
- [ ] Form validation messages
- [ ] Error announcements

---

## Browser Support Matrix

| Browser | Version | Status |
|---------|---------|--------|
| Chrome | Latest | ✅ Primary |
| Edge | Latest | ✅ Primary |
| Firefox | Latest | ✅ Supported |
| Safari | Latest | ✅ Supported |
| Mobile Safari | iOS 14+ | 🚧 Testing needed |
| Chrome Mobile | Latest | 🚧 Testing needed |

---

## Deployment Strategy

### Environments
1. **Development** - Local/dev branch
2. **Staging** - Feature branches, preview deployments
3. **Production** - Main branch, auto-deploy

### CI/CD Pipeline
```yaml
- Lint & Format check
- Unit tests (Karma)
- E2E tests (Playwright)
- Build production bundle
- Deploy to environment
- Smoke tests
```

---

## Success Metrics

### User Engagement
- Daily active users
- Average session duration
- Entities created per user
- Share invitations sent

### Performance
- Page load time
- API response time
- Error rate
- Uptime

### Quality
- Bug count
- Test coverage
- Accessibility score
- User satisfaction (NPS)

---

## Next Actions

### Immediate (This Week)
1. ✅ Complete Phase 1 setup
2. 🚧 Implement enhanced person detail view
3. 🚧 Add relationship creation UI
4. 🚧 Create places list component

### Short Term (Next 2 Weeks)
1. Complete core entity management (Places, Events, Things)
2. Implement basic search filters
3. Add backend stats endpoint
4. Expand E2E test coverage

### Medium Term (Next Month)
1. Build visualization components (tree, timeline)
2. Implement sharing workflow
3. Add import/export
4. Performance optimization

---

## Questions for Backend Team

1. **Stats Endpoint:** Can we add a dashboard stats endpoint?
2. **Pagination:** What's the max result size before we need pagination?
3. **Real-time:** Any plans for WebSocket support?
4. **Search:** Is full-text search available or planned?
5. **Rate Limiting:** What are the current API rate limits?
6. **Geocoding:** Should we integrate external service or add backend support?

---

## Open Issues

- [ ] Authentication integration (Firebase configured but not used)
- [ ] Error handling strategy (toast notifications vs inline)
- [ ] Offline mode support
- [ ] Mobile app consideration (Capacitor/Ionic)
- [ ] Multi-language support (i18n)

---

**Last Updated:** 2024-10-25  
**Version:** 1.0  
**Status:** Phase 1 Complete ✅
