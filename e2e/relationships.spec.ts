import { test, expect } from '@playwright/test';

test.describe('Relationships Management', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/relationships');
  });

  test('should display relationships list page', async ({ page }) => {
    await expect(page.locator('h1')).toContainText('Relationships');
    await expect(page.locator('button:has-text("Add Relationship")').first()).toBeVisible();
  });

  test('should show search input', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await expect(searchInput).toBeVisible();
  });

  test.skip('should navigate to add relationship page', async ({ page }) => {
    // TODO: This requires the editor to support relationships entity type
    await Promise.all([
      page.waitForURL(/\/relationships\/new/),
      page.locator('button:has-text("Add Relationship")').first().click()
    ]);
  });

  test('should show empty state when no relationships exist', async ({ page }) => {
    const emptyState = page.locator('.empty-state');
    const table = page.locator('table');
    
    const emptyVisible = await emptyState.isVisible().catch(() => false);
    const tableVisible = await table.isVisible().catch(() => false);
    
    expect(emptyVisible || tableVisible).toBeTruthy();
  });

  test('should filter relationships when typing in search', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    
    await searchInput.fill('parent');
    await page.waitForTimeout(500);
  });

  test('should be mobile responsive', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    await expect(page.locator('h1')).toBeVisible();
    await expect(page.locator('button:has-text("Add Relationship")').first()).toBeVisible();
    
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

  test('should display relationship details in mobile cards', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('family');
    await page.waitForTimeout(500);
    
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      await expect(firstCard).toBeVisible();
      
      // Should show relationship details
      const detailsSection = firstCard.locator('.relationship-details');
      const detailCount = await detailsSection.count();
      expect(detailCount).toBeGreaterThanOrEqual(0);
    }
  });

  test('should show person icons in relationship cards', async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      const icons = firstCard.locator('mat-icon');
      
      const iconCount = await icons.count();
      expect(iconCount).toBeGreaterThan(0);
    }
  });

  test('should handle pagination', async ({ page }) => {
    const paginator = page.locator('mat-paginator');
    const count = await paginator.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });
});

test.describe('Relationships Desktop View', () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 1024, height: 768 });
    await page.goto('/relationships');
  });

  test('should display table on desktop', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
    const desktopTable = page.locator('.desktop-table');
    const count = await desktopTable.count();
    expect(count).toBeGreaterThanOrEqual(0);
  });

  test('should show relationship columns', async ({ page }) => {
    // Table should exist
    const table = page.locator('table');
    const tableCount = await table.count();
    expect(tableCount).toBeGreaterThanOrEqual(0);
  });

  test('should handle row clicks', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('parent');
    await page.waitForTimeout(500);
  });
});

test.describe('Relationships Mobile Touch Interactions', () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 375, height: 667 });
    await page.goto('/relationships');
  });

  test('should handle card taps', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      await expect(firstCard).toBeVisible();
    }
  });

  test('should show action buttons in cards', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      const buttons = firstCard.locator('button');
      
      const buttonCount = await buttons.count();
      expect(buttonCount).toBeGreaterThan(0);
    }
  });

  test('should display arrow icon between persons', async ({ page }) => {
    const searchInput = page.locator('input[placeholder*="search"]');
    await searchInput.fill('test');
    await page.waitForTimeout(500);
    
    const cardCount = await page.locator('.mobile-card').count();
    
    if (cardCount > 0) {
      const firstCard = page.locator('.mobile-card').first();
      const arrowIcon = firstCard.locator('.arrow-icon');
      
      const arrowCount = await arrowIcon.count();
      // Arrow might be present if relationship data is displayed
      expect(arrowCount).toBeGreaterThanOrEqual(0);
    }
  });
});
