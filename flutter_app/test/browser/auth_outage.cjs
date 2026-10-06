// Run against a locally served build. Provider/API requests are synthetic fixtures only.
const {chromium}=require(process.env.PLAYWRIGHT_MODULE||'@playwright/test');
const fs=require('node:fs'), path=require('node:path');
const base=process.env.AUTH_TEST_BASE||'http://127.0.0.1:4372';
if(!['127.0.0.1','localhost','::1'].includes(new URL(base).hostname))throw Error('Only loopback test builds are permitted');
const output=process.env.AUTH_TEST_OUTPUT||'/tmp/con-auth-outage';fs.mkdirSync(output,{recursive:true});
let activeBrowser;
(async()=>{
 const browser=activeBrowser=await chromium.launch({executablePath:process.env.PLAYWRIGHT_CHROMIUM||'/usr/bin/chromium',headless:true,args:['--no-sandbox']});
 const results=[];
 await Promise.all(['de-DE','en-GB'].flatMap(locale=>[390,1440].map(async width=>{
  const context=await browser.newContext({locale,viewport:{width:width/2,height:475},deviceScaleFactor:2});
  await context.route('**/*',route=>new URL(route.request().url()).origin===new URL(base).origin?route.continue():route.abort());
  const page=await context.newPage(); let posts=0, start;
  await page.addInitScript(()=>{
   localStorage.setItem('flutter.user_id',JSON.stringify('retained-profile'));
   localStorage.setItem('flutter.encryption_salt',JSON.stringify('retained-salt'));
  });
  await page.route('**/protocol/openid-connect/token',route=>{start=Date.now();return route.fulfill({json:{access_token:'synthetic-review-access'}})});
  await page.route('**/api/**',route=>{
   const path=new URL(route.request().url()).pathname;
   if(path==='/api/auth/config')return route.fulfill({json:{enabled:true,issuer:'https://app.rfind.de/auth/realms/con',clientId:'con-app'}});
   if(path==='/api/auth/oidc'){posts++;return new Promise(()=>{});}
   return route.fulfill({json:[]});
  });
  await page.addInitScript(()=>sessionStorage.setItem('con.oidc',JSON.stringify({issuer:'https://app.rfind.de/auth/realms/con',clientId:'con-app',verifier:'synthetic-review-verifier',state:'synthetic-review-state',redirect:location.origin+'/',created:Date.now()})));
  await page.goto(base+'/?code=synthetic-one-use&state=synthetic-review-state');
  await page.locator('flt-semantics-placeholder').waitFor({timeout:15000});
  await page.locator('flt-semantics-placeholder').evaluate(el=>el.click());
  // Flutter canvas reflow: half CSS viewport + DPR2 models 200% browser zoom.
  const notice=page.getByText(locale.startsWith('de')?'Anmeldung vorübergehend nicht verfügbar':'Account sign-in is temporarily unavailable',{exact:false});
  await notice.waitFor({timeout:12000});
  if(!start||Date.now()-start>10000)throw Error('Con outage exceeded UI budget');
  if(posts!==1)throw Error('Con token/API request replay detected');
  const snapshot=await page.evaluate(()=>({id:localStorage.getItem('flutter.user_id'),salt:localStorage.getItem('flutter.encryption_salt'),token:localStorage.getItem('flutter.auth_token'),pending:sessionStorage.getItem('con.oidc'),query:location.search,overflow:document.documentElement.scrollWidth>innerWidth}));
  if(snapshot.id!==JSON.stringify('retained-profile')||snapshot.salt!==JSON.stringify('retained-salt')||snapshot.token!==null||snapshot.pending!==null||snapshot.query!=='')throw Error('Con mutated retained profile or callback state');
  await page.mouse.move(width/4,400);
  await page.mouse.wheel(0,1500);
  await page.waitForTimeout(300);
  const noticeBox=await notice.boundingBox();
  if(!noticeBox||noticeBox.y<0||noticeBox.y+noticeBox.height>475)throw Error('Con notice not visible after scrolling');
  await page.screenshot({path:path.join(output,`${locale}-${width}.png`),fullPage:true});
  results.push({app:'Con',locale,width,zoom:200,notice:true,oneRequest:true,profilePreserved:true,overflow:snapshot.overflow});
  await context.close();
 })));
 await browser.close();
 fs.writeFileSync(path.join(output,'results.json'),JSON.stringify(results,null,2));
 console.log(JSON.stringify(results));
})().catch(async e=>{console.error(e.stack);await activeBrowser?.close();process.exit(1)});
