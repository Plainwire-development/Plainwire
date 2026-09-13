import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import assert from 'node:assert/strict';
import { me, now, sync, messages, message, conversations, servers, people } from './fixtures.mjs';

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
let inviteOptions;
let inviteRevoked = false;
const sockets=[];
const subscriptions=[];
let messageFetches=0;
let testServer = { ...servers[0], role: 'owner', welcome_message: 'Welcome to **The Workshop**. Read the rules and say hello.' };
const serverData = () => ({server:testServer, channels:[{id:1,server_id:1,name:'general',kind:'text',position:0,topic:'',created_at:now}],categories:[],members:people.map(user=>({user,role:user.id===1?'owner':'member',muted:false,joined_at:now}))});
messages.push(message(8, 'Here is the change:\n\n```erlang\nhello(Name) -> {ok, Name}.\n```\n\n**Ready to review.** [Notes](https://example.com/notes)\n\n> Keep it simple.\n\n| Task | Status |\n| --- | --- |\n| Audio | Passed |'));
async function setup(context){
 await context.route('**/api/**',async route=>{
  const req=route.request(), url=new URL(req.url()), path=url.pathname;
  const reply=(data,status=200)=>route.fulfill({status,contentType:'application/json',body:JSON.stringify({ok:status<400,data,...(status===401?{error:'not_authenticated'}:{})})});
  if(path==='/api/client-config')return route.fulfill({json:{app_name:'Plainwire',default_theme:'system',version:'1.7.1',asset_version:'1.7.1',registration_enabled:true,instance_description:'A private place for everyday conversations.'}});
  if(path==='/api/me')return authenticated?reply({user:me,csrf:'test-csrf',server_time:now}):reply(null,401);
  if(path==='/api/sync')return reply(sync);
  if(path==='/api/forums')return reply([]);
  if(path==='/api/server/1/invites' && req.method()==='GET')return reply([{code:'test-link',max_uses:10,uses:2,expires_at:now+86400000,created_at:now,revoked:inviteRevoked}]);
  if(path==='/api/server/1/invites' && req.method()==='POST'){inviteOptions=req.postDataJSON();return reply({code:'new-link',url:'#invite/new-link',expires_at:now+3600000});}
  if(path==='/api/server/1/invites/test-link' && req.method()==='DELETE'){inviteRevoked=true;return reply({});}
  if(path==='/api/server/1'){if(req.method()==='POST')testServer={...testServer,...req.postDataJSON()};return reply(serverData());}
  if(path==='/api/messages'){messageFetches++;return reply(url.searchParams.get('scope_id')==='1'?messages:[]);}
  if(/^\/api\/conversation\/\d+\/messages$/.test(path)){
   if(failNext){failNext=false;return route.fulfill({status:503,json:{ok:false,error:'database_busy'}});}
   const cid=Number(path.split('/')[3]);const mid=100+delayed.length;delayed.push(()=>reply(message(mid,req.postDataJSON().body,cid,me)));return;
  }
  if(/^\/api\/conversation\/\d+$/.test(path)){const c=conversations.find(c=>c.id===Number(path.split('/').pop()));return reply({conversation:c,members:c?.members||[]});}
  if(path==='/api/rtc-config')return reply({iceServers:[]});
  if(path==='/api/voice-processing-config')return reply({krisp_available:false});
  return reply({});
 });
 await context.routeWebSocket('**/ws', ws=>{sockets.push(ws);ws.onMessage(raw=>{const msg=JSON.parse(raw);if(msg.type==='subscribe')subscriptions.push(msg.key);if(msg.type==='ping')ws.send(JSON.stringify({type:'pong'}));});ws.send(JSON.stringify({type:'hello',session:{user:me}}));});
}
try {
 const context=await browser.newContext({viewport:{width:1440,height:960},colorScheme:'light'});await setup(context);
 const page=await context.newPage();page.on('pageerror',e=>errors.push(e.message));
 await page.goto(origin);await page.waitForSelector('.home-welcome');
 await page.screenshot({path:'test-results/home-desktop.png'});
 await page.evaluate(()=>location.hash='#dm/1');await page.waitForSelector('#compose');await page.waitForSelector('.msg');
 await page.waitForSelector('.code-block .hljs-title');
 assert.equal(await page.locator('.code-block .code-heading span').first().textContent(),'erlang');
 assert(await page.locator('.msg-body strong').count()>0);
 assert.equal(await page.locator('.markdown-table table').count(),1);
 assert.equal(await page.locator('a[href="https://example.com/notes"]').getAttribute('rel'),'noopener noreferrer ugc');
 await page.evaluate(()=>{
  const el=document.createElement('pw-markdown'); el.id='markdown-security-fixture'; el.setAttribute('source','<img src=x onerror="window.__xss=1">\n<script>window.__xss=1</script>\n[bad](javascript:alert(1))\n![remote](https://tracker.example/pixel)\n\n```unknownlang\n<script>alert(1)</script>\n```'); document.body.append(el);
 });
 assert.equal(await page.locator('#markdown-security-fixture script, #markdown-security-fixture img, #markdown-security-fixture a[href^="javascript:"]').count(),0);
 assert.equal(await page.evaluate(()=>window.__xss),undefined);
 assert(await page.evaluate(()=>window.PlainwireHighlight.listLanguages().length)>180);
 await page.locator('#markdown-security-fixture').evaluate(el=>el.remove());
 await page.locator('#compose').fill(Array(75).fill('Long message with a new line.').join('\n'));
 await page.waitForTimeout(50);
 const composeMetrics=await page.locator('#compose').evaluate(el=>({scroll:el.scrollHeight,height:el.clientHeight,overflow:getComputedStyle(el).overflowY,style:el.getAttribute('style')}));
 assert(composeMetrics.scroll>composeMetrics.height&&composeMetrics.overflow==='auto'&&composeMetrics.height<=180,JSON.stringify(composeMetrics));
 for (const viewport of [{width:1440,height:960},{width:390,height:540}]) {
  await page.setViewportSize(viewport);
  await page.getByLabel('Message formatting',{exact:true}).click();
  await page.waitForTimeout(80);
  const closeBox=await page.getByRole('button',{name:'Close formatting',exact:true}).boundingBox();
  assert(closeBox&&closeBox.y>=0&&closeBox.y+closeBox.height<=viewport.height,'formatting close remains reachable with a long draft');
  const panel=await page.locator('.compose-format-panel').boundingBox();
  assert(panel.x>=0&&panel.x+panel.width<=viewport.width&&panel.y>=0&&panel.y+panel.height<=viewport.height,JSON.stringify({message:'formatting stays inside viewport',panel,viewport}));
  await page.getByRole('button',{name:'Close formatting',exact:true}).click();
  assert.equal(await page.locator('.compose-format-help[open]').count(),0);
  await page.getByLabel('Message formatting',{exact:true}).click();await page.keyboard.press('Escape');
  assert.equal(await page.locator('.compose-format-help[open]').count(),0);
  await page.getByLabel('Message formatting',{exact:true}).click();await page.locator('#compose').click();
  assert.equal(await page.locator('.compose-format-help[open]').count(),0);
 }
 await page.setViewportSize({width:1440,height:960});
 await page.locator('#compose').fill('Selected words');
 await page.locator('#compose').evaluate(el=>el.setSelectionRange(0,8));
 await page.getByLabel('Message formatting',{exact:true}).click();
 await page.getByRole('button',{name:'Bold',exact:true}).click();
 assert.equal(await page.locator('#compose').inputValue(),'**Selected** words');
 await page.waitForSelector('.compose-preview strong');
 await page.screenshot({path:'test-results/composer-formatting.png'});
 await page.getByRole('button',{name:'Close formatting',exact:true}).click();
 await page.locator('#compose').fill('Draft with composition');
 await page.locator('#compose').dispatchEvent('keydown',{key:'Enter',isComposing:true,ctrlKey:false,metaKey:false,shiftKey:false});
 assert.equal(delayed.length,0,'IME confirmation must not send a message');
 await page.locator('#compose').fill('');
 await page.locator('#compose').fill('Draft survives reconnect');
 const oldSockets=sockets.length, oldSubscriptions=subscriptions.length, oldFetches=messageFetches;
 sockets.at(-1).close({code:1012,reason:'Test restart'});
 await page.waitForTimeout(1800);
 assert(sockets.length>oldSockets,'WebSocket reconnects');
 assert(subscriptions.slice(oldSubscriptions).includes('direct:1'),'current room subscription is restored');
 assert(messageFetches>oldFetches,'missed messages are fetched after reconnect');
 assert.equal(await page.locator('#compose').inputValue(),'Draft survives reconnect');
 await page.locator('#compose').fill('');
 await page.screenshot({path:'test-results/chat-desktop.png'});
 await page.locator('#compose').fill('Draft for Jamie');await page.evaluate(()=>location.hash='#dm/2');await page.waitForFunction(()=>document.querySelector('.chat-header h2')?.textContent==='Sam Rivera');assert.equal(await page.locator('#compose').inputValue(),'');
 await page.locator('#compose').fill('Draft for Sam');await page.evaluate(()=>location.hash='#dm/1');await page.waitForFunction(()=>document.querySelector('#compose')?.value==='Draft for Jamie');
 await page.locator('#compose').fill('**First in flight**');await page.locator('.composer-send').click();
 await page.waitForSelector('.msg.pending .msg-body strong');
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
 await page.getByRole('searchbox',{name:'Find a setting'}).fill('microphone');
 await page.locator('.settings-search-results button').click(); await page.waitForSelector('.voice-settings');
 assert.equal(await page.getByRole('searchbox',{name:'Find a setting'}).inputValue(),'');
 await page.screenshot({path:'test-results/settings-voice.png'});
 await page.evaluate(()=>location.hash='#server/1');await page.waitForSelector('.server-welcome strong');
 assert.equal(await page.locator('.channel-glyph.text').first().evaluate(el=>getComputedStyle(el,'::after').content),'none');
 assert.equal(await page.locator('.channel-glyph.text').first().evaluate(el=>getComputedStyle(el).backgroundImage),'none');
 await page.screenshot({path:'test-results/server-channels.png'});
 await page.getByRole('button',{name:'Customize',exact:true}).click();
 await page.getByPlaceholder('A welcome note, a few rules, or where to start. Markdown is supported.').fill('## Start here\nBe kind. Share what you are working on.');
 await page.waitForSelector('.server-customize-preview h2');await page.screenshot({path:'test-results/server-customize.png'});
 await page.getByRole('button',{name:'Save server',exact:true}).click();await page.waitForSelector('.server-welcome h2');
 await page.getByRole('button',{name:'Invite people',exact:true}).click();await page.waitForSelector('.invite-link-row');
 await page.getByRole('button',{name:'Revoke',exact:true}).click();await page.getByText('Revoked link',{exact:true}).waitFor();assert.equal(inviteRevoked,true);
 await page.getByRole('combobox',{name:'Invite expiration'}).selectOption('3600');
 await page.getByRole('button',{name:'One use',exact:true}).click();await page.screenshot({path:'test-results/invites-desktop.png'});
 await page.getByRole('button',{name:'Copy invite',exact:true}).click();await page.waitForTimeout(100);
 assert.equal(inviteOptions.expires_in,3600);assert.equal(inviteOptions.max_uses,1);
 assert.equal(await page.locator('.invite-code-input').inputValue(),`${origin}/#invite/new-link`);
 await page.keyboard.press('Escape');
 await page.waitForFunction(()=>!document.querySelector('.modal'));
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
 assert.deepEqual(errors,[],'no browser exceptions');console.log('PASS: Markdown and syntax highlighting; unsafe markup rejection; long composer scrolling; settings search; welcome preview; invite expiry/revocation; desktop/light/dark/mobile layouts; drafts across routes; concurrent sends out of order; new draft preserved; late send isolated; failed send/retry; sign-in; no runtime exceptions.');
} finally {await browser.close();server.close();}
