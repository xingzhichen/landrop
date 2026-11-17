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
  set textContent(value) { this.text = value; if (this.children) this.children.length = 0; }
  get textContent() { return this.text; }
  set innerHTML(_) { throw Error('Never insert filenames as markup'); }
  addEventListener(t, f) { (this.listeners[t] ||= []).push(f); }
  emit(t,e={}) { return Promise.all((this.listeners[t] || []).map(f => f(e))); }
  appendChild(n) { n.remove(); n.parentElement = this; this.children.push(n); return n; }
  insertBefore(n, ref) { if(n===ref) return n; n.remove(); n.parentElement = this; const i=this.children.indexOf(ref); this.children.splice(i<0?this.children.length:i,0,n); return n; }
  remove() { if(this.parentElement) { const a=this.parentElement.children, i=a.indexOf(this); if(i>=0) a.splice(i,1); this.parentElement=null; } }
  get lastElementChild() { return this.children.at(-1); }
  get isConnected() { return !!this.parentElement; }
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
  for (const name of ['theme-toggle','download-toast','upload-files','upload-button','upload-panel','upload-list','upload-summary','select-all','zip-download','selection-count','preview-dialog','preview-media','preview-close','preview-title','file-list','file-count','file-total','page-title']) elements[name] = new Element();
  elements['upload-panel'].appendChild(elements['upload-summary']);
  const selection = new Element(), label = new Element(); selection.appendChild(label); label.appendChild(elements['select-all']);
  elements['upload-button'].disabled = true;
  const checks = options.empty ? [] : [new Element(), new Element()]; if(checks.length) { checks[0].value=id; checks[1].value='25bd1547-cae0-4b5e-9662-2f24b2ef6e89'; }
  const preview = new Element(); preview.setAttribute('data-id',id); preview.setAttribute('data-kind','video'); preview.setAttribute('data-name','a.mp4');
  const requests = [], fetches = [], replies = [];
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
  const documentEvents = {}, timers = new Map(), themeListeners = [];
  let nextTimer=0;
  const body = new Element(); Object.values(elements).filter(e=>!e.parentElement).forEach(e=>body.appendChild(e)); body.appendChild(preview);
  const document = {documentElement:new Element(),visibilityState:'visible',activeElement:null,
    addEventListener:(t,f)=>(documentEvents[t] ||= []).push(f),
    getElementById:n=>elements[n] || body.querySelector('#'+n),
    createElement:tag=>{const e=new Element(); e.tag=tag; e.ownerDocument=document; return e;},
    querySelectorAll:q=>q==='.file-select'?[...checks,...elements['file-list'].querySelectorAll(q)]:q==='.preview-button'?[preview,...elements['file-list'].querySelectorAll(q)]:q==='.download-arrow, #zip-download'?[elements['zip-download']]:body.querySelectorAll(q)};
  const window = {AbortController:options.noAbortController ? undefined : AbortController,matchMedia:q=>({matches:q.includes('reduced-motion') || !!options.dark && q.includes('color-scheme'),addEventListener:(t,f)=>themeListeners.push(f)}),
    setTimeout:(fn,ms)=>{if(ms===2000 || ms===8000){const id=++nextTimer;timers.set(id,{fn,ms});return id;}fn();return ++nextTimer;},clearTimeout:id=>timers.delete(id),requestAnimationFrame:fn=>fn()};
  const fetch = (url,init) => { fetches.push({url,...init}); return new Promise((resolve,reject)=>replies.push({resolve,reject})); };
  new Function('document','window','XMLHttpRequest','fetch',options.pageScript || pageScript)(document,window,options.XMLHttpRequest || XHR,options.fetch || fetch);
  return {elements,checks,preview,requests,fetches,replies,document,timers,themeListeners,
    async poll() { const first=[...timers.entries()].find(([,timer])=>timer.ms===2000); assert.ok(first,'manifest timer scheduled'); timers.delete(first[0]); await first[1].fn(); },
    async timeoutManifest() { const first=[...timers.entries()].find(([,timer])=>timer.ms===8000); assert.ok(first,'manifest deadline scheduled'); timers.delete(first[0]); first[1].fn(); await tick(); },
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
  assert.equal(app.requests.length+app.fetches.length,0,'selection never auto-uploads');
  const done=app.button.emit('click'); await tick();
  assert.equal(app.picker.disabled,true); assert.equal(app.button.disabled,true);
  await app.button.emit('click'); assert.equal(app.fetches.length,1,'no double-click queue');
  const metadata=Buffer.from(JSON.stringify([first.name,first.size,first.lastModified]));
  const expected=crypto.createHash('sha256').update(Buffer.concat([metadata,Buffer.alloc(65536,97),Buffer.alloc(65536,97)])).digest('hex');
  assert.equal(app.fetches[0].url,'/uploads?name='+encodeURIComponent(first.name)+'&size='+first.size+'&fingerprint='+expected);
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
  await complete(app,first.size,'<img onerror=evil()>');
  assert.equal(state(app.rows[0]),'success'); assert.ok(status(app.rows[0]).endsWith('<img onerror=evil()>'));
  assert.equal(app.fetches.at(-1).method,'POST'); await created(app,0); // empty file has no PATCH
  assert.equal(app.requests.length,2); await complete(app,0); await done;
  assert.match(app.summary.textContent,/成功 2 个/); assert.equal(app.picker.disabled,false); assert.equal(app.picker.value,'');
  assert.equal(app.elements['upload-panel'].attributes['aria-busy'],'false');

  const over=setup(); await over.choose([file('big',1073741825)]); assert.equal(over.button.disabled,true); assert.equal(state(over.rows[0]),'error');
  const limit=setup(); const limitDone=await start(limit,file('max',1073741824)); await created(limit,1073741824,1073741824); await complete(limit,1073741824); await limitDone.done; assert.equal(state(limit.rows[0]),'success');
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
  const rd2=await start(reselect,file('x',10)); assert.equal(reselect.fetches.at(-1).url,firstUrl); await created(reselect,10,7); assert.equal(reselect.requests.at(-1).url,'/uploads/'+id+'?offset=7'); await response(reselect.requests.at(-1),200,{id,size:10,offset:10}); await complete(reselect,10); await rd2.done;

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
  const malformed=setup(); const md=await start(malformed); await created(malformed); await response(malformed.requests[0],200,'not json'); await md.done; assert.equal(state(malformed.rows[0]),'paused');

  // Explicit cancel aborts raw XHR and DELETEs; accidental abort above only pauses.
  const cancelled=setup(); const xd=await start(cancelled); await created(cancelled); const cancelDone=cancel(cancelled.rows[0]).emit('click'); await tick();
  assert.equal(cancelled.requests[0].aborted,true); assert.equal(cancelled.fetches.at(-1).method,'DELETE'); await cancelled.reply(204); await cancelDone; await xd.done;
  assert.equal(state(cancelled.rows[0]),'cancelled'); assert.match(status(cancelled.rows[0]),/临时文件已清理/);
  const creating=setup(); const cr=await start(creating); const cc=cancel(creating.rows[0]).emit('click'); await tick(); await created(creating); assert.equal(creating.fetches.at(-1).method,'DELETE'); await creating.reply(204); await cc; await cr.done; assert.equal(creating.requests.length,0,'cancel during create cannot start chunk');
  const lostCreate=setup(); const lc=await start(lostCreate); await lostCreate.reject(); await lc.done; const retryCancel=cancel(lostCreate.rows[0]).emit('click'); await tick(); assert.equal(lostCreate.fetches[0].url,lostCreate.fetches[1].url,'cancel reconciles lost create response'); await created(lostCreate); assert.equal(lostCreate.fetches.at(-1).method,'DELETE'); await lostCreate.reply(204); await retryCancel; assert.equal(state(lostCreate.rows[0]),'cancelled');
  const cleanup=setup(); const cl=await start(cleanup); await created(cleanup); const cp=cancel(cleanup.rows[0]).emit('click'); await tick(); await cleanup.reject(); await cp; await cl.done; assert.match(status(cleanup.rows[0]),/取消未确认/);

  const ui=setup(); ui.checks[0].checked=true; await ui.checks[0].emit('change'); assert.equal(ui.elements['zip-download'].href,'/download.zip?ids='+id); assert.equal(ui.elements['select-all'].indeterminate,true);
  ui.elements['select-all'].checked=true; await ui.elements['select-all'].emit('change'); assert.ok(ui.checks.every(c=>c.checked));
  ui.elements['select-all'].checked=false; await ui.elements['select-all'].emit('change'); assert.equal(ui.elements['zip-download'].href,'/download.zip');
  await ui.preview.emit('click'); const video=ui.elements['preview-media'].children[0]; assert.equal(video.src,'/file/'+id+'?inline=1'); assert.equal(video.controls,true); assert.notEqual(video.autoplay,true); assert.equal(ui.elements['preview-dialog'].open,true);
  let prevented=false; await ui.elements['preview-dialog'].emit('cancel',{preventDefault(){prevented=true;}}); assert.equal(prevented,true); assert.equal(video.paused,true); assert.equal(video.loaded,true); assert.equal(ui.elements['preview-dialog'].open,false); assert.equal(ui.preview.focused,true);
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
  await dynamic.poll();
  const row=dynamic.elements['file-list'].children[0];
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
  await livePreview.emit('click'); assert.equal(dynamic.elements['preview-dialog'].open,true);
  snapshot={...snapshot,files:[]}; await dynamic.poll();
  assert.equal(dynamic.elements['preview-dialog'].open,false);
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
