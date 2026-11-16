const {chromium}=require('playwright');
(async()=>{
 const b=await chromium.launch({args:['--disable-dev-shm-usage','--no-sandbox','--use-gl=angle','--use-angle=swiftshader','--enable-unsafe-swiftshader']});
 // design
 const dp=await b.newPage({viewport:{width:390,height:844}});
 await dp.goto('http://localhost:8099/Main.dc.html'); await dp.waitForTimeout(1500);
 await dp.screenshot({path:'/tmp/c1a-design.png'});
 // product
 const ctx=await b.newContext({viewport:{width:390,height:844},deviceScaleFactor:1,hasTouch:true,isMobile:true,userAgent:'Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Mobile Safari/537.36'});
 const p=await ctx.newPage();
 await p.goto('http://localhost:8098/'); await p.waitForTimeout(9000);
 await p.screenshot({path:'/tmp/c1a-product.png'});
 await b.close();
})();
