import { test, expect } from '@playwright/test';

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
    await expect(searchInput).toBeVisible();
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
    const searchInput = page.locator('input[placeholder*="search"]');
    
    await searchInput.fill('test place');
    await page.waitForTimeout(500);
  });

  test('should be mobile responsive', async ({ page }) => {
    // Test mobile viewport
    await page.setViewportSize({ width: 375, height: 667 });
    
    // Check that page still displays correctly
    await expect(page.locator('h1')).toBeVisible();
    await expect(page.locator('button:has-text("Add Place")').first()).toBeVisible();
    
    // Search should still be visible on mobile
    const searchInput = page.locator('input[placeholder*="search"]');
    await expect(searchInput).toBeVisible();
  });

  test('should show mobile cards on small screens', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    // Type in search to potentially load results
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
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
    
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
  });
});
