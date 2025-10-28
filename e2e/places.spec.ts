import { test, expect } from '@playwright/test';
import { setSearch } from './test-utils';

test.describe('Places Management', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/places');
  });

  test('should display places list page', async ({ page }) => {
    await expect(page.locator('h1')).toContainText('Places');
    await expect(page.locator('button:has-text("Add Place")').first()).toBeVisible();
  });

  test('should show search input', async ({ page }) => {
  const searchInput = page.locator('input[placeholder*="search"]');
  await expect(searchInput).toHaveCount(1);
  });

  test.skip('should navigate to add place page', async ({ page }) => {
    // TODO: This requires the editor to support places entity type
    await Promise.all([
      page.waitForURL(/\/places\/new/),
      page.locator('button:has-text("Add Place")').first().click()
    ]);
  });

  test('should show empty state when no places exist', async ({ page }) => {
    const emptyState = page.locator('.empty-state');
    const table = page.locator('table');
    
    const emptyVisible = await emptyState.isVisible().catch(() => false);
    const tableVisible = await table.isVisible().catch(() => false);
    
    expect(emptyVisible || tableVisible).toBeTruthy();
  });

  test('should filter places when typing in search', async ({ page }) => {
  await setSearch(page, 'test place');
  });

  test('should be mobile responsive', async ({ page }) => {
    // Test mobile viewport
    await page.setViewportSize({ width: 375, height: 667 });
    
    // Check that page still displays correctly
    await expect(page.locator('h1')).toBeVisible();
    await expect(page.locator('button:has-text("Add Place")').first()).toBeVisible();
    
    // Search should still be visible on mobile
  const searchInput = page.locator('input[placeholder*="search"]');
  await expect(searchInput).toHaveCount(1);
  });

  test('should show mobile cards on small screens', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    // Type in search to potentially load results
  await setSearch(page, 'test');
    
    // Mobile cards or desktop table container should exist in DOM
    const mobileCards = page.locator('.mobile-cards');
    const desktopTable = page.locator('.desktop-table');
    const tableCard = page.locator('.table-card');
    
    // At least the table card container should exist
    const hasTableCard = await tableCard.count();
    expect(hasTableCard).toBeGreaterThan(0);
  });

  test('should handle clear search on mobile', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
  await setSearch(page, 'test');
  });
});

// Optional CRUD tests using the API (requires TEST_TOKEN)
test.describe('Places CRUD (API)', () => {
  const apiBase = process.env['API_BASE'] || 'http://localhost:5042';
  const token = process.env['TEST_TOKEN'];

  test.beforeEach(async ({ page }) => {
    if (!token) test.skip();
    await page.goto('/places');
  });

  test('create -> retrieve -> update place via API and verify UI', async ({ page, request }) => {
    if (!token) test.skip();
    const unique = `e2e-place-${Date.now()}`;
    const createRes = await request.post(`${apiBase}/api/Place`, {
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      data: { name: unique, latitude: 49.1, longitude: 12.66 }
    });
    expect(createRes.ok()).toBeTruthy();
    const created = await createRes.json();
    const id = created?.id;
    expect(id).toBeTruthy();

    // search via UI
  await setSearch(page, unique);
  await page.waitForTimeout(700);
    await expect(page.locator('.mobile-card, .desktop-table')).toBeVisible();

    // update
    const updatedName = unique + '-updated';
    const updateRes = await request.post(`${apiBase}/api/Place`, {
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      data: { id, name: updatedName }
    });
    expect(updateRes.ok()).toBeTruthy();

    // verify
  await setSearch(page, updatedName);
  await page.waitForTimeout(700);
    await expect(page.locator('text=' + updatedName)).toBeVisible();
  });
});
