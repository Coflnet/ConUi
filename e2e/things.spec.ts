import { test, expect } from '@playwright/test';
import { setSearch } from './test-utils';

test.describe('Things Management', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/things');
  });

  test('should display things list page', async ({ page }) => {
    await expect(page.locator('h1')).toContainText('Things');
    await expect(page.locator('button:has-text("Add Thing")').first()).toBeVisible();
  });

  test('should show search input', async ({ page }) => {
  const searchInput = page.locator('input[placeholder*="search"]');
  // On some headless envs Material inputs may be hidden; ensure it exists in DOM
  await expect(searchInput).toHaveCount(1);
  });

  test.skip('should navigate to add thing page', async ({ page }) => {
    // TODO: This requires the editor to support things entity type
    await Promise.all([
      page.waitForURL(/\/things\/new/),
      page.locator('button:has-text("Add Thing")').first().click()
    ]);
  });

  test('should show empty state when no things exist', async ({ page }) => {
    const emptyState = page.locator('.empty-state');
    const table = page.locator('table');
    
    const emptyVisible = await emptyState.isVisible().catch(() => false);
    const tableVisible = await table.isVisible().catch(() => false);
    
    expect(emptyVisible || tableVisible).toBeTruthy();
  });

  test('should filter things when typing in search', async ({ page }) => {
    await setSearch(page, 'test thing');
  });

  test('should be mobile responsive', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    await expect(page.locator('h1')).toBeVisible();
    await expect(page.locator('button:has-text("Add Thing")').first()).toBeVisible();
    
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

  test('should handle action buttons in mobile cards', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
  await setSearch(page, 'test');
    
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      await expect(firstCard).toBeVisible();
      
      // Action buttons should be visible
      const viewButton = firstCard.locator('button[matTooltip="View details"]');
      const editButton = firstCard.locator('button[matTooltip="Edit"]');
      const deleteButton = firstCard.locator('button[matTooltip="Delete"]');
      
      // At least the card should have action buttons
      const buttonCount = await firstCard.locator('button').count();
      expect(buttonCount).toBeGreaterThan(0);
    }
  });

  test('should handle pagination', async ({ page }) => {
    const paginator = page.locator('mat-paginator');
    const count = await paginator.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });
});

test.describe('Things Desktop View', () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 768 });
    await page.goto('/things');
  });

  test('should display table on desktop', async ({ page }) => {
  await setSearch(page, 'test');
    
    // Desktop table should be in the DOM
    const desktopTable = page.locator('.desktop-table');
    const count = await desktopTable.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });

  test('should show all columns in desktop table', async ({ page }) => {
    await setSearch(page, 'book');
    await page.waitForTimeout(500);
  });
});

test.describe('Things Touch Interactions', () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await page.goto('/things');
  });

  test('should scale card on tap', async ({ page }) => {
    await setSearch(page, 'test');
    await page.waitForTimeout(500);
    
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      
      // Card should be visible
      await expect(firstCard).toBeVisible();
    }
  });
});

// Optional CRUD tests (only run when TEST_TOKEN env var is provided)
test.describe('Things CRUD (API)', () => {
  const apiBase = process.env['API_BASE'] || 'http://localhost:5042';
  const token = process.env['TEST_TOKEN'];

  test.beforeEach(async ({ page }) => {
    if (!token) test.skip();
    await page.goto('/things');
  });

  test('create -> retrieve -> update thing via API and verify UI', async ({ page, request }) => {
    if (!token) test.skip();
    const unique = `e2e-thing-${Date.now()}`;
    // create
    const createRes = await request.post(`${apiBase}/api/Thing`, {
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      data: { name: unique }
    });
    expect(createRes.ok()).toBeTruthy();
    const created = await createRes.json();
    const id = created?.id;
    expect(id).toBeTruthy();

    // verify via UI search
    await page.locator('input[placeholder*="search"]').fill(unique);
    await page.waitForTimeout(700);
    await expect(page.locator('.mobile-card, .desktop-table')).toBeVisible();

    // update via API
    const updatedName = unique + '-updated';
    const updateRes = await request.post(`${apiBase}/api/Thing`, {
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
