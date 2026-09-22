import { chromium } from 'playwright';
import { createServer } from 'node:http';
import { readFile, mkdir } from 'node:fs/promises';
import { resolve, extname } from 'node:path';
import assert from 'node:assert/strict';

const root=resolve('priv/admin');
const server=createServer(async(req,res)=>{try{const url=new URL(req.url,'http://localhost');const file=url.pathname==='/'?'index.html':url.pathname.replace(/^\//,'');const path=resolve(root,file);if(!path.startsWith(root+'/')&&path!==root+'/index.html')throw Error('path');const bytes=await readFile(path);res.writeHead(200,{'content-type':({'.html':'text/html','.js':'text/javascript','.css':'text/css','.svg':'image/svg+xml'})[extname(path)]||'application/octet-stream'});res.end(bytes);}catch{res.writeHead(404);res.end();}});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const origin=`http://127.0.0.1:${server.address().port}`;
await mkdir('test-results',{recursive:true});

const posts=[];
let accountState='active';
const user={id:7,username:'ada',display_name:'Ada Lovelace',is_bot:false,account_state:'active',created_at:Date.now()-86400000,updated_at:Date.now(),last_seen:Date.now(),disabled_at:0,email_set:true,email_verified:false,server_count:2,owned_server_count:1,conversation_count:3,message_count:40,upload_count:1,upload_bytes:1024,active_sessions:1};
const json=(data,status=200)=>({status,contentType:'application/json',body:JSON.stringify({ok:status<400,data,...(status>=400?{error:'failed'}:{})})});
const moderation=()=>({account_state:accountState,moderation:accountState==='active'?null:{title:accountState==='banned'?'Access revoked':'Account suspended',reason:'policy',severity:accountState==='banned'?'critical':'warning',expires_at:0}});

const browser=await chromium.launch({headless:true,executablePath:process.env.CHROMIUM_EXECUTABLE||undefined,args:['--no-sandbox','--disable-dev-shm-usage']});
const errors=[];
try {
  const context=await browser.newContext();
  await context.route('**/api/**',async route=>{
    const req=route.request(), url=new URL(req.url()), path=url.pathname, method=req.method();
    if(method!=='GET'){
      let body={};try{body=req.postDataJSON()||{};}catch{body={};}
      posts.push({path,method,body,csrf:req.headers()['x-csrf-token']||''});
    }
    if(path==='/api/status')return route.fulfill(json({instance_id:'test',bootstrap_available:false,recovery_available:false}));
    if(path==='/api/me')return route.fulfill(json({username:'owner',display_name:'Owner',role:'owner',csrf:'csrf-test',instance_id:'test',user_id:1}));
    if(path==='/api/overview')return route.fulfill(json({users:1,active_users_24h:1,servers:1,channels:1,messages:1,messages_24h:1,upload_bytes:1024,ready_uploads:1,active_sessions:1,admin_sessions:1,runtime:{uptime_ms:1000,otp_release:'27',realtime:{available:true,online_users:1,websocket_connections:1,call_participants:0,voice_participants:0,call_rooms:0,voice_rooms:0},database:{available:true,pool_size:4},native_media_quality:{available:false},turn:{},cluster:{backend:'local'}}}));
    if(path==='/api/users' && method==='GET')return route.fulfill(json([{...user,account_state:accountState}]));
    if(path==='/api/users/7' && method==='GET')return route.fulfill(json({...user,account_state:accountState}));
    if(path==='/api/users/7/moderation' && method==='GET')return route.fulfill(json(moderation()));
    if(path==='/api/users/7/moderation/history')return route.fulfill(json([]));
    if(path==='/api/users/7/moderation' && method==='POST'){
      const action=String(route.request().postDataJSON()?.action||'');
      if(action==='restore')accountState='active';
      else if(action==='ban')accountState='banned';
      else if(action==='suspend')accountState='suspended';
      else if(action==='disable')accountState='disabled';
      return route.fulfill(json({...moderation(),changed:action==='clear_display_name',revoked:action==='revoke_sessions'?1:0,removed:action==='remove_email',sent:action==='resend_verification',email_delivery:action==='resend_verification'}));
    }
    if(path==='/api/banners' && method==='GET')return route.fulfill(json([]));
    if(path==='/api/banners' && method==='POST')return route.fulfill(json({id:1,title:'',body:'hello',severity:'info',enabled:true,dismissible:true,starts_at:Date.now(),ends_at:0,updated_at:Date.now()}));
    if(path==='/api/controls')return route.fulfill(json({registration_mode:'inherit',registration_enabled:true}));
    if(path==='/api/controls/registration')return route.fulfill(json({registration_mode:'enabled',registration_enabled:true}));
    if(path==='/api/controls/reconcile')return route.fulfill(json({}));
    return route.fulfill(json({}));
  });
  const page=await context.newPage();
  page.on('pageerror',e=>errors.push(e.message));
  await page.goto(origin);
  await page.locator('#app').waitFor({state:'visible'});

  await page.locator('[data-view="users"]').click();
  await page.locator('tr[data-clickable="true"]').click();
  await page.getByRole('button',{name:'Ban',exact:true}).click();
  await page.locator('#account-moderation-form input[name="reason"]').fill('spam');
  await page.getByRole('button',{name:'Ban account'}).click();
  await page.locator('.toast',{hasText:'Account banned'}).waitFor();
  const ban=posts.find(p=>p.path==='/api/users/7/moderation'&&p.body.action==='ban');
  assert.ok(ban,'Ban account must POST /api/users/:id/moderation');
  assert.equal(ban.body.reason,'spam');
  assert.equal(ban.csrf,'csrf-test');

  await page.getByRole('button',{name:'Restore access'}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Restore access'}).click();
  await page.locator('.toast',{hasText:'Account access restored'}).waitFor();
  const restore=posts.find(p=>p.path==='/api/users/7/moderation'&&p.body.action==='restore');
  assert.ok(restore,'Restore access must POST /api/users/:id/moderation');

  await page.getByRole('button',{name:'Suspend',exact:true}).click();
  await page.locator('#account-moderation-form input[name="reason"]').fill('cooldown');
  await page.getByRole('button',{name:'Suspend account'}).click();
  await page.locator('.toast',{hasText:'Account suspended'}).waitFor();
  const suspend=posts.find(p=>p.path==='/api/users/7/moderation'&&p.body.action==='suspend');
  assert.ok(suspend,'Suspend account must POST /api/users/:id/moderation');
  assert.equal(suspend.body.reason,'cooldown');

  await page.getByRole('button',{name:'Disable',exact:true}).click();
  await page.locator('#account-moderation-form input[name="reason"]').fill('operator hold');
  await page.getByRole('button',{name:'Disable account'}).click();
  await page.locator('.toast',{hasText:'Account disabled'}).waitFor();
  const disable=posts.find(p=>p.path==='/api/users/7/moderation'&&p.body.action==='disable');
  assert.ok(disable,'Disable account must POST /api/users/:id/moderation');
  assert.equal(disable.body.reason,'operator hold');
  assert.equal(disable.csrf,'csrf-test');

  await page.getByRole('button',{name:'Sign out everywhere',exact:true}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Sign out everywhere'}).click();
  await page.locator('.toast',{hasText:'Sessions revoked'}).waitFor();
  assert.ok(posts.some(p=>p.path==='/api/users/7/moderation'&&p.body.action==='revoke_sessions'),'Sign out everywhere must revoke sessions');

  await page.getByRole('button',{name:'Reset display name'}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Reset display name'}).click();
  await page.locator('.toast',{hasText:'Display name reset'}).waitFor();
  assert.ok(posts.some(p=>p.path==='/api/users/7/moderation'&&p.body.action==='clear_display_name'),'Reset display name must POST');

  await page.getByRole('button',{name:'Remove email'}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Remove email'}).click();
  await page.locator('.toast',{hasText:'Email removed'}).waitFor();
  assert.ok(posts.some(p=>p.path==='/api/users/7/moderation'&&p.body.action==='remove_email'),'Remove email must POST');

  await page.getByRole('button',{name:'Resend verification'}).click();
  await page.getByRole('dialog').getByRole('button',{name:'Resend verification'}).click();
  await page.locator('.toast',{hasText:'Verification email sent'}).waitFor();
  assert.ok(posts.some(p=>p.path==='/api/users/7/moderation'&&p.body.action==='resend_verification'),'Resend verification must POST');

  await page.locator('#modal-close').click();
  await page.locator('[data-view="control"]').click();
  await page.getByRole('button',{name:'Reconcile clients'}).click();
  await page.locator('.toast',{hasText:'Connected clients were asked to reconcile'}).waitFor();
  assert.ok(posts.some(p=>p.path==='/api/controls/reconcile'),'Reconcile clients must POST');

  await page.getByRole('button',{name:'Apply'}).click();
  await page.locator('.toast',{hasText:'Registration enabled'}).waitFor();
  assert.ok(posts.some(p=>p.path==='/api/controls/registration'),'Registration Apply must POST');

  await page.getByRole('button',{name:'New global banner'}).click();
  await page.locator('#banner-editor-form textarea[name="body"]').fill('Scheduled maintenance');
  await page.getByRole('button',{name:'Publish banner'}).click();
  await page.locator('.toast',{hasText:'Banner published'}).waitFor();
  assert.ok(posts.some(p=>p.path==='/api/banners'&&p.method==='POST'),'Publish banner must POST');

  assert.deepEqual(errors,[]);
  console.log('PASS: control-plane ban/suspend/disable/restore, session revoke, profile and email actions, reconcile, registration, and banner actions send API requests');
} finally {
  await browser.close();
  await new Promise(r=>server.close(r));
}
