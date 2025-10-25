# Quick Start Guide

## 🚀 Get Started in 5 Minutes

### 1. Install Dependencies
```bash
npm install
```

### 2. Start Development Server
```bash
npm start
```
Navigate to `http://localhost:4200`

### 3. Run Tests
```bash
# Run E2E tests in UI mode (recommended for development)
npm run test:e2e:ui

# Or run all tests
npm run test:e2e
```

---

## 📁 What's New

### Modern Layout
- Professional sidebar navigation
- Material Design throughout
- Responsive design
- Dark mode ready

### Features Implemented
1. **Dashboard** - Overview with stats and quick actions
2. **People List** - Searchable table with CRUD operations
3. **Navigation** - Clean routing between all sections
4. **Testing** - Playwright E2E tests

### Placeholder Components (Ready to Build)
- Places Management
- Events Timeline
- Things Catalog
- Timeline Visualization
- Relationship Graph
- Share & Collaborate

---

## 🔧 Common Tasks

### Create a New Feature Component
```bash
ng generate component features/my-feature --standalone
```

### Add a New Route
1. Create component
2. Add route to `src/app/app.routes.ts`
3. Add nav item to `src/app/layout/shell/shell.component.ts`

### Add an E2E Test
Create `e2e/my-feature.spec.ts`:
```typescript
import { test, expect } from '@playwright/test';

test.describe('My Feature', () => {
  test('should work', async ({ page }) => {
    await page.goto('/my-feature');
    await expect(page.locator('h1')).toContainText('My Feature');
  });
});
```

---

## 🎯 Key Files to Know

### Application Structure
- `src/app/app.routes.ts` - All routes
- `src/app/layout/shell/` - Main layout
- `src/app/features/` - Feature modules
- `src/app/client/` - Auto-generated API client

### Configuration
- `playwright.config.ts` - E2E test configuration
- `angular.json` - Angular project configuration
- `tsconfig.json` - TypeScript configuration

### Documentation
- `DEVELOPMENT.md` - Full development guide
- `IMPLEMENTATION_PLAN.md` - Detailed implementation plan
- `README.md` - Project overview

---

## 🧪 Testing

### Unit Tests
```bash
npm test
```

### E2E Tests
```bash
# Interactive UI mode
npm run test:e2e:ui

# Headless mode (CI)
npm run test:e2e

# Watch browser
npm run test:e2e:headed
```

### Test Files
- `e2e/navigation.spec.ts` - Navigation tests
- `e2e/dashboard.spec.ts` - Dashboard tests
- `e2e/people.spec.ts` - People management tests

---

## 🔌 API Integration

### Services Available
All auto-generated from OpenAPI:
- `PersonService` - Person CRUD
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
  this.personService.getPersonData('person-id').subscribe(data => {
    console.log(data);
  });
}
```

---

## 🎨 Styling

### Material Theme
Using Angular Material with custom theme. Customize in:
- `src/styles.scss` - Global styles
- Component `.scss` files - Component-specific styles

### Design System
- Primary: Indigo
- Accent: Pink
- Warn: Red
- Background: Light grey (#f5f5f5)

---

## 🐛 Troubleshooting

### Port Already in Use
```bash
# Kill process on port 4200
lsof -ti:4200 | xargs kill -9
```

### Playwright Issues
```bash
# Reinstall browsers
npx playwright install
```

### Clear Angular Cache
```bash
rm -rf .angular
npm start
```

### Module Not Found
```bash
# Clear node_modules and reinstall
rm -rf node_modules package-lock.json
npm install
```

---

## 📚 Learn More

### Angular
- [Angular Docs](https://angular.dev)
- [Angular Material](https://material.angular.io)

### Testing
- [Playwright Docs](https://playwright.dev)

### API
- Check `src/app/client/README.md` for API documentation
- OpenAPI spec should be available from backend

---

## 🤝 Contributing

### Before Submitting PR
1. ✅ Run linter: `ng lint`
2. ✅ Run tests: `npm test && npm run test:e2e`
3. ✅ Update documentation if needed
4. ✅ Follow conventional commits

### Commit Message Format
```
type(scope): subject

body

footer
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`

---

## 🎯 What to Build Next

See `IMPLEMENTATION_PLAN.md` for detailed roadmap. Quick picks:

### Easy Wins (Good First Issues)
1. Add loading spinners to async operations
2. Implement delete confirmation dialog
3. Add toast notifications for success/error
4. Create person detail view tabs

### Medium Complexity
1. Build places list with hierarchy
2. Implement event timeline view
3. Add relationship creation UI
4. Create family tree visualization

### Advanced
1. Real-time collaboration
2. GEDCOM import/export
3. Conflict resolution UI
4. Mobile app with Capacitor

---

## 💡 Tips

- Use lazy loading for better performance
- Add loading states for better UX
- Write tests as you build features
- Keep components small and focused
- Use signals for reactive state
- Leverage Angular Material components

---

## 📞 Get Help

- Check `DEVELOPMENT.md` for detailed docs
- Review existing components for patterns
- Ask in team chat/issues
- Consult Angular docs for framework questions

---

**Happy Coding! 🎉**
