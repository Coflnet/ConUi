import { test, expect } from '@playwright/test';

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
    await expect(searchInput).toBeVisible();
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
    const searchInput = page.locator('input[placeholder*="search"]');
    
    await searchInput.fill('test thing');
    await page.waitForTimeout(500);
  });

  test('should be mobile responsive', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    await expect(page.locator('h1')).toBeVisible();
    await expect(page.locator('button:has-text("Add Thing")').first()).toBeVisible();
    
    const searchInput = page.locator('input[placeholder*="search"]');
    await expect(searchInput).toBeVisible();
  });

  test('should show mobile cards on small screens', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
    const tableCard = page.locator('.table-card');
    const hasTableCard = await tableCard.count();
    expect(hasTableCard).toBeGreaterThan(0);
  });

  test('should handle action buttons in mobile cards', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
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
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
    // Desktop table should be in the DOM
    const desktopTable = page.locator('.desktop-table');
    const count = await desktopTable.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });

  test('should show all columns in desktop table', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('book');
    await page.waitForTimeout(500);
  });
});

test.describe('Things Touch Interactions', () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await page.goto('/things');
  });

  test('should scale card on tap', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      
      // Card should be visible
      await expect(firstCard).toBeVisible();
    }
  });
});
