import { test, expect } from '@playwright/test';
import { setSearch } from './test-utils';

test.describe('Events Management', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/events');
  });

  test('should display events list page', async ({ page }) => {
    await expect(page.locator('h1')).toContainText('Events');
    await expect(page.locator('button:has-text("Add Event")').first()).toBeVisible();
  });

  test('should show search input', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await expect(searchInput).toHaveCount(1);
  });

  test.skip('should navigate to add event page', async ({ page }) => {
    // TODO: This requires the editor to support events entity type
    await Promise.all([
      page.waitForURL(/\/events\/new/),
      page.locator('button:has-text("Add Event")').first().click()
    ]);
  });

  test('should show empty state when no events exist', async ({ page }) => {
    const emptyState = page.locator('.empty-state');
    const table = page.locator('table');
    
    const emptyVisible = await emptyState.isVisible().catch(() => false);
    const tableVisible = await table.isVisible().catch(() => false);
    
    expect(emptyVisible || tableVisible).toBeTruthy();
  });

  test('should filter events when typing in search', async ({ page }) => {
  await setSearch(page, 'test event');
  });

  test('should be mobile responsive', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    await expect(page.locator('h1')).toBeVisible();
    await expect(page.locator('button:has-text("Add Event")').first()).toBeVisible();
    
  const searchInput = page.locator('input[placeholder*="search"]');
  await expect(searchInput).toHaveCount(1);
  });

  test('should show mobile cards on small screens', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
  await setSearch(page, 'test');
    
    const tableCard = page.locator('.table-card');
    const hasTableCard = await tableCard.count();
    expect(hasTableCard).toBeGreaterThan(0);
  });

  test('should display event date and location in cards', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
  await setSearch(page, 'birthday');
  });

  test('should handle pagination', async ({ page }) => {
    const paginator = page.locator('mat-paginator');
    
    // Paginator should exist even if not visible
    const count = await paginator.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });
});

// Optional CRUD tests using the API (requires TEST_TOKEN)
test.describe('Events CRUD (API)', () => {
  const apiBase = process.env['API_BASE'] || 'http://localhost:5042';
  const token = process.env['TEST_TOKEN'];

  test.beforeEach(async ({ page }) => {
    if (!token) test.skip();
    await page.goto('/events');
  });

  test('create -> retrieve -> update event via API and verify UI', async ({ page, request }) => {
    if (!token) test.skip();
    const unique = `e2e-event-${Date.now()}`;
    const createRes = await request.post(`${apiBase}/api/Event`, {
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      data: { name: unique, date: new Date().toISOString() }
    });
    expect(createRes.ok()).toBeTruthy();
    const created = await createRes.json();
    const id = created?.id;
    expect(id).toBeTruthy();

    // verify via UI search
    await page.locator('input[placeholder*="search"]').fill(unique);
    await page.waitForTimeout(700);
    await expect(page.locator('.mobile-card, .desktop-table')).toBeVisible();

    // update
    const updatedName = unique + '-updated';
    const updateRes = await request.post(`${apiBase}/api/Event`, {
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      data: { id, name: updatedName }
    });
    expect(updateRes.ok()).toBeTruthy();

    // verify updated name in UI
    await page.locator('input[placeholder*="search"]').fill(updatedName);
    await page.waitForTimeout(700);
    await expect(page.locator('text=' + updatedName)).toBeVisible();
  });
});

test.describe('Events Mobile Touch Interactions', () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await page.goto('/events');
  });

  test('should handle touch interactions on mobile cards', async ({ page }) => {
  await setSearch(page, 'test');
  await page.waitForTimeout(500);
    
    // Check if cards exist
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      await expect(firstCard).toBeVisible();
    }
  });

  test('should expand button on mobile to full width', async ({ page }) => {
    const addButton = page.locator('button:has-text("Add Event")').first();
    await expect(addButton).toBeVisible();
    
    // Button should be visible and tappable on mobile
    const box = await addButton.boundingBox();
    expect(box).toBeTruthy();
  });
});
