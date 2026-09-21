import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import assert from 'node:assert/strict';
import { me, now, sync, messages } from './fixtures.mjs';

const root=resolve('priv/static');
const server=createServer(async(req,res)=>{try{const url=new URL(req.url,'http://localhost');const file=url.pathname==='/'?'index.html':url.pathname.replace(/^\/assets\//,'');const path=resolve(root,file);if(!path.startsWith(root+'/'))throw Error('path');const bytes=await readFile(path);res.writeHead(200,{'content-type':({'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml'})[extname(path)]||'application/octet-stream'});res.end(bytes);}catch{res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const origin=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE||undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
const errors=[];
await mkdir('test-results',{recursive:true});
async function setup(context) {
 await context.route('**/api/**',route=>{
  const path=new URL(route.request().url()).pathname;
  const data=path==='/api/me'?{user:me,csrf:'test',server_time:now}:path==='/api/sync'?sync:path==='/api/messages'?messages:[];
  return route.fulfill({json:path==='/api/client-config'?{app_name:'Plainwire',version:'2.1.0',registration_enabled:true}:{ok:true,data}});
 });
 await context.routeWebSocket('**/ws',ws=>ws.send(JSON.stringify({type:'hello',session:{user:me}})));
}

try {
 const context=await browser.newContext({viewport:{width:1440,height:960},colorScheme:'dark'});await setup(context);
 const appData={id:1,name:'Test application',public_id:'app_Rura_yH82AmVR1PEhIX_15Nw',public:true,description:'Test description',permissions:[],commands:[],installations:[]};
 await context.route('**/api/developer/**',route=>{const path=new URL(route.request().url()).pathname;return route.fulfill({json:{ok:true,data:path.endsWith('/apps')?[appData]:path.endsWith('/permissions')?[]:appData}})});
 const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin);await page.waitForSelector('.home-welcome');await page.evaluate(()=>location.hash='#settings');await page.waitForSelector('.settings-page');
 for(const width of [1920,1440,1024,800,760,390,320]) {
  await page.setViewportSize({width,height:900});
  for(const section of ['profile','appearance','chat','voice','sound','privacy','account','developer']) {
   if(width>760) await page.locator(`[data-setting="${section}"]`).click();
   else await page.locator('.settings-mobile-nav button').nth(['profile','appearance','chat','voice','sound','privacy','account','developer'].indexOf(section)).click();
   if(section==='developer') {
    await page.waitForSelector('.developer-tabs');
    for(const tab of ['General','Installations','Commands','Interactions','AI assistant']) {
     await page.locator('.developer-tabs').getByRole('button',{name:tab,exact:true}).click();
     await page.waitForTimeout(60);
     const overflow=await page.locator('.developer-panel').evaluate(el=>[el.clientWidth,el.scrollWidth]);
     assert(overflow[1]<=overflow[0]+1,`${width} ${tab} panel overflow: ${overflow}`);
     if(tab==='Commands') await page.screenshot({path:`test-results/settings-responsive-${width}.png`});
    }
   }
   const sizes=await page.locator('.settings-content').evaluate(el=>({client:el.clientWidth,scroll:el.scrollWidth}));
   assert(sizes.scroll<=sizes.client+1,`${width} ${section} settings overflow ${JSON.stringify(sizes)}`);
  }
  if(width>760) {
   const bounds=await page.evaluate(()=>{const p=document.querySelector('.settings-page').getBoundingClientRect(),s=document.querySelector('.settings-sidebar').getBoundingClientRect(),c=document.querySelector('.settings-content').getBoundingClientRect();return [Math.abs(p.left-s.left),Math.abs(p.right-c.right)]});
   assert(bounds.every(n=>n<2),`${width} settings edges ${bounds}`);
  }
 }
 assert.deepEqual(errors,[]);console.log('PASS responsive settings and all developer tabs at seven viewport widths');
} finally { await browser.close();await new Promise(r=>server.close(r)); }
