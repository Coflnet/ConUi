import { Page } from '@playwright/test';

export async function setSearch(page: Page, text: string) {
  const selector = 'input[placeholder*="search"]';
  const locator = page.locator(selector).first();
  // If input is visible and editable, use normal fill
  try {
    // try a quick fill; if element is not visible this will timeout fast
    await locator.fill(text, { timeout: 500 });
    return;
  } catch (e) {
    // fallback to DOM manipulation when element is not interactable in headless envs
    await page.evaluate(({ sel, val }: { sel: string; val: string }) => {
      const el = document.querySelector(sel) as HTMLInputElement | null;
      if (!el) return;
      (el as HTMLInputElement).focus?.();
      (el as HTMLInputElement).value = val;
      el.dispatchEvent(new Event('input', { bubbles: true }));
    }, { sel: selector, val: text });
  }
  // small pause to let Angular react
  await page.waitForTimeout(250);
}
