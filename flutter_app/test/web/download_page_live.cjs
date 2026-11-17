'use strict';
// Runs the actual HTML-emitted JS against the live Dart HttpServer, no browser.
const assert = require('node:assert/strict');
const http = require('node:http');
const {File} = require('node:buffer');
const {Element, setup} = require('./download_page_behavior.cjs');
const base = process.argv[2];
const headers = {'Origin':base,'Sec-Fetch-Site':'same-origin'};
const wire = [];
let mode = '', networkFailed = false, injected409 = false, activePartial;
async function liveFetch(path, init={}) {
  const response = await fetch(new URL(path,base),{...init,headers:{...headers,...init.headers}});
  wire.push({method:init.method||'GET',path,status:response.status});
  return response;
}
class XHR extends Element {
  constructor() { super(); this.upload = new Element(); this.headers = {...headers}; }
  open(method,path) { this.method=method; this.path=path; }
  setRequestHeader(k,v) { this.headers[k]=v; }
  async send(blob) {
    const bytes=Buffer.from(await blob.arrayBuffer());
    if (this.aborted) return;
    if (mode==='resume' && this.path.includes('offset=4194304') && !networkFailed) {
      networkFailed=true; await this.emit('error'); return;
    }
    let path=this.path;
    if (mode==='resume' && !injected409) { injected409=true; path=path.replace('offset=0','offset=1'); }
    const req=this.req=http.request(new URL(path,base),{method:this.method,headers:{...this.headers,'Content-Length':bytes.length}},res=>{
      const chunks=[]; res.on('data',b=>chunks.push(b)); res.on('end',()=>{
        this.status=res.statusCode; this.responseText=Buffer.concat(chunks).toString();
        wire.push({method:this.method,path,status:this.status,bytes:bytes.length}); this.emit('load');
      });
    });
    req.on('error',()=>{ if (!this.aborted) this.emit('error'); });
    if(mode==='cancel') {
      req.write(bytes.subarray(0,32),()=>{ this.upload.emit('progress',{lengthComputable:true,loaded:32,total:bytes.length}); activePartial=this; });
    } else req.end(bytes,()=>this.upload.emit('progress',{lengthComputable:true,loaded:bytes.length,total:bytes.length}));
  }
  abort() { this.aborted=true; this.req?.destroy(); this.emit('abort'); }
}
async function eventually(predicate) {
  for(let i=0;i<100;i++) { if (await predicate()) return; await new Promise(r=>setTimeout(r,10)); }
  throw Error('live protocol did not settle');
}
const state = row=>row.attributes['data-state'];
async function main() {
  const response=await liveFetch('/'); assert.equal(response.status,200);
  const html=await response.text();
  assert.match(html,/img-src 'self'; media-src 'self'/); assert.match(html,/目录\/photo\.png/,'controller must forward DownloadItem.relativePath');
  const pageScript=html.match(/<script>([\s\S]*?)<\/script>/)[1];
  const createApp=()=>setup({pageScript,fetch:liveFetch,XMLHttpRequest:XHR});
  const bytes=Buffer.alloc(4194304+37,97);
  const file=new File([bytes],'live 空格&?#%.bin',{lastModified:123});
  const app=createApp(); mode='resume'; await app.choose([file]); await app.button.emit('click');
  assert.equal(state(app.rows[0]),'paused'); assert.equal(app.rows[0].children[2].value,4194304/bytes.length*100);
  assert.ok(wire.some(r=>r.method==='PATCH'&&r.status===409),'real server 409 exercised');
  const existing=wire.filter(r=>r.method==='POST'&&r.path.startsWith('/uploads?')).at(-1);
  const repeated=await liveFetch(existing.path,{method:'POST'}); assert.equal(repeated.status,201);
  const session=await repeated.json(); assert.equal(session.offset,4194304);
  mode=''; await app.button.emit('click'); assert.equal(state(app.rows[0]),'success');
  assert.ok(wire.some(r=>r.method==='GET'&&r.path==='/uploads/'+session.id&&r.status===200));
  const receipt=await liveFetch('/uploads/'+session.id);
  assert.equal(receipt.status,200,'completed upload retains a bounded recovery receipt');
  assert.deepEqual(await receipt.json(),{id:session.id,offset:bytes.length,size:bytes.length});
  const repeatedComplete=await liveFetch('/uploads/'+session.id+'/complete',{method:'POST'});
  assert.equal(repeatedComplete.status,201,'complete is idempotent after a lost success response');
  assert.deepEqual(await repeatedComplete.json(),{name:'live 空格&_#%.bin',size:bytes.length});
  assert.equal(wire.filter(r=>r.method==='PATCH'&&r.status===200).every(r=>r.bytes<=4194304),true);

  // A new DOM/File selection must recover by POST fingerprint, not a cached File handle.
  const app2=createApp(); mode='resume'; injected409=true; networkFailed=false;
  const second=new File([bytes],'live-reselect.bin',{lastModified:456});
  await app2.choose([second]); await app2.button.emit('click'); assert.equal(state(app2.rows[0]),'paused');
  const firstCreate=wire.filter(r=>r.method==='POST'&&r.path.startsWith('/uploads?')).at(-1).path;
  mode=''; await app2.choose([new File([bytes],'live-reselect.bin',{lastModified:456})]); await app2.button.emit('click');
  assert.equal(state(app2.rows[0]),'success'); assert.equal(wire.filter(r=>r.method==='POST'&&r.path.startsWith('/uploads?')).at(-1).path,firstCreate);

  const cancelled=createApp(); mode='cancel'; await cancelled.choose([new File([Buffer.alloc(1000)],'live-cancel.bin',{lastModified:1})]);
  const uploading=cancelled.button.emit('click'); await eventually(()=>activePartial);
  const create=wire.filter(r=>r.method==='POST'&&r.path.startsWith('/uploads?')).at(-1).path;
  const cancelState=await (await liveFetch(create,{method:'POST'})).json();
  await eventually(async()=>{ const r=await liveFetch('/uploads/'+cancelState.id); return r.status===200 && (await r.json()).offset===32; });
  await cancelled.rows[0].children[3].children[0].emit('click'); await uploading;
  assert.equal(activePartial.aborted,true); assert.equal(state(cancelled.rows[0]),'cancelled');
  assert.equal((await liveFetch('/uploads/'+cancelState.id)).status,404);

  // Safe media stays inline; HTML and SVG always remain attachments, even with inline=1.
  const files=[...html.matchAll(/href="(\/file\/[a-f0-9-]+)" download="([^"]+)"/g)];
  for(const [,path,name] of files) {
    const r=await liveFetch(path+'?inline=1'); assert.equal(r.status,200); await r.arrayBuffer();
    assert.equal(r.headers.get('x-content-type-options'),'nosniff');
    if(name.endsWith('.png')) assert.match(r.headers.get('content-type'),/^image\/png/);
    else { assert.match(r.headers.get('content-type'),/^application\/octet-stream/); assert.match(r.headers.get('content-disposition'),/^attachment;/); }
  }
  const ids=files.map(f=>f[1].split('/').at(-1));
  for(const path of ['/download.zip','/download.zip?ids='+ids.slice(0,2).join(',')]) {
    const r=await liveFetch(path); assert.equal(r.status,200); assert.match(r.headers.get('content-type'),/^application\/zip/); assert.ok((await r.arrayBuffer()).byteLength>22);
  }
  // Incomplete completion must never commit a file, and the session stays cancellable.
  const incompleteCreate=await liveFetch('/uploads?name=incomplete.bin&size=3&fingerprint=incomplete-live',{method:'POST'});
  assert.equal(incompleteCreate.status,201); const incomplete=await incompleteCreate.json();
  const incompleteComplete=await liveFetch('/uploads/'+incomplete.id+'/complete',{method:'POST'});
  assert.equal(incompleteComplete.status,409); assert.equal((await incompleteComplete.json()).offset,0);
  const incompleteDelete=await liveFetch('/uploads/'+incomplete.id,{method:'DELETE'}); assert.equal(incompleteDelete.status,204);
  // Browser-shaped mutations accepted; external origins and same-site aliases rejected.
  for(const extra of [{'Origin':'http://evil.example'},{'Sec-Fetch-Site':'cross-site'}]) {
    const r=await fetch(base+'/uploads?name=evil&size=0&fingerprint=evil',{method:'POST',headers:{...headers,...extra}}); assert.equal(r.status,403); await r.text();
  }
  console.log('live web/server contract passed');
}
main().catch(e=>{ console.error(e); process.exitCode=1; });
