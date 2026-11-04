// Independent synthetic iOS boundary contracts: no live platform requests or session data.
import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import vm from 'node:vm';
const native = name => readFileSync(new URL('../ios/AudioLocal/'+name,import.meta.url),'utf8');
const browser = () => native('BrowserCollector.swift');
const DY='7530630967543811388', OTHER='7530630967543811399';
const NOTE='66f0a1b2c3d4e5f60718293a', USER='5f1a2b3c4d5e6f708192a3b4';
const now=Math.floor(Date.now()/1000)*1000, second=Math.floor(now/1000);
const source=(platform,id)=>platform==='douyin'?`https://www.douyin.com/video/${id}`:`https://www.xiaohongshu.com/explore/${id}`;
const endpoint=(platform,id)=>platform==='douyin'?`https://www.douyin.com/aweme/v1/web/comment/list/?aweme_id=${id}`:`https://edith.xiaohongshu.com/api/sns/web/v1/comment/page?note_id=${id}`;
const detailURL=(platform,id)=>platform==='douyin'?`https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=${id}`:`https://edith.xiaohongshu.com/api/sns/web/v1/feed?note_id=${id}`;
const detail=(platform,id)=>platform==='douyin'?{status_code:0,aweme_detail:{aweme_id:id,create_time:second-86400,desc:'合成来源'}}:{code:0,success:true,data:{items:[{id,note_card:{note_id:id,time:now-86400000,title:'合成来源'}}]}};
const comments=(platform,id,{empty=false,invalidProfile=false}={})=>platform==='douyin'?{
 status_code:0,aweme_id:id,cursor:0,has_more:0,total:empty?0:1,sessionSecret:'RAW_SECRET_MUST_NOT_RETURN',comments:empty?[]:[{
 cid:'7530630967543811401',aweme_id:id,text:'合成咨询：多少钱',create_time:second-3600,ip_label:'广东',digg_count:0,reply_comment_total:2,
 user:{nickname:'合成用户',sec_uid:invalidProfile?'x':'fixture_author_0001',unique_id:'fixture_public'}}]}:{
 code:0,success:true,data:{note_id:id,cursor:'',has_more:false,total:empty?0:1,sessionSecret:'RAW_SECRET_MUST_NOT_RETURN',comments:empty?[]:[{
 id:'66f0a1b2c3d4e5f607182940',note_id:id,content:'合成咨询：多少钱',create_time:now-3600000,ip_location:'浙江',like_count:'0',sub_comment_count:0,
 user_info:{nickname:'合成用户',user_id:invalidProfile?'x':USER},sub_comments:[]}]}};
const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
function response(url,body,status=200){const raw=typeof body==='string'?body:JSON.stringify(body);return{url,status,clone:()=>({body:new ReadableStream({start(c){c.enqueue(new TextEncoder().encode(raw));c.close();}})})};}
function install(platform='douyin',id=DY){
 const queue=[];let calls=0;
 const window={location:new URL(source(platform,id)),fetch:async (...args)=>{calls++;assert.ok(queue.length,'only fixture-owned page fetches');const fn=queue.shift();return fn(...args);}};
 window.window=window;
 const context=vm.createContext({window,location:window.location,URL,URLSearchParams,Date,TextEncoder,TextDecoder,ReadableStream,setTimeout,clearTimeout,Promise});
 vm.runInContext(native('protocol-capture.js'),context);
 const api=window.__houmenProtocol;assert.ok(api,'generated document-start bridge exists');
 const config=(target=id,taskId='qa-task')=>({platform,sourceUrl:source(platform,target),taskId});
 const feed=async(url,body,status=200)=>{queue.push(()=>response(url,body,status));await window.fetch(url);await tick();};
 return{window,api,queue,config,feed,calls:()=>calls,read:(target=id,taskId='qa-task')=>JSON.parse(JSON.stringify(api.read({...config(target,taskId),keyword:'合成关键词'})))};
}

for(const [platform,id]of [['douyin',DY],['xiaohongshu',NOTE]]){
 test(`iOS protocol contract: ${platform} source+comment rows satisfy native required keys and second precision`,async()=>{
  const f=install(platform,id);f.api.beginTask(f.config());
  await f.feed(detailURL(platform,id)+'&x-s=REQUEST_SECRET_MUST_NOT_RETURN',detail(platform,id));
  await f.feed(endpoint(platform,id)+'&a_bogus=REQUEST_SECRET_MUST_NOT_RETURN',comments(platform,id));
  const before=f.calls(),r=f.read();assert.equal(f.calls(),before,'read must not request extra platform data');
  assert.equal(r.state,'ready');assert.equal(r.sourceReady,true);assert.equal(r.commentsReady,true);assert.equal(r.sourceId,id);
  assert.equal(r.comments.length,1);const row=r.comments[0];
  for(const key of ['platform','sourceUrl','profileUrl','authorName','text','publishedAtISO'])assert.equal(typeof row[key],'string',key);
  assert.equal(row.platform,platform);assert.equal(row.sourceUrl,source(platform,id));assert.equal(row.publishedAt,'');
  assert.match(row.publishedAtISO,/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  for(const key of ['sourcePublishedAtISO','sourceCheckedAt','sourceEarliestAtISO'])assert.match(r[key],/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$/);
  assert.equal(r.sourcePublishedAt,'');assert.equal(r.sourcePublishedTimeQuality,'exact');
  assert.equal(String(row.likeCount),'0','explicit zero must survive bridge');assert.equal(row.acquisition,'protocol_capture');
  const visible=JSON.stringify(r);assert.doesNotMatch(visible,/RAW_SECRET_MUST_NOT_RETURN|REQUEST_SECRET_MUST_NOT_RETURN|"body"\s*:|"requestUrl"\s*:|"headers"\s*:/);
  assert.doesNotMatch(JSON.stringify(r.diagnostics),/合成用户|合成咨询|fixture_public|https:\/\//);
 });
}

test('iOS protocol contract: document-start precapture survives first task binding only',async()=>{
 const f=install();await f.feed(detailURL('douyin',DY),detail('douyin',DY));await f.feed(endpoint('douyin',DY),comments('douyin',DY));
 f.api.beginTask(f.config());assert.equal(f.read().comments.length,1);
 f.api.beginTask(f.config(OTHER,'new-task'));assert.equal(f.read(OTHER,'new-task').sourceReady,false);
 assert.equal(f.read().state,'blocked','old target cannot read the new task');
});

test('iOS protocol contract: comments alone never invent source proof',async()=>{
 const f=install();f.api.beginTask(f.config());await f.feed(endpoint('douyin',DY),comments('douyin',DY));const r=f.read();
 assert.equal(r.sourceReady,false);assert.ok(!r.sourcePublishedAtISO);
});

test('iOS protocol contract: empty is explicit only for successful bound comment response',async()=>{
 const f=install();f.api.beginTask(f.config());assert.equal(f.read().state,'waiting');
 await f.feed(detailURL('douyin',DY),detail('douyin',DY));assert.equal(f.read().commentsReady,false);
 await f.feed(endpoint('douyin',DY),comments('douyin',DY,{empty:true}));const r=f.read();
 assert.equal(r.commentsReady,true);assert.equal(r.explicitEmpty,true);assert.equal(r.endOfComments,true);assert.equal(r.comments.length,0);
});

test('iOS protocol contract: invalid profile row is filtered, not sent to atomically rejecting store',async()=>{
 const f=install();f.api.beginTask(f.config());await f.feed(detailURL('douyin',DY),detail('douyin',DY));
 await f.feed(endpoint('douyin',DY),comments('douyin',DY,{invalidProfile:true}));const r=f.read();assert.equal(r.comments.length,0);
 assert.notEqual(r.explicitEmpty,true,'unparseable author does not prove zero platform comments');
});

test('iOS protocol contract: login/rate limit and changed structure are not successful zero comments',async()=>{
 for(const [body,status]of [[{status_code:8,status_msg:'login required'},200],[{},429],[{unexpected:[]},200]]){
  const f=install();f.api.beginTask(f.config());await f.feed(endpoint('douyin',DY),body,status);const r=f.read();
  assert.notEqual(r.state,'ready');assert.notEqual(r.explicitEmpty,true);
 }
});

test('iOS protocol contract: source response cannot lend its date to a different target',async()=>{
 const f=install();f.api.beginTask(f.config());await f.feed(detailURL('douyin',OTHER),detail('douyin',OTHER));
 await f.feed(endpoint('douyin',DY),comments('douyin',DY));const r=f.read();assert.equal(r.sourceReady,false);assert.ok(!r.sourcePublishedAtISO);
});

test('iOS protocol contract: stop and restart reject a late fetch from the old task',async()=>{
 const f=install();f.api.beginTask(f.config());let resolve;
 f.queue.push(()=>new Promise(r=>{resolve=r;}));const pending=f.window.fetch(endpoint('douyin',DY));
 f.api.stop();f.api.beginTask(f.config(OTHER,'after-stop'));
 resolve(response(endpoint('douyin',DY),comments('douyin',DY)));await pending;await tick();
 const r=f.read(OTHER,'after-stop');assert.equal(r.sourceReady,false);assert.equal(r.commentsReady,false);assert.equal(r.comments.length,0);
});

test('iOS protocol contract: resuming same source does not admit a stopped task late response',async()=>{
 const f=install();f.api.beginTask(f.config());let resolve;
 f.queue.push(()=>new Promise(r=>{resolve=r;}));const pending=f.window.fetch(endpoint('douyin',DY));
 f.api.stop();f.api.beginTask(f.config(DY,'same-source-resume'));
 resolve(response(endpoint('douyin',DY),comments('douyin',DY)));await pending;await tick();
 assert.equal(f.read(DY,'same-source-resume').commentsReady,false);
 await f.feed(detailURL('douyin',DY),detail('douyin',DY));await f.feed(endpoint('douyin',DY),comments('douyin',DY));
 assert.equal(f.read(DY,'same-source-resume').comments.length,1,'new epoch still collects current page responses');
});

test('iOS protocol contract: native 64-bit IDs survive raw JSON without numeric rounding',async()=>{
 const f=install();f.api.beginTask(f.config());await f.feed(detailURL('douyin',DY),detail('douyin',DY));
 const body=JSON.stringify(comments('douyin',DY)).replace('"cid":"7530630967543811401"','"cid":7530630967543811401');
 await f.feed(endpoint('douyin',DY),body);assert.equal(f.read().comments[0].commentId,'7530630967543811401');
});

test('iOS protocol contract: conflicting response source ID is blocked instead of relabelled',async()=>{
 const f=install();f.api.beginTask(f.config());await f.feed(endpoint('douyin',DY),comments('douyin',OTHER));
 const r=f.read();assert.equal(r.state,'blocked');assert.equal(r.comments.length,0);assert.notEqual(r.explicitEmpty,true);
});

test('iOS native contract: added metadata stays optional and persisted through allowlist only (static)',()=>{
 const store=native('CommentStore.swift');
 for(const field of ['publicHandle','parentCommentId','ipLabel','acquisition'])assert.match(store,new RegExp(`var ${field}: String\\? = nil`));
 for(const field of ['likeCount','replyCount'])assert.match(store,new RegExp(`var ${field}: Int\\? = nil`));
 assert.match(store,/var isReply: Bool\? = nil/);assert.match(store,/CFGetTypeID\(number\) != CFBooleanGetTypeID\(\)/);
 assert.match(store,/record\.likeCount = Self\.publicCount\(raw\["likeCount"\]\) \?\? old\?\.likeCount/);
 assert.match(store,/record\.ipLabel = Self\.publicIPRegion/);assert.match(store,/next\[index\]\.ipLabel\.flatMap\(Self\.publicIPRegion\)/);
 assert.doesNotMatch(store,/var (?:rawBody|headers|cookies?|responseBody):/i);
 assert.match(store,/"父评论标识"/);assert.match(store,/"点赞数"/);
});

test('iOS native contract: document-start install, page world, no message handler and bounded cancellation (static)',()=>{
 const code=browser();assert.match(code,/protocol-capture/);assert.match(code,/\.atDocumentStart/);assert.match(code,/forMainFrameOnly: true/);assert.match(code,/forMainFrameOnly: true, in: \.page/);
 assert.doesNotMatch(code,/addScriptMessageHandler|userContentController\.add\(/);
 assert.match(code,/__houmenProtocol/);assert.match(code,/\.stop\(\)/);assert.match(code,/generation = UUID\(\)/);
 assert.match(code,/row\.merge\(proof\.rowFields\) \{ _, verified in verified \}/);
 assert.match(code,/store\.save\(batch, requireRecentSource: true/);
});
