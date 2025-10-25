import { test, expect } from '@playwright/test';

test.describe('Dashboard', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/dashboard');
  });

  test('should display dashboard with stats cards', async ({ page }) => {
    await expect(page.locator('h1')).toContainText('Dashboard');
    
    const stats = ['People', 'Places', 'Events', 'Things'];
    
    for (const stat of stats) {
      await expect(page.locator(`.stat-card:has-text("${stat}")`)).toBeVisible();
    }
  });

  test('should show quick actions', async ({ page }) => {
    await expect(page.locator('text=Quick Actions')).toBeVisible();
    
    const actions = ['Add Person', 'Add Event', 'Add Place', 'Add Thing'];
    
    for (const action of actions) {
      await expect(page.locator(`button:has-text("${action}")`)).toBeVisible();
    }
  });

  test('should navigate when clicking stat cards', async ({ page }) => {
    await page.click('.stat-card:has-text("People")');
    await expect(page).toHaveURL(/\/people/);
  });

  test('should navigate when clicking quick actions', async ({ page }) => {
    await page.click('button:has-text("Add Person")');
    await expect(page).toHaveURL(/\/people\/new/);
  });

  test('should show recent activity section', async ({ page }) => {
    await expect(page.locator('text=Recent Activity')).toBeVisible();
  });
});
