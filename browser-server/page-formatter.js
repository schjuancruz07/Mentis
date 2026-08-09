'use strict';

async function formatPage(page, maxChars = 2000) {
  const rawText = await page.evaluate(() => (document.body ? document.body.innerText : ''));
  const text = rawText.length > maxChars ? rawText.slice(0, maxChars) + '...' : rawText;

  const handles = await page.$$('a[href], button, input, select, textarea');
  const elements = [];
  const liveHandles = [];
  for (const h of handles) {
    const visible = await h.isVisible().catch(() => false);
    if (!visible) continue;
    const info = await h.evaluate((el) => {
      const tag = el.tagName.toLowerCase();
      let kind = 'link';
      if (tag === 'button') kind = 'button';
      else if (tag === 'input' || tag === 'textarea') kind = 'input';
      else if (tag === 'select') kind = 'select';
      const label = (el.innerText || el.value || el.placeholder || el.getAttribute('aria-label') || '').trim().slice(0, 80);
      const type = el.type || null;
      return { kind, label, type };
    });
    liveHandles.push(h);
    elements.push({ n: liveHandles.length, kind: info.kind, label: info.label, type: info.type });
  }

  return { text, elements, handles: liveHandles };
}

module.exports = { formatPage };
