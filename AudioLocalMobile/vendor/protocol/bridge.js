// Browser-only bounded projection. Reads only the page's completed fetch/XHR observations.
// It does not fetch, scroll, click, sign, persist raw JSON, or infer age/contact information.
const BRIDGE_VERSION='houmen-protocol/0.1.7';
const MAX_SOURCES=8, MAX_ROWS_PER_SOURCE=200, MAX_ROWS_TOTAL=400, MAX_CACHE_BYTES=2*1024*1024;
const MAX_BODY=512*1024, CACHE_TTL=5*60*1000;
const caches=new Map();
let active=null, stopped=false, initialBound=false;
const diagnostic={processed:0,rejected:0,parseFailures:0,businessErrors:0,invalidRows:0,sourceConflicts:0,evicted:0};

function pagePlatform() {
  try {
    const u=new URL(window.location.href);
    if(u.protocol!=='https:'||u.username||u.password||u.port)return '';
    if(['www.douyin.com','douyin.com'].includes(u.hostname))return 'douyin';
    if(['www.xiaohongshu.com','xiaohongshu.com'].includes(u.hostname))return 'xiaohongshu';
  }catch(_){}
  return '';
}
function sourceKey(platform,id) {
  if(typeof id!=='string')return '';
  const valid=platform==='douyin'?/^[0-9]{10,30}$/.test(id)
    :platform==='xiaohongshu'?/^[a-fA-F0-9]{24}$/.test(id):false;
  return valid?platform+':'+(platform==='xiaohongshu'?id.toLowerCase():id):'';
}
function sourceTarget(platform,url) {
  if(typeof url!=='string'||url.length>1600)return null;
  try {
    const u=new URL(url);
    if(u.protocol!=='https:'||u.username||u.password||u.port||u.hash)return null;
    let m;
    if(platform==='douyin'&&['www.douyin.com','douyin.com'].includes(u.hostname)&&!u.search)
      m=/^\/video\/([0-9]{10,30})\/?$/.exec(u.pathname);
    if(platform==='xiaohongshu'&&['www.xiaohongshu.com','xiaohongshu.com'].includes(u.hostname))
      m=/^\/(?:explore|search_result|discovery\/item)\/([a-fA-F0-9]{24})\/?$/.exec(u.pathname);
    if(!m)return null;
    const id=platform==='xiaohongshu'?m[1].toLowerCase():m[1];
    return {platform,sourceId:id,key:sourceKey(platform,id),sourceUrl:sourceUrlFor(platform,id)};
  }catch(_){return null;}
}
function profileValid(platform,value) {
  if(typeof value!=='string'||value.length>500)return false;
  try {
    const u=new URL(value);if(u.protocol!=='https:'||u.username||u.password||u.port||u.search||u.hash)return false;
    return platform==='douyin'?u.hostname==='www.douyin.com'&&/^\/user\/[A-Za-z0-9_.-]{4,200}$/.test(u.pathname)
      :platform==='xiaohongshu'&&u.hostname==='www.xiaohongshu.com'&&/^\/user\/profile\/[a-fA-F0-9]{24}$/.test(u.pathname);
  }catch(_){return false;}
}
function bytes(value){try{return new TextEncoder().encode(value).length;}catch(_){return value.length*3;}}
function secondISO(value) {
  const d=evidenceDate(value);return d&&d.ms<=Date.now()?d.iso:'';
}
function entryFor(platform,id) {
  const key=sourceKey(platform,id);if(!key)return null;
  if(active&&(active.platform!==platform||(active.sourceId&&active.key!==key)))return null;
  let entry=caches.get(key);
  if(!entry){entry={platform,sourceId:platform==='xiaohongshu'?id.toLowerCase():id,source:null,rows:new Map(),
    commentsReady:false,explicitEmpty:false,endOfComments:false,paging:{cursor:'',hasMore:null,total:null},error:null,touched:Date.now()};caches.set(key,entry);}
  entry.touched=Date.now();return entry;
}
function trimCaches() {
  for(const [key,entry] of caches)if(Date.now()-entry.touched>CACHE_TTL){caches.delete(key);diagnostic.evicted++;}
  const size=()=>{
    let rows=0,total=0;for(const e of caches.values()){rows+=e.rows.size;total+=bytes(JSON.stringify({source:e.source,rows:[...e.rows.values()]}));}
    return {rows,total};
  };
  let s=size();
  while(caches.size>MAX_SOURCES||s.rows>MAX_ROWS_TOTAL||s.total>MAX_CACHE_BYTES){
    let oldest=null;for(const pair of caches)if(!oldest||pair[1].touched<oldest[1].touched)oldest=pair;
    if(!oldest)break;caches.delete(oldest[0]);diagnostic.evicted++;s=size();
  }
}
function endpointContext(value,platform) {
  if(typeof value!=='string'||value.length>2400)return null;
  try {
    const u=new URL(value);
    if(u.protocol!=='https:'||u.username||u.password||u.port)return null;
    const hosts=platform==='douyin'?['www.douyin.com','douyin.com']:['www.xiaohongshu.com','edith.xiaohongshu.com'];
    if(!hosts.includes(u.hostname))return null;
    const paths=platform==='douyin'?{
      '/aweme/v1/web/comment/list':'comment_list','/aweme/v1/web/comment/list/reply':'comment_reply','/aweme/v1/web/aweme/detail':'aweme_detail'
    }:{'/api/sns/web/v1/comment/page':'comment_page','/api/sns/web/v1/comment/sub/page':'comment_sub','/api/sns/web/v1/feed':'note_feed'};
    const endpoint=paths[u.pathname.replace(/\/$/,'')];if(!endpoint)return null;
    const context=captureContext(value,platform);
    return {endpoint,...context,url:u.href};
  }catch(_){return null;}
}
function setError(platform,id,state,code) {
  const e=entryFor(platform,id);if(e)e.error={state,code};
}
function projectComment(comment) {
  const platform=comment.platform, id=comment.sourceId;
  if(!sourceKey(platform,id)||!profileValid(platform,comment.profileUrl)||!comment.authorName||!comment.text||comment.unsafeNumericId)return null;
  const time=secondISO(comment.publishedAtISO);
  if(!time)return null;
  return {platform,sourceId:platform==='xiaohongshu'?id.toLowerCase():id,
    commentId:String(comment.commentId||'').slice(0,100),text:String(comment.text).slice(0,6000),
    authorName:String(comment.authorName).slice(0,100),authorId:String(comment.authorId||'').slice(0,200),
    profileUrl:comment.profileUrl,publicHandle:String(comment.publicHandle||'').slice(0,200),
    parentCommentId:String(comment.parentCommentId||'').slice(0,100),isReply:!!comment.isReply,
    publishedAt:'',publishedAtRaw:'',publishedAtISO:time,publishedTimeQuality:'exact',
    ipLabel:String(comment.ipLabel||'').slice(0,80),likeCount:String(comment.likeCount||'').slice(0,30),
    replyCount:String(comment.replyCount||'').slice(0,30),acquisition:'protocol_capture'};
}
function drain() {
  let records;try{records=capture.take();}catch(_){return;}
  if(stopped||!Array.isArray(records))return;
  for(const raw of records.slice(0,200)) {
    if(!raw||raw.platform!==pagePlatform()||typeof raw.body!=='string'||bytes(raw.body)>MAX_BODY){diagnostic.rejected++;continue;}
    const platform=raw.platform, context=endpointContext(raw.url,platform), request=endpointContext(raw.requestUrl||raw.url,platform);
    if(!context||!request||context.endpoint!==request.endpoint||raw.name!==context.endpoint){diagnostic.rejected++;continue;}
    if(active&&active.platform!==platform){diagnostic.rejected++;continue;}
    // Do not relabel data when a redirect changed the actual source.
    if(request.sourceId&&context.sourceId&&request.sourceId!==context.sourceId){diagnostic.sourceConflicts++;continue;}
    const id=context.sourceId||request.sourceId;
    if(active&&active.sourceId&&id&&sourceKey(platform,id)!==active.key){diagnostic.rejected++;continue;}
    diagnostic.processed++;
    const status=Number(raw.status);
    if([401,403,429].includes(status)){setError(platform,id,'blocked','platform_access_required');continue;}
    if([404,410].includes(status)){setError(platform,id,'skipped','source_unavailable');continue;}
    if(!Number.isInteger(status)||status<200||status>=300){diagnostic.rejected++;continue;}
    try {
      const payload=parsePayload(raw.body);
      if(businessError(payload)){diagnostic.businessErrors++;setError(platform,id,'blocked','platform_business_error');continue;}
      if(['aweme_detail','note_feed'].includes(context.endpoint)) {
        const variants=platform==='xiaohongshu'&&Array.isArray(payload?.data?.items)
          ?payload.data.items.slice(0,40).map(item=>({data:{items:[item]}})):[payload];
        for(const variant of variants){
          const detail=parseSource(variant,{platform,capturedAt:raw.at,captureUrl:context.url,now:Date.now()});
          if(!detail)continue;
          const e=entryFor(platform,detail.sourceId);if(!e)continue;
          // Repeated observation must not rejuvenate the source's original publication.
          if(!e.source||detail.publishedAtISO<e.source.publishedAtISO)e.source=detail;
        }
      }else{
        const parsed=parseComments(payload,{platform,endpoint:context.endpoint,captureUrl:context.url,includeReplies:true});
        if(parsed.pathKind!=='explicit'){diagnostic.parseFailures++;continue;}
        const e=entryFor(platform,parsed.sourceId||id);
        if(!e){diagnostic.rejected++;continue;}
        const mainPage=['comment_list','comment_page'].includes(context.endpoint);
        if(mainPage){
          e.commentsReady=true;e.paging=parsed.paging;e.explicitEmpty=parsed.empty===true&&e.rows.size===0;
          e.endOfComments=parsed.paging.hasMore===false;
          if(e.explicitEmpty&&parsed.paging.total===0)e.endOfComments=true;
          e.error=null;
        }
        for(const item of parsed.comments){
          if(sourceKey(platform,item.sourceId)!==sourceKey(platform,e.sourceId)){diagnostic.sourceConflicts++;continue;}
          const row=projectComment(item);if(!row){diagnostic.invalidRows++;continue;}
          const key=row.commentId?'id:'+row.commentId:'fallback:'+row.profileUrl+'|'+row.text+'|'+row.publishedAtISO;
          if(e.rows.has(key)||e.rows.size<MAX_ROWS_PER_SOURCE)e.rows.set(key,row);
          if(e.rows.size)e.explicitEmpty=false;
        }
      }
    }catch(error){
      if(['source_conflict','parent_conflict','invalid_capture_url'].includes(error?.kind)){
        diagnostic.sourceConflicts++;setError(platform,id,'blocked','source_mismatch');
      }else{diagnostic.parseFailures++;}
    }
  }
  trimCaches();
}
function beginTask(options={}) {
  const platform=options.platform, taskId=typeof options.taskId==='string'?options.taskId.slice(0,200):'';
  const target=options.sourceUrl?sourceTarget(platform,options.sourceUrl):{platform,sourceId:'',sourceUrl:'',key:''};
  if(!target||platform!==pagePlatform()||!taskId){stop();return {state:'blocked',code:'invalid_target',taskId};}
  const same=active&&active.platform===platform&&active.key===target.key&&active.taskId===taskId;
  if(same&&!stopped){drain();return {state:'ready',taskId};}
  if(!initialBound&&!stopped){drain();initialBound=true;}
  else{capture.beginTask();capture.clear();caches.clear();initialBound=true;}
  active={...target,taskId};stopped=false;
  for(const [key,e] of caches)if(e.platform!==platform||(target.key&&key!==target.key))caches.delete(key);
  return {state:'ready',taskId};
}
function stop(){stopped=true;capture.stop();capture.clear();caches.clear();}
function diagnosticSnapshot(code='') {
  let cachedRows=0;for(const e of caches.values())cachedRows+=e.rows.size;
  const rawStats=capture.stats||{};
  return {...diagnostic,cachedSources:caches.size,cachedRows,tooLarge:Number(rawStats.tooLarge)||0,
    budgetSkipped:Number(rawStats.budgetSkipped)||0,staleEpoch:Number(rawStats.staleEpoch)||0,code};
}
function read(options={}) {
  const target=sourceTarget(options.platform,options.sourceUrl);
  const empty=(state,code)=>({version:BRIDGE_VERSION,state,code,taskId:active?.taskId||'',sourceId:target?.sourceId||'',sourceUrl:target?.sourceUrl||'',
    sourceReady:false,commentsReady:false,rows:[],comments:[],paging:{cursor:'',hasMore:null,total:null},explicitEmpty:false,endOfComments:false,
    diagnostics:diagnosticSnapshot(code)});
  if(stopped)return empty('blocked','stopped');
  if(!target||options.platform!==pagePlatform())return empty('blocked','invalid_target');
  if(!active){const bound=beginTask({...options,taskId:options.taskId||'implicit'});if(bound.state==='blocked')return empty('blocked',bound.code);}
  if(active.platform!==target.platform||active.key!==target.key||(options.taskId&&options.taskId!==active.taskId))return empty('blocked','target_mismatch');
  drain();
  const e=caches.get(target.key);if(!e)return empty('waiting','awaiting_page_responses');
  if(e.error)return {...empty(e.error.state,e.error.code),commentsReady:e.commentsReady};
  const proof=e.source?toRows([{platform:e.platform,sourceId:e.sourceId}],{source:e.source,now:Date.now()})[0]:null;
  const sourceReady=proof?.sourceStatus==='verified';
  const rows=toRows([...e.rows.values()],{source:e.source,sourceTitle:e.source?.title||'',product:String(options.keyword||'').slice(0,60),now:Date.now()})
    .map(row=>({...row,publishedAt:'',publishedTimeQuality:'exact'}))
    .sort((a,b)=>b.publishedAtISO.localeCompare(a.publishedAtISO)||a.commentId.localeCompare(b.commentId));
  const evidence={};
  if(sourceReady)for(const key of ['sourcePublishedAt','sourcePublishedAtISO','sourcePublishedTimeQuality','sourceCheckedAt','sourceEarliestAtISO','sourcePolicy'])evidence[key]=proof[key];
  const state=sourceReady||e.commentsReady?'ready':'waiting';
  return {version:BRIDGE_VERSION,state,code:state==='waiting'?'awaiting_page_responses':'',taskId:active.taskId,
    sourceId:e.sourceId,sourceUrl:target.sourceUrl,sourceReady,commentsReady:e.commentsReady,
    ...evidence,source:sourceReady?{platform:e.platform,sourceId:e.sourceId,...evidence}:null,
    rows,comments:rows,paging:{...e.paging},explicitEmpty:e.explicitEmpty,endOfComments:e.endOfComments,
    diagnostics:diagnosticSnapshot()};
}
window.__houmenProtocol=Object.freeze({version:BRIDGE_VERSION,beginTask,stop,read});
if(window.__houmenProtocolInitialTask)beginTask(window.__houmenProtocolInitialTask);
// Continuously project and discard raw response bodies; no persistent storage or network is used.
if(typeof setInterval==='function')setInterval(()=>{if(!stopped)drain();},500);
