const { chromium } = require('/opt/node-tools/node_modules/playwright');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1243/chrome-linux64/chrome', args: ['--no-sandbox','--ignore-certificate-errors'] });
  const p = await b.newPage({ viewport: { width: 420, height: 900 } });
  await p.goto('http://127.0.0.1:8090/');
  await p.waitForTimeout(6000);
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await p.waitForTimeout(1000);
  await p.fill('input[aria-label="エンドポイント"]', 'https://127.0.0.1:8792');
  await p.fill('input[aria-label="アクセストークン"]', 'live-token');
  await p.getByText('接続する', { exact: true }).last().click();
  await p.waitForTimeout(4000);
  const dump = async (n) => { console.log(n, JSON.stringify(await p.evaluate(() => [...document.querySelectorAll('flt-semantics')].map(e => (e.getAttribute('aria-label') || e.textContent || '').slice(0, 40)).filter(Boolean).slice(0, 40)))); await p.screenshot({ path: `/home/user/notes/work115/web-${n}.png` }); };
  await dump('after-connect');
  await b.close();
})();
