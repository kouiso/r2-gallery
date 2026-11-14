const { chromium } = require('/opt/node-tools/node_modules/playwright');
(async () => {
  const b = await chromium.launch({ executablePath: '/opt/pw-browsers/chromium-1243/chrome-linux64/chrome', args: ['--no-sandbox'] });
  const p = await b.newPage({ viewport: { width: 420, height: 900 } });
  p.on('console', m => console.log('CONSOLE', m.text().slice(0, 200)));
  await p.goto('http://127.0.0.1:8090/');
  await p.waitForTimeout(6000);
  await p.evaluate(() => document.querySelector('flt-semantics-placeholder')?.click());
  await p.waitForTimeout(1500);
  console.log(await p.evaluate(() => document.body.innerText.slice(0, 600)));
  console.log(await p.evaluate(() => [...document.querySelectorAll('input,textarea')].map(i => i.outerHTML.slice(0,160))));
  await p.screenshot({ path: '/home/user/notes/work115/web1.png' });
  await b.close();
})();
