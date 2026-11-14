const { chromium } = require('/opt/node-tools/node_modules/playwright');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1243/chrome-linux64/chrome', args: ['--no-sandbox','--ignore-certificate-errors'] });
  const p = await b.newPage({ viewport: { width: 420, height: 900 } });
  await p.goto('http://127.0.0.1:8090/');
  await p.waitForTimeout(6000);
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await p.waitForTimeout(1000);
  await p.click('input[aria-label="エンドポイント"]'); await p.keyboard.type('https://127.0.0.1:8792', {delay: 5});
  await p.click('input[aria-label="アクセストークン"]'); await p.keyboard.type('live-token', {delay: 5}); await p.waitForTimeout(500);
  await p.getByText('接続する', { exact: true }).last().click();
  await p.waitForTimeout(9000);
  const dump = async (n) => { console.log(n, JSON.stringify(await p.evaluate(() => [...document.querySelectorAll('flt-semantics')].map(e => (e.getAttribute('aria-label') || e.textContent || '').slice(0, 40)).filter(Boolean).slice(0, 40)))); await p.screenshot({ path: `/home/user/notes/work115/web-${n}.png` }); };
  await p.mouse.click(52,865); await p.waitForTimeout(3000); await dump('photos');
  
  const files = require('fs').readdirSync('/home/user/notes/work115/photos').map(f => '/home/user/notes/work115/photos/' + f);
  const [fc] = await Promise.all([p.waitForEvent('filechooser', {timeout: 20000}), p.mouse.click(210, 552)]);
  console.log('multiple?', fc.isMultiple());
  const t0 = Date.now();
  await fc.setFiles(files);
  await p.waitForTimeout(15000);
  await dump('confirm');
  console.log('TEXT', JSON.stringify(await p.evaluate(() => [...document.querySelectorAll('flt-semantics')].map(e => (e.textContent||'').slice(0,60)).filter(Boolean).slice(-12))));

  p.on('console', m => { const t = m.text(); if (!/GL Driver|Injecting/.test(t)) console.log('CONSOLE', t.slice(0,200)); });
  p.on('requestfailed', r => console.log('REQFAIL', r.method(), r.url().slice(0,100), r.failure()?.errorText));
  p.on('response', r => { if (r.status() >= 400) console.log('HTTP', r.status(), r.request().method(), r.url().slice(0,100)); });
  await p.getByText('アップロード', {exact: true}).last().click({force: true});
  const s0 = Date.now();
  for (let i = 0; i < 24; i++) { await p.waitForTimeout(5000); const txt = await p.evaluate(() => [...document.querySelectorAll('flt-semantics')].map(e => (e.textContent||'').slice(0,40)).filter(Boolean).filter(x => /転送|件|失敗|エラー|完了|待機|アップロード/.test(x)).slice(0,6)); console.log((Date.now()-s0)/1000, JSON.stringify(txt)); await p.screenshot({path:`/home/user/notes/work115/web-up-${i}.png`}); }
  await b.close();
})();
