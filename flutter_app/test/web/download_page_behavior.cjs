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
  appendChild(n) { n.parentElement = this; this.children.push(n); }
  insertBefore(n, ref) { n.parentElement = this; this.children.splice(this.children.indexOf(ref),0,n); }
  setAttribute(k,v) { this.attributes[k] = v; }
  getAttribute(k) { return this.attributes[k]; }
  removeAttribute(k) { delete this.attributes[k]; }
  focus() { this.focused = true; }
  showModal() { this.open = true; }
  close() { this.open = false; this.emit('close'); }
  pause() { this.paused = true; }
  load() { this.loaded = true; }
}
function setup(options={}) {
  const elements = {};
  for (const name of ['theme-toggle','download-toast','upload-files','upload-button','upload-panel','upload-list','upload-summary','select-all','zip-download','selection-count','preview-dialog','preview-media','preview-close','preview-title']) elements[name] = new Element();
  elements['upload-panel'].appendChild(elements['upload-summary']);
  const selection = new Element(), label = new Element(); selection.appendChild(label); label.appendChild(elements['select-all']);
  elements['upload-button'].disabled = true;
  const checks = [new Element(), new Element()]; checks[0].value=id; checks[1].value='25bd1547-cae0-4b5e-9662-2f24b2ef6e89';
  const preview = new Element(); preview.setAttribute('data-id',id); preview.setAttribute('data-kind','video'); preview.setAttribute('data-name','a.mp4');
  const requests = [], fetches = [], replies = [];
  class XHR extends Element {
    constructor() { super(); this.upload = new Element(); this.headers={}; requests.push(this); }
    open(method,url) { if(options.throwOpen) throw Error('open'); this.method=method; this.url=url; }
    setRequestHeader(k,v) { this.headers[k]=v; }
    send(body) { if(options.throwSend) throw Error('send'); this.body=body; }
    abort() { this.aborted = true; this.emit('abort'); }
  }
  const document = {documentElement:new Element(), getElementById:n=>elements[n], createElement:tag=>{const e=new Element(); e.tag=tag; return e;}, querySelectorAll:q=>q==='.file-select'?checks:q==='.preview-button'?[preview]:q==='.download-arrow, #zip-download'?[elements['zip-download']]:[]};
  const window = {matchMedia:()=>({matches:true}),setTimeout:fn=>{fn();return 1;},clearTimeout(){},requestAnimationFrame:fn=>fn()};
  const fetch = (url,init) => { fetches.push({url,...init}); return new Promise((resolve,reject)=>replies.push({resolve,reject})); };
  new Function('document','window','XMLHttpRequest','fetch',options.pageScript || pageScript)(document,window,options.XMLHttpRequest || XHR,options.fetch || fetch);
  return {elements,checks,preview,requests,fetches,replies,rows:elements['upload-list'].children,
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
  console.log('upload behavior checks passed');
}
module.exports = {Element, setup};
if (require.main === module) checks().catch(e=>{ console.error(e); process.exitCode=1; });
