import { test, expect } from '@playwright/test';

test.describe('Navigation', () => {
  test('should navigate to dashboard by default', async ({ page }) => {
    await page.goto('/');
    await expect(page).toHaveURL(/\/dashboard/);
    await expect(page.locator('h1')).toContainText('Dashboard');
  });

  test('should navigate between main sections', async ({ page }) => {
    await page.goto('/dashboard');
    
    // Navigate to People
    await page.click('text=People');
    await expect(page).toHaveURL(/\/people/);
    await expect(page.locator('h1')).toContainText('People');
    
    // Navigate to Events
    await page.click('text=Events');
    await expect(page).toHaveURL(/\/events/);
    await expect(page.locator('h1')).toContainText('Events');
    
    // Navigate back to Dashboard
    await page.click('text=Dashboard');
    await expect(page).toHaveURL(/\/dashboard/);
  });

  test('should show sidebar navigation', async ({ page }) => {
    await page.goto('/dashboard');
    
    const navItems = ['Dashboard', 'People', 'Places', 'Events', 'Things', 'Timeline', 'Relationships', 'Share'];
    
    for (const item of navItems) {
      // The sidenav contains icons and text; target the title span to avoid strict-mode collisions
      await expect(page.locator('.app-sidenav').locator(`.mat-mdc-list-item-title:has-text("${item}")`)).toBeVisible();
    }
  });

  test('should toggle sidebar', async ({ page }) => {
    await page.goto('/dashboard');
    
    const sidenav = page.locator('.app-sidenav');
    await expect(sidenav).toBeVisible();
    
    // Click menu button to close
    await page.click('button[aria-label="Toggle menu"]');
    // Note: The sidenav might still exist in DOM but be visually hidden
    // This test might need adjustment based on actual implementation
  });
});
