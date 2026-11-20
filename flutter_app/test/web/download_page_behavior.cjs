'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const pageScript = process.argv[2];
const id = '15bd1547-cae0-4b5e-9662-2f24b2ef6e89';
class Element {
  constructor() {
    this.listeners = {}; this.attributes = {}; this.children = [];
    this.disabled = false; this.hidden = false; this.checked = false;
    this.classes = new Set();
    this.classList = {add: c => this.classes.add(c), remove: c => this.classes.delete(c), toggle: (c,v) => v ? this.classes.add(c) : this.classes.delete(c)};
    this.textContent = '';
  }
  set textContent(value) { this.text = value; this.textContentWrites = (this.textContentWrites || 0) + 1; if (this.children) this.children.length = 0; }
  get textContent() { return this.text; }
  set innerHTML(_) { throw Error('Never insert filenames as markup'); }
  addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
  emit(t,e={}) { return Promise.all((this.listeners[t] || []).map(f => f(e))); }
  appendChild(n) { n.remove(); n.parentElement = this; this.children.push(n); return n; }
  insertBefore(n, ref) { if(n===ref) return n; n.remove(); n.parentElement = this; const i=this.children.indexOf(ref); this.children.splice(i<0?this.children.length:i,0,n); return n; }
  remove() { if(this.parentElement) { const doc=this.ownerDocument, active=doc?.activeElement; for(let n=active;n;n=n.parentElement) if(n===this) { doc.activeElement=doc.body; break; } const a=this.parentElement.children, i=a.indexOf(this); if(i>=0) a.splice(i,1); this.parentElement=null; } }
  get lastElementChild() { return this.children.at(-1); }
  get isConnected() { let n=this; while(n.parentElement) n=n.parentElement; return n.isDocumentRoot===true; }
  querySelector(q) { return this.querySelectorAll(q)[0] || null; }
  querySelectorAll(q) { return this.children.flatMap(c=>[...(q[0]==='.' && (c.className||'').split(' ').includes(q.slice(1)) || q[0]==='#' && c.id===q.slice(1) ? [c] : []), ...c.querySelectorAll(q)]); }
  setAttribute(k,v) { this.attributes[k] = v; }
  getAttribute(k) { return this.attributes[k]; }
  removeAttribute(k) { delete this.attributes[k]; if(k==='src') delete this.src; }
  focus() { this.focused = true; if(this.ownerDocument) this.ownerDocument.activeElement=this; }
  showModal() { this.open = true; }
  close() { this.open = false; this.emit('close'); }
  pause() { this.paused = true; }
  load() { this.loaded = true; }
}
function setup(options={}) {
  const elements = {};
  for (const name of ['theme-toggle','download-toast','upload-files','upload-button','upload-panel','upload-list','upload-summary','upload-recovery-warning','select-all','zip-download','zip-cancel','selection-count','preview-dialog','preview-media','preview-status','preview-close','preview-title','file-list-announcement','file-list','download-heading','file-count','file-total','page-title']) elements[name] = new Element();
  elements['selection-count'].textContent='已选 0 个';
  elements['zip-download'].href='/download.zip';
  elements['zip-cancel'].hidden=true;
  elements['upload-panel'].appendChild(elements['upload-summary']);
  elements['upload-panel'].appendChild(elements['upload-recovery-warning']);
  const selection = new Element(), label = new Element(); selection.appendChild(label); label.appendChild(elements['select-all']);
  elements['upload-button'].disabled = true;
  const checks = options.empty ? [] : [new Element(), new Element()]; if(checks.length) { checks[0].value=id; checks[1].value='25bd1547-cae0-4b5e-9662-2f24b2ef6e89'; }
  const preview = new Element(); preview.setAttribute('data-id',id); preview.setAttribute('data-kind','video'); preview.setAttribute('data-name','a.mp4'); preview.setAttribute('aria-label','预览 a.mp4');
  const requests = [], fetches = [], replies = [], navigations = [];
  class XHR extends Element {
    constructor() { super(); this.upload = new Element(); this.headers={}; requests.push(this); }
    open(method,url) { if(options.throwOpen) throw Error('open'); this.method=method; this.url=url; }
    setRequestHeader(k,v) { this.headers[k]=v; }
    send(body) { if(options.throwSend) throw Error('send'); this.body=body; }
    abort() { this.aborted = true; this.emit('abort'); }
  }
  // Parse only the generated file-card subtree to exercise hydration too.
  if(options.html) {
    const decode=s=>s.replace(/&(?:amp|lt|gt|quot|#39|#\d+);/g,e=>({'&amp;':'&','&lt;':'<','&gt;':'>','&quot;':'"','&#39;':"'"}[e] ?? String.fromCharCode(Number(e.slice(2,-1)))));
    for(const match of options.html.matchAll(/<div class="file-card [\s\S]*?<\/div><\/div>/g)) {
      const stack=[elements['file-list']];
      for(const token of match[0].matchAll(/<([^>]+)>|([^<]+)/g)) {
        if(token[2]) { if(token[2].trim()) { const e=stack.at(-1); e.textContent+=decode(token[2]); } continue; }
        if(token[1][0]==='/') { stack.pop(); continue; }
        const tag=token[1].split(' ')[0], e=new Element(); e.tag=tag;
        for(const attr of token[1].matchAll(/([\w-]+)="([^"]*)"/g)) {
          const k=attr[1], v=decode(attr[2]); e.setAttribute(k,v);
          if(k==='class') e.className=v; else if(['id','value','type','href'].includes(k)) e[k]=v;
        }
        stack.at(-1).appendChild(e);
        if(tag!=='input') stack.push(e);
      }
    }
  }
  const documentEvents = {}, windowEvents = {}, timers = new Map(), themeListeners = [], beacons = [];
  const storage = options.sessionStorage || new Map();
  const sessionStorage = {
    getItem:key=>{ if(options.sessionStorageThrows) throw Error('storage blocked'); return storage.has(key)?storage.get(key):null; },
    setItem:(key,value)=>{ if(options.sessionStorageThrows) throw Error('storage blocked'); storage.set(key,String(value)); },
    removeItem:key=>{ if(options.sessionStorageThrows) throw Error('storage blocked'); storage.delete(key); }
  };
  let nextTimer=0;
  const body = new Element(); Object.values(elements).filter(e=>!e.parentElement).forEach(e=>body.appendChild(e)); body.appendChild(preview);
  const document = {documentElement:new Element(),body,visibilityState:'visible',activeElement:null,
    addEventListener:(t,f)=>(documentEvents[t] ||= []).push(f),
    getElementById:n=>elements[n] || body.querySelector('#'+n),
    createElement:tag=>{const e=new Element(); e.tag=tag; e.ownerDocument=document; return e;},
    querySelectorAll:q=>q==='.file-select'?[...checks,...elements['file-list'].querySelectorAll(q)]:q==='.preview-button'?[preview,...elements['file-list'].querySelectorAll(q)]:q==='.download-arrow, #zip-download'?[elements['zip-download']]:body.querySelectorAll(q)};
  body.isDocumentRoot=true; const attachDocument=n=>{ n.ownerDocument=document; n.children.forEach(attachDocument); }; attachDocument(body);
  const window = {AbortController:options.noAbortController ? undefined : AbortController,crypto:options.noCrypto ? undefined : options.useGetRandomValues ? {getRandomValues:bytes=>{bytes.fill(0);return bytes;}} : {randomUUID:()=>options.zipTokens ? options.zipTokens.shift() : options.zipToken||'35bd1547-cae0-4b5e-9662-2f24b2ef6e89'},location:{assign:url=>navigations.push(url)},navigator:{sendBeacon:(url,body)=>{beacons.push({url,body}); options.onBeacon?.(url,body); return options.beaconResult!==false;}},addEventListener:(t,f)=>(windowEvents[t] ||= []).push(f),matchMedia:q=>({matches:q.includes('reduced-motion') || !!options.dark && q.includes('color-scheme'),addEventListener:(t,f)=>themeListeners.push(f)}),
    setTimeout:(fn,ms)=>{if(ms===2000 || ms===8000 || ms===120000){const id=++nextTimer;timers.set(id,{fn,ms});return id;}fn();return ++nextTimer;},clearTimeout:id=>timers.delete(id),requestAnimationFrame:fn=>fn()};
  Object.defineProperty(window,'sessionStorage',{get:()=>{if(options.sessionStorageGetterThrows) throw Error('storage blocked'); return sessionStorage;}});
  const fetch = (url,init={}) => { fetches.push({url,...init}); return new Promise((resolve,reject)=>{ const reply={resolve,reject}; replies.push(reply); if(init.signal) { const abort=()=>{const index=replies.indexOf(reply); if(index>=0) replies.splice(index,1); const error=Error('aborted'); error.name='AbortError'; reject(error);}; if(init.signal.aborted) abort(); else init.signal.addEventListener('abort',abort,{once:true}); } }); };
  new Function('document','window','XMLHttpRequest','fetch',options.pageScript || pageScript)(document,window,options.XMLHttpRequest || XHR,options.fetch || fetch);
  return {elements,checks,preview,requests,fetches,replies,document,timers,themeListeners,beacons,navigations,storage,sessionStorage,
    async pagehide() { await Promise.all((windowEvents.pagehide||[]).map(f=>f())); await tick(); },
    async poll() { const first=[...timers.entries()].find(([,timer])=>timer.ms===2000); assert.ok(first,'manifest timer scheduled'); timers.delete(first[0]); await first[1].fn(); },
    async timeoutManifest() { const first=[...timers.entries()].find(([,timer])=>timer.ms===8000); assert.ok(first,'manifest deadline scheduled'); timers.delete(first[0]); first[1].fn(); await tick(); },
    async timeoutControl() { const first=[...timers.entries()].find(([,timer])=>timer.ms===120000); assert.ok(first,'control deadline scheduled'); timers.delete(first[0]); first[1].fn(); await tick(); },
     async visibility(value) { document.visibilityState=value; await Promise.all((documentEvents.visibilitychange||[]).map(f=>f())); await tick(); },
    rows:elements['upload-list'].children,
    picker:elements['upload-files'],button:elements['upload-button'],summary:elements['upload-summary'],
    async choose(files) { this.picker.files=files; await this.picker.emit('change'); },
    async reply(status,body) { const r=replies.shift(); assert.ok(r,'expected fetch'); r.resolve({status,json:async()=>{ if (body instanceof Error) throw body; return body; }}); await tick(); },
    async reject() { replies.shift().reject(Error('offline')); await tick(); }
  };
}
async function tick() { for(let i=0;i<20;i++) await Promise.resolve(); }
function file(name='x',size=1,lastModified=123) {
  return {name,size,lastModified,slice(start,end) { const n=Math.min(size,end??size)-start; return {size:n,arrayBuffer:async()=>new Uint8Array(n).fill(97).buffer}; }};
}
const state = row=>row.attributes['data-state'];
const status = row=>row.children[1].textContent;
const progress = row=>row.children[2];
const cancel = row=>row.children[3].children[0];
async function response(xhr,code,body) { xhr.status=code; xhr.responseText=typeof body==='string'?body:JSON.stringify(body); await xhr.emit('load'); await tick(); }
async function start(app,f=file()) { await app.choose([f]); const done=app.button.emit('click'); await tick(); return {done}; }
async function created(app,size=1,offset=0) { await app.reply(201,{id,size,offset}); }
async function complete(app,size=1,name='saved') { await app.reply(201,{name,size}); }
async function checks() {
  const app=setup(), first=file('</script><img src=x> 空格 &?#%.txt',4194305);
  await app.choose([first,file('empty',0)]);
  assert.equal(app.rows[0].children[0].textContent,first.name);
  const cancelName0=app.rows[0].children[3].children[0].getAttribute('aria-label');
  const cancelName1=app.rows[1].children[3].children[0].getAttribute('aria-label');
  assert.equal(cancelName0,'取消上传 '+first.name); assert.equal(cancelName1,'取消上传 empty'); assert.notEqual(cancelName0,cancelName1);
  assert.equal(app.requests.length+app.fetches.length,0,'selection never auto-uploads');
  const done=app.button.emit('click'); await tick();
  assert.equal(app.picker.disabled,true); assert.equal(app.button.disabled,true);
  await app.button.emit('click'); assert.equal(app.fetches.length,1,'no double-click queue');
  const chunkHashes=[];
  for(let offset=0;offset<first.size;offset+=4*1024*1024) chunkHashes.push(crypto.createHash('sha256').update(Buffer.alloc(Math.min(4*1024*1024,first.size-offset),97)).digest('hex'));
  const expected=crypto.createHash('sha256').update(JSON.stringify([first.name,first.size,first.lastModified,chunkHashes])).digest('hex');
  assert.equal(app.fetches[0].url,'/uploads?name='+encodeURIComponent(first.name)+'&size='+first.size+'&fingerprint='+expected);
  const collisionFile=value=>{ const bytes=Buffer.alloc(131073,97); bytes[65536]=value; return {name:'same.bin',size:bytes.length,lastModified:123,slice(start,end){const part=Uint8Array.from(bytes.subarray(start,end));return {arrayBuffer:async()=>part.buffer};}}; };
  const collisionA=setup(), collisionB=setup();
  const collisionDoneA=await start(collisionA,collisionFile(97)); const fingerprintA=collisionA.fetches[0].url;
  await created(collisionA,131073); await collisionA.requests[0].emit('error'); await collisionDoneA.done;
  const collisionDoneB=await start(collisionB,collisionFile(98)); const fingerprintB=collisionB.fetches[0].url;
  assert.notEqual(fingerprintA,fingerprintB,'interior byte differences cannot collide when samples match');
  await created(collisionB,131073); await collisionB.requests[0].emit('error'); await collisionDoneB.done;
  await created(app,first.size);
  const xhr=app.requests[0];
  assert.equal(xhr.method,'PATCH'); assert.equal(xhr.url,'/uploads/'+id+'?offset=0'); assert.equal(xhr.body.size,4194304);
  assert.deepEqual(xhr.headers,{'Content-Type':'application/octet-stream'});
  const activeRow=app.rows[0], activeSummary=app.summary.textContent;
  const pollDuringUpload=app.poll(); await tick();
  await app.reply(200,{title:'同步传输',files:[{id,name:'new.png',size:2,previewKind:'image'}]}); await pollDuringUpload;
  assert.equal(app.rows[0],activeRow); assert.equal(app.summary.textContent,activeSummary);
  assert.equal(app.picker.disabled,true); assert.equal(app.requests[0],xhr); assert.notEqual(xhr.aborted,true);
  await xhr.upload.emit('progress',{lengthComputable:true,loaded:2097152,total:4194304});
  assert.ok(progress(app.rows[0]).value>49 && progress(app.rows[0]).value<50);
  assert.match(status(app.rows[0]),/MiB\/s.*剩余约/);
  await xhr.upload.emit('progress',{lengthComputable:false});
  await response(xhr,200,{id,size:first.size,offset:4194304});
  assert.equal(app.requests.length,2,'one sequential chunk at a time');
  assert.equal(app.requests[1].url,'/uploads/'+id+'?offset=4194304'); assert.equal(app.requests[1].body.size,1);
  await response(app.requests[1],200,{id,size:first.size,offset:first.size});
  assert.equal(state(app.rows[0]),'uploading','sent does not mean saved');
  assert.equal(app.fetches.at(-1).url,'/uploads/'+id+'/complete');
  assert.equal(cancel(app.rows[0]).disabled,true,'cannot cancel after completion request begins');
  await cancel(app.rows[0]).emit('click');
  assert.equal(state(app.rows[0]),'uploading'); assert.match(status(app.rows[0]),/此阶段无法取消/);
  assert.equal(app.fetches.some(request=>request.method==='DELETE'),false,'completed files are never reported as cancelled or cleaned');
  await complete(app,first.size,'<img onerror=evil()>');
  assert.equal(state(app.rows[0]),'success'); assert.ok(status(app.rows[0]).endsWith('<img onerror=evil()>'));
  assert.equal(app.fetches.at(-1).method,'POST'); await created(app,0); // empty file has no PATCH
  assert.equal(app.requests.length,2); await complete(app,0); await done;
  assert.match(app.summary.textContent,/成功 2 个/); assert.equal(app.picker.disabled,false); assert.equal(app.picker.value,'');
  assert.equal(app.elements['upload-panel'].getAttribute('aria-busy'),undefined,'live upload announcements are not hidden under a busy ancestor');

  const hashing=setup(); let releaseHash;
  const slowFile={name:'slow.bin',size:1,lastModified:123,slice(){return {arrayBuffer:()=>new Promise(resolve=>releaseHash=resolve)}}};
  const hashingDone=await start(hashing,slowFile);
  assert.equal(status(hashing.rows[0]),'正在校验完整文件内容…');
  assert.equal(progress(hashing.rows[0]).getAttribute('aria-label'),'slow.bin 文件校验进度');
  releaseHash(new Uint8Array([97]).buffer); await tick(); await created(hashing,1);
  await hashing.requests[0].emit('error'); await hashingDone.done;
  const cancelHash=setup(); let releaseCancelledHash;
  const pendingFile={name:'cancel-hash.bin',size:1,lastModified:123,slice(){return {arrayBuffer:()=>new Promise(resolve=>releaseCancelledHash=resolve)}}};
  const cancelHashDone=await start(cancelHash,pendingFile);
  const cancelling=cancel(cancelHash.rows[0]).emit('click'); await tick();
  assert.equal(state(cancelHash.rows[0]),'cancelling');
  releaseCancelledHash(new Uint8Array([97]).buffer); await cancelling; await cancelHashDone.done;
  assert.equal(state(cancelHash.rows[0]),'cancelled'); assert.equal(cancelHash.fetches.length,0,'cancel during hashing creates no server session');
  const over=setup(); await over.choose([file('big',1073741825)]); assert.equal(over.button.disabled,true); assert.equal(state(over.rows[0]),'error');
  const limit=setup(), syntheticMax=file('max',1073741824); syntheticMax.slice=()=>({arrayBuffer:async()=>new ArrayBuffer(0)});
  await limit.choose([syntheticMax]); const limitDone=limit.button.emit('click');
  for(let i=0;i<600 && !limit.fetches.length;i++) await Promise.resolve();
  await created(limit,1073741824,1073741824); await complete(limit,1073741824); await limitDone;
  assert.equal(state(limit.rows[0]),'success','exact size limit remains uploadable');
  const empty=setup(); await empty.choose([]); await empty.button.emit('click'); assert.equal(empty.fetches.length,0);

  // 409 must query authoritative status; never trust or rewind to a 409 body.
  const conflict=setup(); const cd=await start(conflict,file('large',10)); await created(conflict,10,2);
  await response(conflict.requests[0],409,{offset:0}); assert.equal(conflict.fetches.at(-1).method,'GET');
  await conflict.reply(200,{id,size:10,offset:6}); assert.equal(conflict.requests[1].url,'/uploads/'+id+'?offset=6');
  await conflict.requests[1].emit('error'); await cd.done;
  assert.equal(state(conflict.rows[0]),'paused'); assert.equal(conflict.button.textContent,'继续上传');
  assert.equal(progress(conflict.rows[0]).value,60); assert.equal(conflict.fetches.some(r=>r.method==='DELETE'),false);
  const resumed=conflict.button.emit('click'); await tick(); assert.equal(conflict.fetches.at(-1).method,'GET');
  await conflict.reply(200,{id,size:10,offset:8}); assert.equal(conflict.requests[2].url,'/uploads/'+id+'?offset=8');
  await response(conflict.requests[2],200,{id,size:10,offset:10}); await complete(conflict,10); await resumed;
  assert.equal(state(conflict.rows[0]),'success');
  await conflict.requests[1].upload.emit('progress',{lengthComputable:true,loaded:4,total:4}); assert.equal(state(conflict.rows[0]),'success','late events ignored');

  const backwards=setup(); const bd=await start(backwards,file('x',10)); await created(backwards,10,6); await response(backwards.requests[0],409,{}); await backwards.reply(200,{id,size:10,offset:2}); await bd.done;
  assert.equal(state(backwards.rows[0]),'paused'); assert.equal(progress(backwards.rows[0]).value,60,'never rewind confirmed offset');

  // New selection of the same file has a stable fingerprint and reuses server offset.
  const reselect=setup(); const rd=await start(reselect,file('x',10)); const firstUrl=reselect.fetches[0].url; await created(reselect,10); await reselect.requests[0].emit('error'); await rd.done;
  const rd2=await start(reselect,file('x',10)); assert.equal(reselect.fetches.at(-1).url,'/uploads/'+id); await reselect.reply(200,{id,size:10,offset:7}); assert.equal(reselect.requests.at(-1).url,'/uploads/'+id+'?offset=7'); await response(reselect.requests.at(-1),200,{id,size:10,offset:10}); await complete(reselect,10); await rd2.done;

  // A lost complete response remains recoverable after a page reload. The
  // stored session id retrieves the durable receipt instead of creating a
  // second receive session; confirmed success removes the local record.
  const uploadStorage=new Map();
  const lostComplete=setup({sessionStorage:uploadStorage});
  const lostCompleteDone=await start(lostComplete,file('reload-safe.bin',3));
  await created(lostComplete,3);
  await response(lostComplete.requests[0],200,{id,size:3,offset:3});
  await lostComplete.reject(); await lostCompleteDone.done;
  assert.equal(state(lostComplete.rows[0]),'paused');
  assert.ok(uploadStorage.has('landrop.uploadSessions.v1'));
  const refreshed=setup({sessionStorage:uploadStorage});
  const refreshedDone=await start(refreshed,file('reload-safe.bin',3));
  assert.equal(refreshed.fetches[0].url,'/uploads/'+id,'resume by remembered session id');
  await refreshed.reply(200,{id,size:3,offset:3});
  assert.equal(refreshed.fetches[1].url,'/uploads/'+id+'/complete');
  await refreshed.reply(201,{name:'reload-safe.bin',size:3});
  await refreshedDone.done;
  assert.equal(state(refreshed.rows[0]),'success');
  assert.equal(refreshed.fetches.some(request=>request.url.startsWith('/uploads?')),false,'do not create a duplicate session');
  assert.equal(uploadStorage.has('landrop.uploadSessions.v1'),false,'confirmed success clears recovery metadata');

  // Storage denial must not silently claim reload recovery; a throwing
  // storage getter is reported immediately, and method failures do not block upload.
  const blockedStorageGetter=setup({sessionStorageGetterThrows:true});
  assert.equal(blockedStorageGetter.elements['upload-recovery-warning'].hidden,false);
  assert.match(blockedStorageGetter.elements['upload-recovery-warning'].textContent,/无法可靠访问/);
  const blockedStorage=setup({sessionStorageThrows:true});
  const recoveryWarning=blockedStorage.elements['upload-recovery-warning'];
  assert.equal(recoveryWarning.hidden,false);
  assert.match(recoveryWarning.textContent,/无法可靠访问.*刷新页面后可能无法自动续传或确认/);
  const blockedStorageDone=await start(blockedStorage,file('storage-blocked.bin',3));
  await created(blockedStorage,3);
  await response(blockedStorage.requests[0],200,{id,size:3,offset:3});
  await complete(blockedStorage,3,'storage-blocked.bin');
  await blockedStorageDone.done;
  assert.equal(state(blockedStorage.rows[0]),'success','storage denial must not block upload');
  assert.equal(recoveryWarning.hidden,false,'storage warning remains visible after success');

  // Each tab owns its recovery map: another tab confirming the same shared
  // server session must not erase this tab's mapping before its refresh.
  const storageA=new Map(), storageB=new Map();
  const tabA=setup({sessionStorage:storageA}); const tabADone=await start(tabA,file('cross-tab.bin',4)); await created(tabA,4);
  const tabB=setup({sessionStorage:storageB}); const tabBDone=await start(tabB,file('cross-tab.bin',4)); await created(tabB,4);
  assert.ok(storageA.has('landrop.uploadSessions.v1')); assert.ok(storageB.has('landrop.uploadSessions.v1'));
  await response(tabA.requests[0],200,{id,size:4,offset:4}); await complete(tabA,4,'cross-tab.bin'); await tabADone.done;
  assert.equal(storageA.has('landrop.uploadSessions.v1'),false); assert.ok(storageB.has('landrop.uploadSessions.v1'));
  await response(tabB.requests[0],409,{}); await tabB.reply(200,{id,size:4,offset:4}); await tabB.reject(); await tabBDone.done;
  const tabBReload=setup({sessionStorage:storageB}); const tabBReloadDone=await start(tabBReload,file('cross-tab.bin',4));
  assert.equal(tabBReload.fetches[0].url,'/uploads/'+id);
  await tabBReload.reply(200,{id,size:4,offset:4}); await tabBReload.reply(201,{name:'cross-tab.bin',size:4}); await tabBReloadDone.done;
  assert.equal(state(tabBReload.rows[0]),'success');
  assert.equal(tabBReload.fetches.some(request=>request.url.startsWith('/uploads?')),false);

  const deliberateDuplicate=setup({sessionStorage:uploadStorage});
  const deliberateDone=await start(deliberateDuplicate,file('reload-safe.bin',3));
  assert.ok(deliberateDuplicate.fetches[0].url.startsWith('/uploads?'),'a later deliberate re-upload starts a new session');
  await deliberateDuplicate.reply(201,{id:'25bd1547-cae0-4b5e-9662-2f24b2ef6e89',size:3,offset:0});
  await deliberateDuplicate.requests[0].emit('abort'); await deliberateDone.done;

  const staleStorage=new Map(); const staleOld=setup({sessionStorage:staleStorage});
  const staleOldDone=await start(staleOld,file('stale-session.bin',2)); await created(staleOld,2);
  await staleOld.requests[0].emit('abort'); await staleOldDone.done;
  const staleReload=setup({sessionStorage:staleStorage}); const staleReloadDone=await start(staleReload,file('stale-session.bin',2));
  await staleReload.reply(404,{error:'Unknown upload'}); await staleReloadDone.done;
  assert.equal(state(staleReload.rows[0]),'error');
  assert.match(status(staleReload.rows[0]),/文件可能已保存/);
  assert.equal(staleReload.fetches.length,1,'stale sessions are not silently recreated');
  assert.equal(staleStorage.has('landrop.uploadSessions.v1'),false);

  for(const failure of [
    {code:200,body:{name:'x',size:1}}, {code:413,body:'too big'}, {code:500,body:{}},
    {code:201,body:new SyntaxError('not JSON')},{code:201,body:null},{code:201,body:{name:'x',size:0}},{code:201,body:{name:'x',size:'1'}},
    {code:201,body:{name:123,size:1}},{code:201,body:{name:'',size:1}}
  ]) {
    const a=setup(); const d=await start(a); await created(a); await response(a.requests[0],200,{id,size:1,offset:1}); await a.reply(failure.code,failure.body); await d.done;
    assert.equal(state(a.rows[0]),'paused',JSON.stringify(failure)); assert.match(status(a.rows[0]),/未确认保存/); assert.ok(!status(a.rows[0]).includes('上传成功'));
  }
  for(const event of ['error','abort','timeout']) {
    const a=setup(); const d=await start(a); await created(a); await a.requests[0].emit(event); await d.done; assert.equal(state(a.rows[0]),'paused'); assert.match(status(a.rows[0]),/未确认保存/);
    await response(a.requests[0],200,{id,size:1,offset:1}); assert.equal(state(a.rows[0]),'paused');
  }
  for(const options of [{throwOpen:true},{throwSend:true}]) { const a=setup(options); const d=await start(a); await created(a); await d.done; assert.equal(state(a.rows[0]),'paused'); }
  const mixed=setup(); await mixed.choose([file('over',1073741825),file('network',2),file('empty',0)]); const mix=mixed.button.emit('click'); await tick(); await created(mixed,2); await mixed.requests[0].emit('error'); await tick(); await created(mixed,0); await complete(mixed,0); await mix;
  assert.match(mixed.summary.textContent,/成功 1 个，暂停 1 个，失败 1 个/); assert.equal(state(mixed.rows[1]),'paused'); assert.equal(state(mixed.rows[2]),'success','queue continues after network failure');
  const invalid=setup(); const iv=await start(invalid); await invalid.reply(201,{id:'../../evil',size:1,offset:0}); await iv.done; assert.equal(invalid.requests.length,0);
  const offline=setup(); const od=await start(offline); await offline.reject(); await od.done; assert.equal(state(offline.rows[0]),'paused');
  const controlTimeout=setup(); const ctd=await start(controlTimeout); assert.equal(controlTimeout.fetches[0].signal instanceof AbortSignal,true); await controlTimeout.timeoutControl(); await ctd.done;
  assert.equal(controlTimeout.fetches[0].signal.aborted,true); assert.equal(state(controlTimeout.rows[0]),'paused'); assert.match(status(controlTimeout.rows[0]),/响应超时.*未确认保存/);
  assert.equal(controlTimeout.picker.disabled,false); assert.equal(controlTimeout.button.disabled,false,'timed-out create can be retried');
  const bodyTimeout=setup(); const bodyTimeoutDone=await start(bodyTimeout); const pendingResponse=bodyTimeout.replies.shift();
  pendingResponse.resolve({status:201,json:()=>new Promise(()=>{})}); await tick(); await bodyTimeout.timeoutControl(); await bodyTimeoutDone.done;
  assert.equal(bodyTimeout.fetches[0].signal.aborted,true); assert.equal(state(bodyTimeout.rows[0]),'paused'); assert.match(status(bodyTimeout.rows[0]),/响应超时.*未确认保存/);
  const malformed=setup(); const md=await start(malformed); await created(malformed); await response(malformed.requests[0],200,'not json'); await md.done; assert.equal(state(malformed.rows[0]),'paused');

  // Explicit cancel aborts raw XHR and DELETEs; accidental abort above only pauses.
  const cancelled=setup(); const xd=await start(cancelled); await created(cancelled); const cancelDone=cancel(cancelled.rows[0]).emit('click'); await tick();
  assert.equal(cancelled.requests[0].aborted,true); assert.equal(cancelled.fetches.at(-1).method,'DELETE'); await cancelled.reply(204); await cancelDone; await xd.done;
  assert.equal(state(cancelled.rows[0]),'cancelled'); assert.match(status(cancelled.rows[0]),/临时文件已清理/);
  const creating=setup(); const cr=await start(creating); const cc=cancel(creating.rows[0]).emit('click'); await tick(); await created(creating); assert.equal(creating.fetches.at(-1).method,'DELETE'); await creating.reply(204); await cc; await cr.done; assert.equal(creating.requests.length,0,'cancel during create cannot start chunk');
  const lostCreate=setup(); const lc=await start(lostCreate); await lostCreate.reject(); await lc.done; const retryCancel=cancel(lostCreate.rows[0]).emit('click'); await tick(); assert.equal(lostCreate.fetches[0].url,lostCreate.fetches[1].url,'cancel reconciles lost create response'); await created(lostCreate); assert.equal(lostCreate.fetches.at(-1).method,'DELETE'); await lostCreate.reply(204); await retryCancel; assert.equal(state(lostCreate.rows[0]),'cancelled');
  const cleanup=setup(); const cl=await start(cleanup); await created(cleanup); const cp=cancel(cleanup.rows[0]).emit('click'); await tick(); await cleanup.reject(); await cp; await cl.done; assert.match(status(cleanup.rows[0]),/取消未确认/);
  const cancelTimeout=setup(); const cancelTimeoutUpload=await start(cancelTimeout,file('cancel-timeout',2)); await created(cancelTimeout,2); await cancelTimeout.requests[0].emit('error'); await cancelTimeoutUpload.done;
  const cancelTimeoutDone=cancel(cancelTimeout.rows[0]).emit('click'); await tick(); assert.equal(cancelTimeout.fetches.at(-1).method,'DELETE');
  await cancelTimeout.timeoutControl(); await cancelTimeoutDone;
  assert.equal(state(cancelTimeout.rows[0]),'paused'); assert.match(status(cancelTimeout.rows[0]),/临时文件尚未确认清理/);
  assert.doesNotMatch(status(cancelTimeout.rows[0]),/临时文件已清理/); assert.equal(cancel(cancelTimeout.rows[0]).hidden,false);
  assert.equal(cancelTimeout.fetches.at(-1).signal.aborted,true);
  const committed=setup(), committedDone=await start(committed,file('committed',0)); await created(committed,0);
  await committed.reject(); await committedDone.done;
  const cancelCommitted=cancel(committed.rows[0]).emit('click'); await tick();
  assert.match(committed.fetches.at(-1).url,/cancel=1/);
  await committed.reply(409,{error:'Upload already completed',state:{id,size:0,offset:0}}); await cancelCommitted;
  assert.equal(state(committed.rows[0]),'success'); assert.match(status(committed.rows[0]),/已确认文件保存/);
  assert.doesNotMatch(status(committed.rows[0]),/已清理/);

  const ui=setup(); ui.checks[0].checked=true; await ui.checks[0].emit('change'); assert.equal(ui.elements['zip-download'].href,'/download.zip?ids='+id); assert.equal(ui.elements['select-all'].indeterminate,true);
  let preventedDefault=false;
  await ui.elements['zip-download'].emit('click',{button:0,preventDefault(){preventedDefault=true;}});
  assert.equal(preventedDefault,true,'the tokenized navigation replaces the clean anchor default');
  const zipJob='35bd1547-cae0-4b5e-9662-2f24b2ef6e89';
  assert.equal(ui.elements['zip-download'].href,'/download.zip?ids='+id,'the reusable anchor stays free of one-use tokens');
  assert.equal(ui.navigations[0],'/download.zip?ids='+id+'&job='+zipJob);
  assert.equal(ui.elements['zip-cancel'].hidden,false);
  await ui.pagehide(); assert.equal(ui.beacons.length,0,'leaving the page must not cancel an active browser download');
  await ui.elements['zip-cancel'].emit('click'); assert.deepEqual(ui.beacons,[{url:'/download.zip/cancel?job='+zipJob,body:undefined}]);
  assert.equal(ui.elements['zip-cancel'].hidden,true);
  assert.equal(ui.elements['zip-download'].href,'/download.zip?ids='+id,'cancellation clears the one-use token but preserves selection');
  ui.elements['select-all'].checked=true; await ui.elements['select-all'].emit('change'); assert.ok(ui.checks.every(c=>c.checked));
  const beaconFallback=setup({beaconResult:false}); await beaconFallback.elements['zip-download'].emit('click'); await beaconFallback.elements['zip-cancel'].emit('click');
  assert.equal(beaconFallback.fetches[0].url,'/download.zip/cancel?job=35bd1547-cae0-4b5e-9662-2f24b2ef6e89');
  assert.equal(beaconFallback.fetches[0].method,'POST'); assert.equal(beaconFallback.fetches[0].keepalive,true);
  const manyTokens=Array.from({length:33},(_,i)=>'35bd1547-cae0-4b5e-9662-'+i.toString(16).padStart(12,'0'));
  const capped=setup({zipTokens:manyTokens});
  for(let i=0;i<33;i++) await capped.elements['zip-download'].emit('click');
  assert.equal(capped.elements['zip-download'].href,'/download.zip','downloads keep working after the cancellation-token cap');
  assert.equal(capped.navigations.length,33);
  assert.equal(capped.navigations.at(-1),'/download.zip','capped requests use the clean download URL');
  await capped.elements['zip-cancel'].emit('click');
  assert.equal(capped.beacons.length,32,'the page bounds remembered cancellation tokens');
  assert.equal(capped.elements['zip-download'].href,'/download.zip','cancellation restores a clean reusable link');
  const noCrypto=setup({noCrypto:true}); noCrypto.checks[0].checked=true; await noCrypto.checks[0].emit('change'); await noCrypto.elements['zip-download'].emit('click'); await noCrypto.pagehide();
  assert.equal(noCrypto.elements['zip-download'].href,'/download.zip?ids='+id,'downloads still work without Web Crypto'); assert.equal(noCrypto.beacons.length,0);
  const randomValues=setup({useGetRandomValues:true}); await randomValues.elements['select-all'].emit('change'); await randomValues.elements['zip-download'].emit('click');
  assert.equal(randomValues.elements['zip-download'].href,'/download.zip');
  assert.equal(randomValues.navigations[0],'/download.zip?job=00000000-0000-4000-8000-000000000000');
  const modifiedClick=setup(); let modifiedPrevented=false;
  await modifiedClick.elements['zip-download'].emit('click',{button:0,metaKey:true,preventDefault(){modifiedPrevented=true;}});
  assert.equal(modifiedPrevented,false,'modified clicks keep native clean-link behavior');
  assert.equal(modifiedClick.elements['zip-download'].href,'/download.zip');
  assert.equal(modifiedClick.elements['zip-cancel'].hidden,true,'opening a clean link in another tab does not create a cancellation token');
  assert.equal(modifiedClick.navigations.length,0);
  ui.elements['select-all'].checked=false; await ui.elements['select-all'].emit('change'); assert.equal(ui.elements['zip-download'].href,'/download.zip');
  assert.equal(ui.preview.getAttribute('aria-label'),'预览 a.mp4');
  await ui.preview.emit('click'); const video=ui.elements['preview-media'].children[0]; assert.equal(video.src,'/file/'+id+'?inline=1'); assert.equal(video.controls,true); assert.notEqual(video.autoplay,true); assert.equal(ui.elements['preview-dialog'].open,true);
  assert.equal(ui.elements['preview-status'].textContent,'预览加载中…');
  await video.emit('loadeddata'); assert.equal(ui.elements['preview-status'].textContent,''); assert.equal(ui.elements['preview-media'].attributes['aria-busy'],'false');
  let prevented=false; await ui.elements['preview-dialog'].emit('cancel',{preventDefault(){prevented=true;}}); assert.equal(prevented,true); assert.equal(video.paused,true); assert.equal(video.loaded,true); assert.equal(ui.elements['preview-dialog'].open,false); assert.equal(ui.preview.focused,true); assert.equal(ui.elements['preview-status'].textContent,'');
  await ui.elements['theme-toggle'].emit('click'); assert.equal(ui.elements['theme-toggle'].attributes['aria-pressed'],'true');
  // OS appearance follows until the existing two-state button is used.
  const theme=setup({dark:true});
  assert.equal(theme.elements['theme-toggle'].attributes['aria-pressed'],'true');
  theme.themeListeners.forEach(f=>f({matches:false}));
  assert.equal(theme.elements['theme-toggle'].attributes['aria-pressed'],'false');
  await theme.elements['theme-toggle'].emit('click');
  theme.themeListeners.forEach(f=>f({matches:false}));
  assert.equal(theme.elements['theme-toggle'].attributes['aria-pressed'],'true','manual choice survives OS changes');

  // Hostile data must be text, IDs must be UUIDs, preview requires BOTH enum + extension.
  let snapshot={title:'<img onerror=evil()>',files:[{id,name:'evil.svg',size:1,relativePath:'<script>evil()</script>',previewKind:'image'}]};
  const dynamic=setup({empty:true,fetch:async()=>({status:200,json:async()=>snapshot})});
  const selectionStatusWrites=dynamic.elements['selection-count'].textContentWrites;
  await dynamic.poll();
  assert.equal(dynamic.elements['selection-count'].textContentWrites,selectionStatusWrites,'new unselected files do not re-announce an unchanged selection count');
  const row=dynamic.elements['file-list'].children[0];
  const fileAnnouncement=dynamic.elements['file-list-announcement'];
  assert.equal(fileAnnouncement.textContent,'新增 1 个文件，当前共 1 个文件。','new files are announced politely');
  assert.equal(row.querySelector('.file-name').textContent,'evil.svg');
  assert.equal(row.querySelector('.file-path').textContent,'<script>evil()</script>');
  assert.equal(row.querySelector('.preview-button'),null);
  assert.equal(dynamic.elements['page-title'].textContent,'<img onerror=evil()>');
  for(const [name,kind] of [['safe.png','script'],['unsafe.html','video'],['safe.mp4','image'],['safe.png','constructor'],['safe.png','__proto__'],['safe.png',['image']],['png','image']]) {
    snapshot={...snapshot,files:[{id,name,size:1,previewKind:kind}]}; await dynamic.poll();
    assert.equal(row.querySelector('.preview-button'),null);
  }
  snapshot={...snapshot,files:[{id:'../../bad',name:'bad.png',size:1,previewKind:'image'}]}; await dynamic.poll();
  assert.equal(dynamic.elements['file-list'].children[0],row,'malformed manifest retains last working DOM');
  snapshot={...snapshot,files:[{id,name:'safe.png',size:2,previewKind:'image'}]}; await dynamic.poll();
  assert.equal(dynamic.elements['file-list'].children[0],row,'metadata changes patch in place');
  const livePreview=row.querySelector('.preview-button'); assert.ok(livePreview);
  assert.equal(livePreview.getAttribute('aria-label'),'预览 safe.png');
  snapshot={...snapshot,files:[{id,name:'renamed <safe> "photo".png',size:2,previewKind:'image'}]}; await dynamic.poll();
  assert.equal(fileAnnouncement.textContent,'新增 1 个文件，当前共 1 个文件。','renaming an existing file does not announce a list change');
  assert.equal(row.querySelector('.preview-button'),livePreview,'same preview control is patched in place');
  assert.equal(livePreview.getAttribute('aria-label'),'预览 renamed <safe> "photo".png');
  await livePreview.emit('click'); assert.equal(dynamic.elements['preview-dialog'].open,true);
  const image=dynamic.elements['preview-media'].children[0];
  assert.equal(dynamic.elements['preview-status'].textContent,'预览加载中…');
  snapshot={...snapshot,files:[{id,name:'updated <photo> & notes.png',size:2,previewKind:'image'}]}; await dynamic.poll();
  assert.equal(dynamic.elements['preview-title'].textContent,'updated <photo> & notes.png');
  assert.equal(image.alt,'updated <photo> & notes.png');
  assert.equal(livePreview.getAttribute('aria-label'),'预览 updated <photo> & notes.png');
  await image.emit('error'); assert.equal(dynamic.elements['preview-status'].textContent,'预览失败，请下载文件。');
  assert.equal(dynamic.elements['preview-status'].getAttribute('data-state'),'error');
  snapshot={...snapshot,files:[{id,name:'updated video.mp4',size:2,previewKind:'video'}]}; await dynamic.poll();
  assert.equal(dynamic.elements['preview-dialog'].open,false,'preview closes when its media type changes');
  assert.equal(dynamic.elements['preview-status'].textContent,'');
  const videoPreview=row.querySelector('.preview-button');
  assert.equal(videoPreview.getAttribute('data-kind'),'video');
  await videoPreview.emit('click');
  snapshot={...snapshot,files:[{id,name:'not-previewable.txt',size:2,previewKind:'image'}]}; await dynamic.poll();
  assert.equal(dynamic.elements['preview-dialog'].open,false,'preview closes when the current file becomes non-previewable');
  assert.equal(dynamic.elements['preview-status'].textContent,'');
  snapshot={...snapshot,files:[]}; await dynamic.poll();
  assert.equal(fileAnnouncement.textContent,'移除 1 个文件，当前共 0 个文件。','removed files are announced politely');
  assert.equal(dynamic.elements['preview-dialog'].open,false);

  const stalePreview=setup(); await stalePreview.preview.emit('click');
  const oldMedia=stalePreview.elements['preview-media'].children[0];
  await stalePreview.elements['preview-dialog'].emit('cancel',{preventDefault(){}});
  assert.equal(stalePreview.elements['preview-status'].textContent,'');
  await stalePreview.preview.emit('click');
  const currentMedia=stalePreview.elements['preview-media'].children[0];
  assert.notEqual(currentMedia,oldMedia);
  await oldMedia.emit('error');
  assert.equal(stalePreview.elements['preview-status'].textContent,'预览加载中…','late event from prior preview is ignored even for the same UUID');
  await currentMedia.emit('error');
  assert.equal(stalePreview.elements['preview-status'].textContent,'预览失败，请下载文件。');

  const audioPreview=setup();
  audioPreview.preview.setAttribute('data-kind','audio');
  audioPreview.preview.setAttribute('data-name','notes.mp3');
  audioPreview.preview.setAttribute('aria-label','预览 notes.mp3');
  await audioPreview.preview.emit('click');
  const audio=audioPreview.elements['preview-media'].children[0];
  assert.equal(audio.controls,true); assert.equal(audio.preload,'metadata');
  assert.equal(audioPreview.elements['preview-status'].textContent,'预览加载中…');
  await audio.emit('loadedmetadata');
  assert.equal(audioPreview.elements['preview-status'].textContent,'');
  assert.equal(audioPreview.elements['preview-media'].attributes['aria-busy'],'false');

  for(const [name,kind] of [['safe.bmp','image'],['safe.aac','audio'],['safe.flac','audio']]) {
    snapshot={...snapshot,files:[{id,name,size:1,previewKind:kind}]}; await dynamic.poll();
    const button=dynamic.elements['file-list'].querySelector('.preview-button');
    assert.equal(button.getAttribute('data-kind'),kind,'all server-safe preview formats are available dynamically');
  }

  // Even a fetch that ignores abort forever must time out and allow recovery.
  const pending=[];
  const stalled=setup({empty:true,fetch:(url,init)=>new Promise(resolve=>pending.push({resolve,signal:init.signal}))});
  await stalled.choose([file('keep-upload.txt')]);
  const keptUpload=stalled.rows[0], keptStatus=keptUpload.children[1].textContent;
  const expired=stalled.poll(); await tick();
  assert.equal(pending[0].signal.aborted,false);
  await stalled.timeoutManifest(); await expired;
  assert.equal(pending[0].signal.aborted,true); assert.equal(stalled.timers.size,1,'one retry timer after timeout');
  const recovered=stalled.poll(); await tick();
  pending[1].resolve({status:200,json:async()=>({title:'Recovered',files:[{id,name:'current.png',size:1,previewKind:'image'}]})}); await recovered;
  assert.equal(stalled.elements['page-title'].textContent,'Recovered');
  assert.equal(stalled.rows[0],keptUpload); assert.equal(keptUpload.children[1].textContent,keptStatus);
  assert.equal(stalled.button.disabled,false); assert.equal(stalled.elements['download-toast'].textContent,'');
  pending[0].resolve({status:200,json:async()=>({title:'STALE',files:[]})}); await tick();
  assert.equal(stalled.elements['page-title'].textContent,'Recovered'); assert.equal(stalled.timers.size,1);

  // Hide/show in the same turn aborts the old generation and starts immediately.
  const abandoned=stalled.poll(); await tick(); const old=pending[2];
  const hidden=stalled.visibility('hidden'), visible=stalled.visibility('visible');
  await Promise.all([hidden,visible]); await abandoned;
  assert.equal(old.signal.aborted,true); assert.equal(pending.length,4);
  assert.equal(stalled.timers.size,1); assert.equal([...stalled.timers.values()][0].ms,8000,'old finally cannot create an extra polling timer');
  old.resolve({status:200,json:async()=>({title:'HIDDEN OLD',files:[]})}); await tick();
  assert.equal(stalled.elements['page-title'].textContent,'Recovered'); assert.equal(stalled.timers.size,1);
  pending[3].resolve({status:200,json:async()=>({title:'Visible current',files:[]})}); await tick();
  assert.equal(stalled.elements['page-title'].textContent,'Visible current');
  assert.equal(stalled.timers.size,1); assert.equal([...stalled.timers.values()][0].ms,2000);

  // The deadline includes body JSON parsing, not only response headers.
  let bodyResolve, bodyCalls=0;
  const bodyPending=setup({empty:true,fetch:async()=>({status:200,json:()=>++bodyCalls===1 ? new Promise(resolve=>{bodyResolve=resolve;}) : Promise.resolve({title:'Body recovered',files:[]})})});
  const bodyPoll=bodyPending.poll(); await tick(); await bodyPending.timeoutManifest(); await bodyPoll;
  await bodyPending.poll(); bodyResolve({title:'Late JSON',files:[]}); await tick();
  assert.equal(bodyPending.elements['page-title'].textContent,'Body recovered'); assert.equal(bodyPending.timers.size,1);
  const noAbort=setup({empty:true,noAbortController:true,fetch:()=>new Promise(()=>{})});
  const noAbortPoll=noAbort.poll(); await tick(); await noAbort.timeoutManifest(); await noAbortPoll;
  assert.equal(noAbort.timers.size,1,'DOM mocks without AbortController still recover');
  console.log('upload behavior checks passed');
}
module.exports = {Element, setup};
if (require.main === module) checks().catch(e=>{ console.error(e); process.exitCode=1; });
