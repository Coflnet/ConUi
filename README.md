# Connections - Genealogy & Historical Records Management

> A modern Angular web application for managing people, places, events, things, and their relationships. Perfect for family history research, community documentation, and collaborative genealogy projects.

[![Angular](https://img.shields.io/badge/Angular-19-red)](https://angular.dev)
[![TypeScript](https://img.shields.io/badge/TypeScript-5.5-blue)](https://www.typescriptlang.org/)
[![Material Design](https://img.shields.io/badge/Material-19-purple)](https://material.angular.io)
[![Playwright](https://img.shields.io/badge/E2E-Playwright-green)](https://playwright.dev)

---

## 🌟 Features

### ✅ Implemented (Phase 1)
- **Modern Dashboard** - Overview with stats and quick actions
- **People Management** - List, search, and manage people
- **Professional UI** - Material Design with responsive layout
- **Navigation** - Sidebar navigation with 8 main sections
- **Testing** - Comprehensive Playwright E2E test suite
- **Documentation** - Complete developer and user guides

### 🚧 In Development
- Enhanced person detail view with tabs
- Relationship visualization
- Places management with map integration
- Events timeline
- Things catalog

### 📋 Planned
- Visual family tree (D3.js)
- Interactive timeline
- Share & collaboration
- GEDCOM import/export
- Conflict resolution
- Document management

---

## 🚀 Quick Start

### Prerequisites
- Node.js 18+
- npm or yarn

### Installation
```bash
# Clone repository
git clone [your-repo-url]
cd ConUi

# Install dependencies
npm install

# Start development server
npm start
```

Navigate to `http://localhost:4200`

### Run Tests
```bash
# E2E tests (interactive UI)
npm run test:e2e:ui

# E2E tests (headless)
npm run test:e2e

# Unit tests
npm test
```

---

## 📚 Documentation

### For Developers
- **[QUICKSTART.md](QUICKSTART.md)** - Get started in 5 minutes
- **[DEVELOPMENT.md](DEVELOPMENT.md)** - Complete development guide
- **[IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md)** - Detailed roadmap
- **[UI_DESIGN.md](UI_DESIGN.md)** - UI/UX design system

### For Users
- **[SUMMARY.md](SUMMARY.md)** - What's new and what's working

---

## 🏗️ Architecture

### Tech Stack
- **Framework:** Angular 19 (standalone components)
- **UI Library:** Angular Material 19
- **State Management:** Signals (Angular built-in)
- **Testing:** Playwright (E2E) + Karma/Jasmine (Unit)
- **API Client:** Auto-generated from OpenAPI

### Project Structure
```
src/app/
├── client/              # Auto-generated API client
├── features/            # Feature modules
│   ├── dashboard/       ✅ Implemented
│   ├── people/          ✅ Implemented
│   ├── places/          🚧 Placeholder
│   ├── events/          🚧 Placeholder
│   ├── things/          🚧 Placeholder
│   ├── timeline/        🚧 Placeholder
│   ├── relationships/   🚧 Placeholder
│   └── share/           🚧 Placeholder
├── layout/
│   └── shell/           ✅ Main layout
└── ...legacy components
```

---

## 🎯 Use Cases

### Family History
- Document multiple family lines
- Create visual family trees
- Track births, marriages, deaths
- Share with family members

### Historical Research
- Record village/community members
- Track historical events
- Document places and buildings
- Collaborative research

### Personal CRM
- Store contact information
- Track relationships
- Document interactions
- Export for backup

---

## 🧪 Testing

### E2E Test Coverage
- ✅ Navigation between all sections
- ✅ Dashboard stats and actions
- ✅ People list and search
- 🚧 Person CRUD operations
- 🚧 Relationship management
- 🚧 Share workflow

### Running Tests
```bash
# Interactive mode (recommended)
npm run test:e2e:ui

# Headless mode
npm run test:e2e

# Specific test file
npx playwright test e2e/dashboard.spec.ts

# With browser visible
npm run test:e2e:headed
```

---

## 🔌 Backend Integration

### API Services
All auto-generated from OpenAPI specification:

- `PersonService` - Person CRUD operations
- `PlaceService` - Place management
- `EventService` - Event tracking
- `ThingService` - Thing catalog
- `RelationshipService` - Relationship management
- `SearchService` - Global search
- `ShareService` - Sharing & collaboration
- `DocumentService` - Document management

### Example Usage
```typescript
import { PersonService } from './client';

constructor(private personService: PersonService) {}

ngOnInit() {
  this.personService.getPersonData('person-id')
    .subscribe(data => console.log(data));
}
```

### Recommended Backend Enhancements
See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for detailed list:
- Dashboard stats endpoint
- Paginated search
- Aggregated person data
- Relationship suggestions
- Real-time updates (WebSocket)

---

## 🎨 Design System

### Colors
- **Primary:** Indigo (#3F51B5)
- **People:** Green (#4CAF50)
- **Places:** Blue (#2196F3)
- **Events:** Orange (#FF9800)
- **Things:** Purple (#9C27B0)

### Typography
- **Font:** Roboto
- **Scale:** 8px grid system

### Components
- Material Design 3
- Responsive breakpoints
- WCAG AA accessible

See [UI_DESIGN.md](UI_DESIGN.md) for complete design system.

---

## 📊 Roadmap

### Phase 2: Core Entities (2-3 weeks)
- [ ] Enhanced person detail view
- [ ] Places list with map integration
- [ ] Events timeline
- [ ] Things management

### Phase 3: Visualizations (2-3 weeks)
- [ ] Family tree visualization
- [ ] Interactive timeline
- [ ] Relationship graph

### Phase 4: Collaboration (2 weeks)
- [ ] Share workflow UI
- [ ] Conflict resolution
- [ ] Data provenance display

### Phase 5: Import/Export (1 week)
- [ ] GEDCOM support
- [ ] CSV batch import/export
- [ ] PDF reports

### Phase 6: Polish (1-2 weeks)
- [ ] Onboarding tour
- [ ] Dark mode
- [ ] Keyboard shortcuts
- [ ] Performance optimization

---

## 🤝 Contributing

### Getting Started
1. Read [DEVELOPMENT.md](DEVELOPMENT.md)
2. Check existing components for patterns
3. Write tests for new features
4. Follow conventional commits

### Commit Format
```
type(scope): subject

body

footer
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

### Code Style
- TypeScript strict mode
- Angular style guide
- Prettier formatting
- ESLint rules

---

## 📈 Performance

### Targets
- First Contentful Paint: < 1.5s
- Time to Interactive: < 3s
- Lighthouse Score: > 90
- Bundle Size: < 500KB (initial)

### Optimizations
- Lazy loading routes
- Debounced search
- Virtual scrolling (planned)
- Image optimization (planned)
- Service worker (planned)

---

## 🌐 Browser Support

- Chrome/Edge (latest) ✅
- Firefox (latest) ✅
- Safari (latest) ✅
- Mobile browsers (testing needed) 🚧

---

## 📄 License

[Your License Here]

---

## 📞 Contact & Support

- **Issues:** [GitHub Issues](your-repo/issues)
- **Discussions:** [GitHub Discussions](your-repo/discussions)
- **Email:** your-email@example.com

---

## 🙏 Acknowledgments

- Angular Team
- Material Design Team
- Playwright Team
- All contributors

---

## 📝 Development Status

**Current Phase:** 1 Complete ✅  
**Next Phase:** 2 - Core Entities  
**Last Updated:** 2024-10-25

### Recent Changes
- ✅ Implemented modern shell layout
- ✅ Created dashboard with stats
- ✅ Built people management
- ✅ Added Playwright testing
- ✅ Comprehensive documentation

### Next Steps
1. Enhanced person detail view
2. Relationship management
3. Places with map integration
4. Events timeline

See [IMPLEMENTATION_PLAN.md](IMPLEMENTATION_PLAN.md) for complete roadmap.

---

**Built with ❤️ using Angular & Material Design**
