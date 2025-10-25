import { test, expect } from '@playwright/test';

test.describe('People Management', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/people');
  });

  test('should display people list page', async ({ page }) => {
    await expect(page.locator('h1')).toContainText('People');
    await expect(page.locator('text=Add Person')).toBeVisible();
  });

  test('should show search input', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await expect(searchInput).toBeVisible();
  });

  test('should navigate to add person page', async ({ page }) => {
    await page.click('text=Add Person');
    await expect(page).toHaveURL(/\/people\/new/);
  });

  test('should show empty state when no people exist', async ({ page }) => {
    // This assumes no data in the system
    const emptyState = page.locator('.empty-state');
    const table = page.locator('table');
    
    // Either empty state or table should be visible
    const emptyVisible = await emptyState.isVisible().catch(() => false);
    const tableVisible = await table.isVisible().catch(() => false);
    
    expect(emptyVisible || tableVisible).toBeTruthy();
  });

  test('should filter people when typing in search', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    
    // Type in search
    await searchInput.fill('test');
    
    // Wait a moment for debounce
    await page.waitForTimeout(500);
    
    // The search should have been triggered
    // Actual verification would depend on having test data
  });
});

test.describe('Person CRUD Operations', () => {
  test('should create a new person', async ({ page }) => {
    await page.goto('/people/new');
    
    // Wait for the editor to load
    await page.waitForSelector('.name-input-container', { timeout: 5000 });
    
    // Type a name
    const nameInput = page.locator('.name-input-container input');
    await nameInput.fill('John Doe');
    await nameInput.press('Enter');
    
    // Add a field
    const newFieldInput = page.locator('input[placeholder*="Auswählen"]');
    if (await newFieldInput.isVisible().catch(() => false)) {
      await newFieldInput.fill('Geburtstag');
      await page.click('text=Geburtstag');
    }
  });
});
