import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {spawnSync} from 'node:child_process';
const bundle=fs.readFileSync(new URL('../ios/AudioLocal/protocol-capture.js',import.meta.url),'utf8');
const A='7530630967543811388',B='7530630967543811389';
const NOW=Date.parse('2026-10-27T00:00:00Z'), published=Date.parse('2026-10-20T00:00:00Z')/1000;
const video=id=>`https://www.douyin.com/video/${id}`;
const comments=id=>`https://www.douyin.com/aweme/v1/web/comment/list/?aweme_id=${id}&cursor=0&a_bogus=SECRET`;
const detail=id=>`https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=${id}`;
const row=(id='c1',time=published)=>({cid:id,text:'多少钱',create_time:time,user:{sec_uid:'MS4wLjABAAAA-fixture',nickname:'Fixture'}});
const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
function environment(initialTask=null) {
  const responses=new Map(),intervals=[];let calls=0;
  class Clock extends Date{constructor(...args){super(...(args.length?args:[NOW]));}static now(){return NOW;}}
  const window={location:{href:video(A)},__houmenProtocolInitialTask:initialTask,
    fetch:async input=>{calls++;const address=typeof input==='string'?input:input.url||input.href;return responses.get(address);}};
  const context=vm.createContext({window,URL,URLSearchParams,Date:Clock,TextEncoder,TextDecoder,Promise,Map,Set,
    setInterval:fn=>{intervals.push(fn);return intervals.length;}});
  vm.runInContext(bundle,context);
  return {window,context,api:window.__houmenProtocol,calls:()=>calls,drain:()=>intervals.forEach(fn=>fn()),
    async receive(url,payload,status=200,finalUrl=url){responses.set(url,{status,url:finalUrl,clone(){return {text:async()=>typeof payload==='string'?payload:JSON.stringify(payload)};}});await window.fetch(url);await tick();},
    async delayed(url){let release;responses.set(url,{status:200,url,clone(){return {text:()=>new Promise(r=>{release=r;})};}});await window.fetch(url);return body=>release(JSON.stringify(body));}};
}
const read=(env,id=A)=>JSON.parse(JSON.stringify(env.api.read({platform:'douyin',sourceUrl:video(id),keyword:'品牌'})));

test('bundle is reproducible from vendored source, no unresolved ESM',()=>{
  const check=spawnSync(process.execPath,['tools/build-ios-protocol.mjs','--check'],{cwd:new URL('..',import.meta.url),encoding:'utf8'});
  assert.equal(check.status,0,check.stderr);assert.ok(!/^\s*(import|export)\s/m.test(bundle));
});
test('bridge installation delegates only page initiated calls and hides raw capture API',async()=>{
  const e=environment();assert.equal(e.window.__shengxunCapture,undefined);
  await e.receive(comments(A),{comments:[row()],has_more:false});
  const r=read(e);assert.equal(r.rows.length,1);assert.equal(e.calls(),1);
  assert.ok(!JSON.stringify(r).includes('SECRET'));assert.ok(!('body' in r));
});
test('source details and comments may arrive in either order without losing rows',async()=>{
  for(const order of ['details-first','comments-first']){
    const e=environment();
    const d=()=>e.receive(detail(A),{aweme_detail:{aweme_id:A,desc:'Synthetic',create_time:published}});
    const c=()=>e.receive(comments(A),{comments:[row()],has_more:false});
    if(order==='details-first'){await d();e.drain();await c();}else{await c();e.drain();await d();}
    const r=read(e);assert.equal(r.sourceReady,true);assert.equal(r.commentsReady,true);assert.equal(r.rows.length,1);
    assert.equal(r.rows[0].sourceStatus,'verified');assert.equal(r.rows[0].sourceCheckedAt,'2026-10-27T00:00:00Z');
  }
});
test('detail-only ready never means empty comments or end of comments',async()=>{
  const e=environment();await e.receive(detail(A),{aweme_detail:{aweme_id:A,desc:'Source',create_time:published}});
  const r=read(e);assert.equal(r.state,'ready');assert.equal(r.sourceReady,true);assert.equal(r.commentsReady,false);
  assert.equal(r.explicitEmpty,false);assert.equal(r.endOfComments,false);
});
test('comments without protocol details remain bound for native DOM evidence fallback',async()=>{
  const e=environment();await e.receive(comments(A),{comments:[row()],has_more:true,cursor:20});
  const r=read(e);assert.equal(r.commentsReady,true);assert.equal(r.sourceReady,false);assert.equal(r.rows[0].sourceStatus,'bound');
  assert.ok(!('sourcePublishedAtISO' in r.rows[0]));assert.equal(r.rows[0].publishedAt,'');
});
test('first documentStart task binding accepts subsequent first detail response',async()=>{
  const e=environment({platform:'douyin',sourceUrl:video(A),taskId:'native-task'});
  await e.receive(detail(A),{aweme_detail:{aweme_id:A,desc:'First detail',create_time:published}});
  assert.equal(read(e).sourceReady,true);
  e.api.beginTask({platform:'douyin',sourceUrl:video(A),taskId:'native-task'});
  assert.equal(read(e).sourceReady,true);
});
test('old task data cannot survive task switch even to the same source',async()=>{
  const e=environment({platform:'douyin',sourceUrl:video(A),taskId:'one'});
  await e.receive(comments(A),{comments:[row()],has_more:false});assert.equal(read(e).rows.length,1);
  e.api.beginTask({platform:'douyin',sourceUrl:video(A),taskId:'two'});assert.equal(read(e).state,'waiting');
  const stale=e.api.read({platform:'douyin',sourceUrl:video(A),taskId:'one'});assert.equal(stale.state,'blocked');
});
test('late callback from before stop is not accepted after new beginTask',async()=>{
  const e=environment({platform:'douyin',sourceUrl:video(A),taskId:'one'});
  const release=await e.delayed(comments(A));e.api.stop();
  e.api.beginTask({platform:'douyin',sourceUrl:video(A),taskId:'two'});
  release({comments:[row()],has_more:false});await tick();
  const r=read(e);assert.equal(r.rows.length,0);assert.equal(r.state,'waiting');assert.ok(r.diagnostics.staleEpoch>=1);
});
test('redirect changing source identity is never relabelled as the requested source',async()=>{
  const e=environment();await e.receive(comments(A),{comments:[row()],has_more:false},200,comments(B));
  const r=read(e);assert.equal(r.rows.length,0);assert.ok(r.diagnostics.sourceConflicts>=1);
});
test('source conflict blocks rather than accepting mixed response data',async()=>{
  const e=environment();await e.receive(comments(A),{aweme_id:B,comments:[row()]});
  const r=read(e);assert.equal(r.state,'blocked');assert.equal(r.code,'source_mismatch');assert.deepEqual(r.rows,[]);
});
test('bad root structure never becomes successful zero comments',async()=>{
  const e=environment();await e.receive(comments(A),{wrapper:{comments:[]}});
  const r=read(e);assert.equal(r.state,'waiting');assert.equal(r.explicitEmpty,false);assert.equal(r.commentsReady,false);
  assert.ok(r.diagnostics.parseFailures>=1);
});
test('invalid future rows are counted but do not imply the page had zero comments',async()=>{
  const e=environment();await e.receive(comments(A),{comments:[row('future',NOW/1000+1)],has_more:false});
  const r=read(e);assert.equal(r.commentsReady,true);assert.equal(r.rows.length,0);assert.equal(r.explicitEmpty,false);
  assert.equal(r.endOfComments,true);assert.ok(r.diagnostics.invalidRows>=1);
});
test('rows are deduplicated and sorted by comment time, not arrival time',async()=>{
  const e=environment();await e.receive(comments(A),{comments:[row('old',published),row('new',published+20)],has_more:true});
  read(e);await e.receive(comments(A),{comments:[row('new',published+20)],has_more:false});
  const r=read(e);assert.deepEqual(r.rows.map(x=>x.commentId),['new','old']);assert.equal(r.endOfComments,true);
});
test('bounded cache evicts old sources before a first binding',async()=>{
  const e=environment();
  for(let i=0;i<12;i++){
    const id=(BigInt(A)+BigInt(i)).toString();
    await e.receive(detail(id),{aweme_detail:{aweme_id:id,desc:'Source',create_time:published}});e.drain();
  }
  const r=read(e);assert.ok(r.diagnostics.cachedSources<=8);assert.ok(r.diagnostics.evicted>=4);
});
test('per-source row cap is respected without inventing completion',async()=>{
  const e=environment();await e.receive(comments(A),{comments:Array.from({length:230},(_,i)=>row('c'+i)),has_more:true});
  const r=read(e);assert.equal(r.rows.length,200);assert.equal(r.endOfComments,false);
});
test('oversized body is not parsed and no raw body is returned',async()=>{
  const e=environment();await e.receive(comments(A),'中'.repeat(200*1024));
  const r=read(e);assert.equal(r.state,'waiting');assert.equal(r.rows.length,0);assert.ok(r.diagnostics.tooLarge>=1);
});
