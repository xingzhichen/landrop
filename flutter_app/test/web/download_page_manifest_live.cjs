'use strict';
// Real controller/HttpServer + actual generated JavaScript. Only DOM is mocked.
const assert = require('node:assert/strict');
const readline = require('node:readline');
const {File} = require('node:buffer');
const {setup} = require('./download_page_behavior.cjs');
const base = process.argv[2];
const lines = readline.createInterface({input:process.stdin});
let reply;
lines.on('line',line=>{ if(reply) { const done=reply; reply=null; done(line); } });
function mutate(action) { return new Promise(resolve=>{reply=resolve; console.log('MUTATE:'+action);}); }
async function main() {
  const html = await (await fetch(base)).text();
  assert.match(html,/暂无可下载的文件/);
  assert.match(html,/id="file-list" role="list" aria-label="可下载文件"/);
  const script = html.match(/<script>([\s\S]*?)<\/script>/)[1];
  let offline=false, requests=0;
  const app=setup({empty:true,pageScript:script,fetch:async(path,init)=>{
    assert.equal(path,'/manifest'); requests++;
    assert.equal(init.cache,'no-store');
    if(offline) throw Error('offline');
    const response=await fetch(base+path,init);
    assert.equal(response.status,200); assert.match(response.headers.get('cache-control'),/no-store/);
    return response;
  }});
  const list=app.elements['file-list'];
  const rows=()=>list.querySelectorAll('.file-card');
  await app.poll(); assert.equal(rows().length,0); assert.equal(app.elements['zip-download'].hidden,true);
  assert.equal(app.document.getElementById('file-empty').getAttribute('role'),'listitem');
  const upload=new File(['upload-data'],'pending.txt',{lastModified:1});
  await app.choose([upload]);
  const uploadRow=app.rows[0], uploadStatus=uploadRow.children[1].textContent;
  await mutate('add'); await app.poll();
  assert.equal(rows().length,1,'empty transfer begins polling before any file exists');
  assert.equal(rows()[0].getAttribute('role'),'listitem');
  const first=rows()[0], check=first.querySelector('.file-select');
  assert.equal(first.querySelector('.file-name').textContent,'photo& 空格.png');
  assert.match(first.querySelector('.file-path').textContent,/目录&特殊字符/);
  assert.equal(check.checked,false,'new files are not selected');
  check.checked=true; await check.emit('change'); check.focus();
  const id=check.value;
  assert.equal(app.elements['zip-download'].href,'/download.zip?ids='+id);
  const preview=first.querySelector('.preview-button');
  await preview.emit('click'); const media=app.elements['preview-media'].children[0];
  assert.equal(media.src,'/file/'+id+'?inline=1');
  assert.equal((await fetch(base+media.src)).status,200,'new preview is really wired');
  await app.elements['preview-close'].emit('click');
  check.focus(); await app.poll();
  assert.equal(rows()[0],first); assert.equal(app.document.activeElement,check,'unchanged snapshot preserves focus');
  await mutate('more'); await app.poll();
  assert.equal(rows().length,3); assert.equal(rows()[0],first); assert.equal(check.checked,true);
  assert.equal(app.document.activeElement,check); assert.equal(app.elements['select-all'].indeterminate,true);
  for(const row of rows().slice(1)) { assert.equal(row.querySelector('.file-select').checked,false); assert.equal(row.querySelector('.preview-button'),null,'SVG/HTML cannot inline preview'); }
  // Hydrate an already populated, actually rendered HTML list (not only new rows).
  const populated=await (await fetch(base)).text();
  const hydrated=setup({empty:true,html:populated,pageScript:script,fetch:(path,init)=>fetch(base+path,init)});
  const original=hydrated.elements['file-list'].querySelectorAll('.file-card');
  assert.equal(original.length,3);
  const originalCheck=original[0].querySelector('.file-select');
  originalCheck.checked=true; await originalCheck.emit('change');
  await hydrated.poll();
  assert.equal(hydrated.elements['file-list'].querySelectorAll('.file-card')[0],original[0],'initial HTML rows are reused');
  assert.equal(originalCheck.checked,true); assert.equal(hydrated.elements['zip-download'].href,'/download.zip?ids='+id);
  const zip=await fetch(base+app.elements['zip-download'].href); assert.equal(zip.status,200); assert.ok((await zip.arrayBuffer()).byteLength>22);
  assert.equal(app.rows[0],uploadRow); assert.equal(uploadRow.children[1].textContent,uploadStatus); assert.equal(app.button.disabled,false,'pending upload survives file mutations');
  offline=true; await app.poll(); assert.equal(rows().length,3); assert.equal(check.checked,true); assert.equal(app.elements['download-toast'].textContent,'');
  offline=false; await mutate('remove'); await app.poll(); assert.equal(rows().length,2); assert.equal(app.elements['selection-count'].textContent,'已选 0 个');
  assert.equal(app.document.activeElement,rows()[0].querySelector('.file-select'),'focused removed row moves to next row control');
  rows()[1].querySelector('.file-select').focus(); await mutate('removeLast'); await app.poll();
  assert.equal(rows().length,1); assert.equal(app.document.activeElement,rows()[0].querySelector('.file-select'),'focused last row moves to previous row control');
  await app.visibility('hidden'); assert.equal(app.timers.size,0); const before=requests;
  await mutate('clear'); await app.visibility('visible');
  // visibility listener fires immediately, with its async fetch allowed to finish.
  for(let i=0;i<100 && rows().length;i++) await new Promise(r=>setTimeout(r,10));
  assert.equal(requests,before+1); assert.equal(rows().length,0); assert.equal(app.document.getElementById('file-empty').getAttribute('role'),'listitem');
  assert.equal(app.document.activeElement,app.document.getElementById('download-heading'),'clearing the list moves focus to its heading');
  await mutate('add'); await app.poll();
  app.picker.focus(); await mutate('remove'); await app.poll();
  assert.equal(rows().length,0); assert.equal(app.document.activeElement,app.picker,'removing files does not steal focus from upload controls');
  await mutate('add'); await app.poll();
  await rows()[0].querySelector('.preview-button').emit('click'); const removedMedia=app.elements['preview-media'].children[0];
  await mutate('clear'); await app.poll();
  assert.equal(app.elements['preview-dialog'].open,false); assert.equal(removedMedia.loaded,true); assert.equal(removedMedia.src,undefined); assert.equal(removedMedia.paused,true);
  assert.equal(app.rows[0],uploadRow);
  console.log('live dynamic manifest contract passed'); lines.close();
}
main().catch(error=>{console.error(error); lines.close(); process.exitCode=1;});
