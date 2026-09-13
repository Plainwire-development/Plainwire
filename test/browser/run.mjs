import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import assert from 'node:assert/strict';
import { me, now, sync, messages, message, conversations } from './fixtures.mjs';

const root=resolve('priv/static');
const server=createServer(async(req,res)=>{try{const url=new URL(req.url,'http://localhost');const file=url.pathname==='/'?'index.html':url.pathname.replace(/^\/assets\//,'');const path=resolve(root,file);if(!path.startsWith(root+'/'))throw Error('path');const bytes=await readFile(path);res.writeHead(200,{'content-type':({'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml'})[extname(path)]||'application/octet-stream'});res.end(bytes);}catch{res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const origin=`http://127.0.0.1:${server.address().port}`;
const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE||undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
const errors=[];
await mkdir('test-results',{recursive:true});
let authenticated=true;
let delayed=[];
let failNext=false;
async function setup(context){
 await context.route('**/api/**',async route=>{
  const req=route.request(), url=new URL(req.url()), path=url.pathname;
  const reply=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify({ok:status<400,data,...(status===401?{error:'not_authenticated'}:{})})});
  if(path==='/api/client-config')return route.fulfill({json:{app_name:'Plainwire',default_theme:'system',version:'1.6.0',asset_version:'1.6.0',registration_enabled:true,instance_description:'A private place for everyday conversations.'}});
  if(path==='/api/me')return authenticated?reply({user:me,csrf:'test-csrf',server_time:now}):reply(null,401);
  if(path==='/api/sync')return reply(sync);
  if(path==='/api/forums')return reply([]);
  if(path==='/api/messages')return reply(url.searchParams.get('scope_id')==='1'?messages:[]);
  if(/^\/api\/conversation\/\d+\/messages$/.test(path)){
   if(failNext){failNext=false;return route.fulfill({status:503,json:{ok:false,error:'database_busy'}});}
   const cid=Number(path.split('/')[3]);const mid=100+delayed.length;delayed.push(()=>reply(message(mid,req.postDataJSON().body,cid,me)));return;
  }
  if(/^\/api\/conversation\/\d+$/.test(path)){const c=conversations.find(c=>c.id===Number(path.split('/').pop()));return reply({conversation:c,members:c?.members||[]});}
  if(path==='/api/rtc-config')return reply({iceServers:[]});
  if(path==='/api/voice-processing-config')return reply({krisp_available:false});
  return reply({});
 });
 await context.routeWebSocket('**/ws', ws=>{ws.onMessage(raw=>{const msg=JSON.parse(raw);if(msg.type==='ping')ws.send(JSON.stringify({type:'pong'}));});ws.send(JSON.stringify({type:'hello',session:{user:me}}));});
}
try {
 const context=await browser.newContext({viewport:{width:1440,height:960},colorScheme:'light'});await setup(context);
 const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin);await page.waitForSelector('.home-welcome');
 await page.screenshot({path:'test-results/home-desktop.png'});
 await page.evaluate(()=>location.hash='#dm/1');await page.waitForSelector('#compose');await page.waitForSelector('.msg');
 await page.screenshot({path:'test-results/chat-desktop.png'});
 await page.locator('#compose').fill('Draft for Jamie');await page.evaluate(()=>location.hash='#dm/2');await page.waitForFunction(()=>document.querySelector('.chat-header h2')?.textContent==='Sam Rivera');assert.equal(await page.locator('#compose').inputValue(),'');
 await page.locator('#compose').fill('Draft for Sam');await page.evaluate(()=>location.hash='#dm/1');await page.waitForFunction(()=>document.querySelector('#compose')?.value==='Draft for Jamie');
 await page.locator('#compose').fill('First in flight');await page.locator('.composer-send').click();
 await page.locator('#compose').fill('Second in flight');await page.locator('.composer-send').click();
 await page.locator('#compose').fill('Keep this new draft');await page.waitForFunction(()=>document.querySelectorAll('.msg.pending').length===2);
 assert.equal(delayed.length,2);await delayed[1]();await page.waitForFunction(()=>document.querySelectorAll('.msg.pending').length===1);assert.equal(await page.locator('#compose').inputValue(),'Keep this new draft');
 await page.evaluate(()=>location.hash='#dm/2');await page.waitForFunction(()=>document.querySelector('.chat-header h2')?.textContent==='Sam Rivera');await delayed[0]();await page.waitForTimeout(100);
 assert.equal(await page.locator('#compose').inputValue(),'Draft for Sam');assert.equal(await page.locator('.msg').count(),0,'late response must not leak into another chat');
 delayed=[];
 failNext=true;await page.locator('#compose').fill('Retry me');await page.locator('.composer-send').click();await page.waitForSelector('.msg.failed');
 await page.getByRole('button',{name:'Retry',exact:true}).click();await page.waitForTimeout(50);assert.equal(delayed.length,1);await delayed[0]();await page.waitForFunction(()=>!document.querySelector('.msg.pending, .msg.failed'));
 if(await page.locator('.toast-close').count())await page.locator('.toast-close').click();
 await page.evaluate(()=>location.hash='#settings');await page.waitForSelector('.settings-page');await page.screenshot({path:'test-results/settings-desktop.png'});
 await page.emulateMedia({colorScheme:'dark'});await page.evaluate(()=>location.hash='#dm/1');await page.waitForSelector('.msg');await page.screenshot({path:'test-results/chat-dark.png'});
 for (const width of [360,390,768]) {
  await page.setViewportSize({width,height:844});await page.waitForTimeout(100);
  assert.equal(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth),true,`no page overflow at ${width}`);
  const box=await page.locator('#compose').boundingBox();assert(box&&box.x>=0&&box.x+box.width<=width&&box.y+box.height<=844,`composer reachable at ${width}`);
  const sendBox = await page.locator('.composer-send').boundingBox();
  const navBox = await page.locator('.mobile-nav').boundingBox();
  assert(sendBox && sendBox.y + sendBox.height <= (navBox?.height ? navBox.y : 844), `send button is not covered at ${width}`);
  if(await page.locator('.toast-close').count())await page.locator('.toast-close').click();
  await page.screenshot({path:`test-results/chat-${width}.png`});
 }
 authenticated=false;const auth=await browser.newContext({viewport:{width:1440,height:960},colorScheme:'light'});await setup(auth);const login=await auth.newPage();login.on('pageerror',e=>errors.push(e.message));await login.goto(origin);await login.waitForSelector('.auth-submit');await login.screenshot({path:'test-results/login-desktop.png'});await login.setViewportSize({width:390,height:844});await login.screenshot({path:'test-results/login-mobile.png'});
 const blocked=await browser.newContext();await setup(blocked);await blocked.addInitScript(()=>Object.defineProperty(window,'localStorage',{get(){throw new DOMException('Storage blocked','SecurityError')}}));const blockedPage=await blocked.newPage();blockedPage.on('pageerror',e=>errors.push(e.message));await blockedPage.goto(origin);await blockedPage.waitForSelector('.auth-submit');
 assert.deepEqual(errors,[],'no browser exceptions');console.log('PASS: desktop/light/dark/mobile layouts; drafts across routes; concurrent sends out of order; new draft preserved; late send isolated; failed send/retry; sign-in; no runtime exceptions.');
} finally {await browser.close();server.close();}
