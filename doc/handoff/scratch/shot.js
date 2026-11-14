// usage: node shot.js <textfile> <out.png> <caption>
const {chromium}=require('playwright');const fs=require('fs');
(async()=>{const t=fs.readFileSync(process.argv[2],'utf8').replace(/&/g,'&amp;').replace(/</g,'&lt;');
const b=await chromium.launch();const p=await b.newPage({viewport:{width:1100,height:200},deviceScaleFactor:1});
await p.setContent(`<body style="margin:0;background:#111;color:#eee;font:13px monospace"><div style="padding:8px;background:#264;font-weight:bold">${process.argv[4]}</div><pre style="padding:10px;white-space:pre-wrap">${t}</pre></body>`);
await p.screenshot({path:process.argv[3],fullPage:true});await b.close();})();
