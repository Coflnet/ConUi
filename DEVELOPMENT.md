# Connections - Angular Web Application

## Overview
Connections is a genealogy and historical records management system designed to help users store, organize, and share information about people, places, events, things, and their relationships.

## Features

### Implemented (Phase 1) ✅
- **Modern Shell Layout**: Responsive sidebar navigation with Material Design
- **Dashboard**: Overview with quick stats and actions
- **People Management**: List, search, and manage people
- **Routing Structure**: Complete routing for all major features
- **E2E Tests**: Playwright tests for navigation, dashboard, and people management

### Placeholder Components (Ready for Development) 🚧
- Places Management
- Events Timeline
- Things Management
- Timeline Visualization
- Relationship Viewer
- Share & Collaboration

### Planned Features (Future Phases) 📋
- Visual family tree builder
- Interactive timeline
- Document upload and management
- GEDCOM import/export
- Conflict resolution UI
- Multi-user collaboration

## Architecture

### Frontend Stack
- **Framework**: Angular 19
- **UI Library**: Angular Material
- **State Management**: Signals (Angular built-in)
- **Routing**: Angular Router with lazy loading
- **Testing**: Playwright for E2E, Karma/Jasmine for unit tests

### API Integration
Auto-generated client services from OpenAPI:
- PersonService
- PlaceService
- EventService
- ThingService
- RelationshipService
- SearchService
- ShareService
- DocumentService

## Project Structure

```
src/app/
├── client/              # Auto-generated API client
│   ├── api/            # Service classes
│   └── model/          # TypeScript interfaces
├── features/           # Feature modules
│   ├── dashboard/
│   ├── people/
│   │   └── people-list/
│   ├── places/
│   ├── events/
│   ├── things/
│   ├── timeline/
│   ├── relationships/
│   └── share/
├── layout/
│   └── shell/          # Main application shell
├── editor/             # Legacy editor (to be refactored)
├── field/              # Reusable field component
├── login/              # Authentication
└── map-container/      # Map integration
```

## Getting Started

### Prerequisites
- Node.js 18+
- npm or yarn
- Angular CLI 19

### Installation
```bash
npm install
```

### Development Server
```bash
npm start
# Navigate to http://localhost:4200
```

### Running Tests

#### Unit Tests
```bash
npm test
```

#### E2E Tests
```bash
# Run all E2E tests
npm run test:e2e

# Run with UI mode (recommended for development)
npm run test:e2e:ui

# Run in headed mode (see browser)
npm run test:e2e:headed
```

## Testing Strategy

### E2E Tests with Playwright
Located in `/e2e` directory:

1. **navigation.spec.ts**: Tests sidebar navigation and routing
2. **dashboard.spec.ts**: Tests dashboard stats, quick actions, and navigation
3. **people.spec.ts**: Tests people list, search, and CRUD operations

### Test Coverage
- ✅ Navigation flow between all main sections
- ✅ Dashboard stat cards and quick actions
- ✅ People list display and search
- ✅ Sidebar toggle functionality
- 🚧 Person creation workflow (partial)
- 🚧 Authentication flow (pending)
- 🚧 Relationship management (pending)
- 🚧 Share functionality (pending)

## Development Workflow

### Adding New Features
1. Create feature module in `src/app/features/[feature-name]/`
2. Add route in `app.routes.ts`
3. Add navigation item in `shell.component.ts`
4. Create Playwright tests in `e2e/[feature-name].spec.ts`
5. Implement component logic
6. Run tests to verify

### Code Generation
The API client is auto-generated. To regenerate:
```bash
./generateclientBindings.sh
```

## Backend Integration

### Current API Endpoints
All endpoints are documented in the OpenAPI spec and accessed through generated services.

### Recommended Backend Enhancements

#### 1. Batch Operations
```
POST /api/Batch/import - Import multiple entities at once
POST /api/Person/bulk - Create multiple people
```

#### 2. Aggregated Endpoints
```
GET /api/Person/{id}/full - Return person with all related data
GET /api/Person/{id}/timeline - Pre-built timeline data
GET /api/Dashboard/stats - Get counts for dashboard
```

#### 3. Search Improvements
- Add fuzzy search support
- Add pagination (limit/offset)
- Add faceted filters (by type, date range, etc.)
- Return total count with results

#### 4. Relationship Suggestions
```
GET /api/Relationship/suggestions/{personId} - AI-suggested relationships
```

#### 5. Real-time Updates
- WebSocket support for collaborative editing
- Change notifications

## UX Design Principles

### Ease of Use
1. **Progressive Disclosure**: Show basic info first, details on demand
2. **Inline Editing**: Edit directly in lists/cards where possible
3. **Auto-save**: Save changes automatically on blur
4. **Smart Defaults**: Pre-fill common fields
5. **Quick Add**: Fast entry points for common actions

### CRM-Style Data Entry
- Tab-based organization within entities
- Quick add panels for rapid data entry
- Relationship builder with visual feedback
- Document drag-and-drop upload
- Keyboard shortcuts for power users

### Search & Discovery
- Global search with type filters
- Recent items quick access
- Favorites/bookmarks
- Suggested connections

## Accessibility
- ARIA labels on all interactive elements
- Keyboard navigation support
- High contrast theme support
- Screen reader compatible

## Performance Considerations
- Lazy loading for all feature modules
- Virtual scrolling for large lists
- Image optimization
- Pagination for search results
- Service worker for offline capability (future)

## Browser Support
- Chrome/Edge (latest)
- Firefox (latest)
- Safari (latest)
- Mobile browsers (responsive design)

## Contributing

### Code Style
- Follow Angular style guide
- Use TypeScript strict mode
- Write tests for new features
- Document complex logic

### Commit Messages
Use conventional commits:
- `feat:` New feature
- `fix:` Bug fix
- `test:` Add or update tests
- `docs:` Documentation
- `refactor:` Code refactoring
- `style:` Formatting changes

## Roadmap

### Phase 2: Core Entities (Next)
- [ ] Places list and detail view
- [ ] Map integration for place selection
- [ ] Events timeline view
- [ ] Things grid view
- [ ] Advanced search filters

### Phase 3: Visualizations
- [ ] Family tree visualization (D3.js)
- [ ] Interactive timeline
- [ ] Relationship graph
- [ ] Photo gallery

### Phase 4: Collaboration
- [ ] Share invitation UI
- [ ] Conflict resolution interface
- [ ] Data provenance display
- [ ] Activity feed

### Phase 5: Import/Export
- [ ] GEDCOM import
- [ ] CSV batch import
- [ ] PDF export
- [ ] Print layouts

### Phase 6: Polish
- [ ] Onboarding tour
- [ ] Undo/redo
- [ ] Dark theme
- [ ] Mobile app (Capacitor)

## License
[Your License Here]

## Contact
[Your Contact Information]
