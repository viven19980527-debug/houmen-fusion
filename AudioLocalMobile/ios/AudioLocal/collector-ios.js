/* Visible public DOM only. No private endpoints, credentials, native bridge or login bypass.
   iOS-only Version 0.1.3: actual search hrefs, source-date evidence and unavailable states. */
function collectAudioPage(cfg) {
 'use strict';
 cfg=cfg||{};
 const $=(s,n=document)=>n.querySelector(s), all=(s,n=document)=>Array.from(n.querySelectorAll(s));
 const text=n=>String(n?.innerText??n?.textContent??'').trim();
 const visible=n=>{
  if(!n||n.closest('[aria-hidden="true"], [hidden]'))return false;
  try{for(let p=n;p;p=p.parentElement){const s=getComputedStyle(p);if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse')return false;}const r=n.getBoundingClientRect();return r.width>0&&r.height>0}catch{return false}
 };
 const visibleText=n=>{
  const walk=p=>{
   if(p.nodeType===3)return p.textContent||'';
   if(p.nodeType!==1||!visible(p)||/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(p.tagName))return '';
   return Array.from(p.childNodes).map(walk).join('');
  };
  return n?walk(n).trim():'';
 };
 // A collector-owned, source-scoped empty-state confirmation. No site state is inspected.
 const emptyKey='shengxunEmptyCommentsV013';
 const clearEmptyConfirmations=()=>{for(const n of all('[data-shengxun-empty-comments-v013]'))delete n.dataset[emptyKey];};
 function confirmEmptyComments(marker,scope,proof,eligible){
  if(!marker)return false;
  if(!eligible){delete marker.dataset[emptyKey];return false;}
  const now=Date.now();let state;
  try{state=JSON.parse(marker.dataset[emptyKey]||'null');}catch{}
  if(!state||state.scope!==scope||state.proof!==proof||!Number.isFinite(state.started)||!Number.isFinite(state.lastSeen)||now<state.lastSeen||now-state.lastSeen>5000){
   marker.dataset[emptyKey]=JSON.stringify({scope,proof,started:now,lastSeen:now,polls:1});return false;
  }
  state.lastSeen=now;state.polls=(state.polls||0)+1;marker.dataset[emptyKey]=JSON.stringify(state);
  return state.polls>=2&&now-state.started>=1000;
 }
 const limit=(v,f,max)=>Number.isFinite(Number(v))?Math.max(1,Math.min(max,Math.floor(Number(v)))):f;
 function link(v,kind){
  if(typeof v!=='string'||!v.trim())return '';
  try{const u=new URL(v,location.href);
   if(u.protocol!=='https:'||u.username||u.password||u.port&&!['443'].includes(u.port)||!['douyin.com','www.douyin.com'].includes(u.hostname))return '';
   if(kind==='video'&&!/^\/video\/\d{10,30}\/?$/.test(u.pathname))return '';
   if(kind==='profile'&&!/^\/user\/[\w.-]{4,200}\/?$/.test(u.pathname))return '';
   return u.origin+u.pathname;
  }catch{return ''}
 }
 const page=new URL(String(location.href));
 if(page.protocol!=='https:'||page.username||page.password||page.port&&page.port!=='443'||!/(^|\.)douyin\.com$/.test(page.hostname))
  return {state:'blocked',message:'当前不在受支持的抖音HTTPS页面，已停止'};
 const promptText=all('body *').filter(n=>visible(n)&&!n.closest('[data-e2e="comment-item"],[data-e2e="video-desc"],.VDYK8Xd7,h1,a[href*="/video/"],[id^="waterfall_item_"]')&&!Array.from(n.children).some(visible)).map(visibleText).filter(t=>t&&t.length<=180);
 if(promptText.some(t=>/请完成下方验证|请完成安全验证|安全验证|拖动滑块|请先完成验证/.test(t)))
  {clearEmptyConfirmations();return {state:'blocked',code:'verification',message:'平台要求验证码，已暂停；请本人完成后点继续，不自动处理验证码'};}
 if(promptText.some(t=>/登录后即可搜索更多精彩视频|请登录后查看评论|登录后才能查看评论/.test(t)))
  {clearEmptyConfirmations();return {state:'blocked',code:'login',message:'平台要求登录，请本人在下方页面登录后继续'};}

 // This state belongs to this collector and lives only on the rendered document.
 // It does not read site application stores, requests, credentials or hidden page data.
 function latestGate(options, fingerprint, explicitEmpty){
  const marker=document.documentElement, key='shengxunLatestV013', now=Date.now();
  const scope=String(cfg.keyword||'')+'|'+page.origin+page.pathname+'|window:'+options.sourceWindowDays;
  let state;try{state=JSON.parse(marker.dataset[key]||'null');}catch{}
  if(!state||state.scope!==scope||!Number.isFinite(state.started)||now<state.started||now-state.started>300000)
   state={scope,started:now,baseline:fingerprint,last:'',stable:0,changed:false,sawEmpty:!fingerprint,ready:false,opened:0};
  const save=()=>{marker.dataset[key]=JSON.stringify(state);};
  const waiting=message=>{save();return {state:'waiting',videos:[],latestOrderConfirmed:false,sourceWindowDays:options.sourceWindowDays,timeFilterApplied:options.timeLabel,message};};
  if(options.error){state.ready=false;save();return {state:'blocked',code:'latest_sort_unconfirmed',latestOrderConfirmed:false,message:options.error};}
  if(options.open){
   state.ready=false;
   if(state.opened>=3){save();return {state:'blocked',code:'latest_sort_unconfirmed',latestOrderConfirmed:false,message:'未能展开平台最新/时间筛选，请手动选择后重试'};}
   state.opened++;options.open();return waiting('正在展开平台筛选，尚未读取搜索结果');
  }
  state.opened=0;
  if(!options.latestSelected||!options.weekSelected){
   // Capture a fresh baseline before EACH change: a previous sort refresh cannot prove the time filter refreshed.
   state.baseline=fingerprint;state.changed=true;state.sawEmpty=!fingerprint;state.last='';state.stable=0;state.started=now;state.ready=false;state.sameSince=null;state.sameCount=0;
   (!options.latestSelected?options.latest:options.week).click();
   return waiting(!options.latestSelected?'正在选择最新发布，等待结果刷新':'正在选择指定时间筛选，等待结果刷新');
  }
  if(options.loading){
   state.ready=false;state.last='';state.stable=0;state.sameSince=null;state.sameCount=0;
   return waiting('平台仍显示正在加载，尚不读取搜索结果');
  }
  if(!fingerprint){state.sawEmpty=true;if(!explicitEmpty){state.ready=false;state.last='';state.stable=0;state.sameSince=null;state.sameCount=0;return waiting('最新/时间筛选已选中，等待搜索结果加载');}}
  if(state.changed&&!state.sawEmpty&&fingerprint===state.baseline){
   // Applying a date filter may legitimately leave exactly the same IDs. A fast DOM reload can
   // finish between polls. After exclusive latest/week selection, require a bounded visible
   // stable-sample proof (>=3 polls spanning >=4s, no loading), never claim site-wide exhaustiveness.
   if(!Number.isFinite(state.sameSince)){state.sameSince=now;state.sameCount=0;}
   state.sameCount=(state.sameCount||0)+1;
   if(state.sameCount<3||now-state.sameSince<4000){state.ready=false;return waiting('筛选已选中，等待相同结果在无加载状态下持续稳定');}
   state.orderingEvidence='selected_stable_sample';
  }else state.orderingEvidence=state.changed?'observed_result_refresh':'already_selected_stable';
  const current=fingerprint||'EXPLICIT_EMPTY';
  if(state.last!==current){state.last=current;state.stable=1;state.stableAt=now;state.ready=false;return waiting('等待最新/时间筛选结果稳定');}
  if(now-(state.stableAt||now)<1000)return waiting('等待搜索结果稳定');
  state.stable++;state.ready=state.stable>=2;save();
  return {state:state.ready?'ready':'waiting',latestOrderConfirmed:state.ready,orderingEvidence:state.ready?state.orderingEvidence:'',
   sourceWindowDays:options.sourceWindowDays,timeFilterApplied:options.timeLabel,
   message:state.ready?'平台最新排序及时间筛选已确认；仍需逐条核验原发布时间':'等待结果稳定'};
 }
 function advanceSearch(nodes){
  if(!nodes.length)return {state:'waiting',moved:false,reason:'no_search_results'};
  let scroller=nodes[0].parentElement;
  while(scroller&&scroller!==document.body){
   const css=getComputedStyle(scroller);
   if(/auto|scroll/.test(css.overflowY)&&scroller.scrollHeight>scroller.clientHeight+4&&typeof scroller.scrollBy==='function')break;
   scroller=scroller.parentElement;
  }
  if(!scroller||scroller===document.body){
   scroller=document.scrollingElement||document.documentElement;
   if(!scroller||scroller.scrollHeight<=scroller.clientHeight+4||typeof scroller.scrollBy!=='function')return {state:'ready',moved:false,reason:'no_scrollable_search_container'};
  }
  const before=scroller.scrollTop||0;scroller.scrollBy({top:Math.max(240,Math.round(scroller.clientHeight*0.8)),behavior:'auto'});
  return {state:'ready',moved:Math.abs((scroller.scrollTop||0)-before)>1,reason:'visible_search_scroll',latestOrderConfirmed:true};
 }

 if(['prepare_search','search','search_advance'].includes(cfg.command)){
  const sourceWindowDays=cfg.sourceWindowDays===undefined?7:cfg.sourceWindowDays;
  if(![7,30,90].includes(sourceWindowDays))return {state:'blocked',code:'invalid_source_window',latestOrderConfirmed:false,message:'来源窗口仅支持7、30或90天'};
  // Only observed controls: neither platform has a verified one-month option here.
  // For 30/90 days select visible unlimited UI, then native source evidence imposes the exact window.
  const timeLabel=sourceWindowDays===7?'一周内':'不限';
  if(!page.pathname.startsWith('/search/'))return {state:'waiting',videos:[],message:'等待关键词搜索页，不读取推荐视频'};
  let term='';try{term=decodeURIComponent(page.pathname.slice('/search/'.length))}catch{}
  if(!String(cfg.keyword||'').trim()||term!==String(cfg.keyword))return {state:'blocked',code:'source_mismatch',message:'当前搜索关键词与任务不一致，请重新开始'};
  const found=new Map(),root=$('#waterFallScrollContainer')||document;
  // A waterfall DOM id is a layout key, NOT a verified video id. Only navigate actual hrefs.
  for(const a of all('a[href*="/video/"]',root)){
   if(!visible(a)||a.closest('[data-e2e="comment-item"]'))continue;
   const card=a.closest('[id^="waterfall_item_"]');
   if(card&&(!$('.videoImage',card)||!/^\d{1,2}:\d{2}/m.test(text(card))))continue;
   const u=link(a.getAttribute('href'),'video');if(!u)continue;
   const id=new URL(u).pathname.split('/')[2];if(found.has(id))continue;
   // These two isolated fields were observed in the video-search tab on 2026-10-25.
   const title=$('.VDYK8Xd7',a), dates=all('.faDtinfi',a).filter(visible);
   const date=dates.length===1?dates[0]:null;
   const times=date?[...(date.matches('time[datetime]')?[date]:[]),...all('time[datetime]',date)].filter(visible):[];
   const dateLabel=text(date),raw=dateLabel.length<=200?dateLabel:'';
   found.set(id,{id,url:u,title:(text(title)||text(a)).slice(0,300),sourcePublishedAt:raw,
    sourcePublishedAtISO:times.length===1&&!/编辑|更新/.test(raw)?String(times[0].getAttribute('datetime')||'').slice(0,80):''});
  }
  const toolbars=all('#search-toolbar-container').filter(visible);
  if(toolbars.length!==1)return {state:'blocked',code:'latest_sort_unconfirmed',message:'未找到唯一搜索筛选栏，不从综合结果采集',latestOrderConfirmed:false};
  const toolbar=toolbars[0], toggles=all('.jjU9T0dQ',toolbar).filter(visible);
  const sortLabels=all('._tawtVou',toolbar).filter(n=>visible(n)&&text(n)==='排序依据');
  const timeLabels=all('._tawtVou',toolbar).filter(n=>visible(n)&&text(n)==='发布时间');
  let options;
  if(!sortLabels.length&&!timeLabels.length&&toggles.length===1){
   options={open:()=>{const toggle=toggles[0];if(typeof MouseEvent==='function'){toggle.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));toggle.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false}));}else toggle.click();}};
  }else if(sortLabels.length!==1||timeLabels.length!==1){options={error:'最新/时间筛选结构不唯一，未读取结果'};}
  else{
   const sort=all('span[data-index1="0"]',sortLabels[0].parentElement).filter(visible);
   const times=all('span[data-index1="1"]',timeLabels[0].parentElement).filter(visible);
   const latest=sort.filter(n=>n.getAttribute('data-index2')==='1'&&text(n)==='最新发布');
   const week=times.filter(n=>n.getAttribute('data-index2')===(sourceWindowDays===7?'2':'0')&&text(n)===timeLabel);
   const sa=sort.filter(n=>n.classList.contains('sDNqBVWH')),ta=times.filter(n=>n.classList.contains('sDNqBVWH'));
   options=latest.length===1&&week.length===1&&sa.length<=1&&ta.length<=1?
    {latest:latest[0],week:week[0],latestSelected:sa.length===1&&sa[0]===latest[0],weekSelected:ta.length===1&&ta[0]===week[0]}:
    {error:'无法唯一确认最新发布和指定时间选项，未读取结果'};
  }
  const explicitEmpty=promptText.some(t=>/^(暂无搜索结果|没有找到相关结果|暂时没有找到相关结果|未找到相关视频)$/.test(t));
  options.loading=promptText.some(t=>/^(加载中[.。…]*|正在加载[.。…]*|搜索中[.。…]*)$/.test(t))||all('[aria-busy="true"]').some(n=>visible(n)&&!n.closest('[data-e2e="comment-item"],[data-e2e="video-desc"],.VDYK8Xd7,a[href*="/video/"]'));
  options.sourceWindowDays=sourceWindowDays;options.timeLabel=timeLabel;
  const gate=latestGate(options,[...found.keys()].join('|'),explicitEmpty);
  if(gate.state!=='ready')return gate;
  if(cfg.command==='prepare_search')return gate;
  if(cfg.command==='search_advance')return {...advanceSearch(all('a[href*="/video/"]',root).filter(n=>visible(n)&&link(n.getAttribute('href'),'video'))),sourceWindowDays,timeFilterApplied:timeLabel};
  const videos=[...found.values()].slice(0,limit(cfg.maxCandidates,40,40));
  return {state:videos.length||explicitEmpty?'ready':'waiting',videos,found:found.size,explicitEmpty,latestOrderConfirmed:true,sourceWindowDays,timeFilterApplied:timeLabel,
   message:videos.length?'已按平台最新及指定时间筛选读取候选，原生仍逐条核验窗口内来源日期':'平台明确没有符合筛选的搜索结果'};
 }
 const source=link(cfg.sourceUrl,'video');
 const currentId=page.pathname.match(/^\/video\/(\d+)\/?$/)?.[1]||page.searchParams.get('modal_id');
 // This file is iOS-only. Android retains its separate, unchanged shared collector.
 if(source&&currentId!==new URL(source).pathname.split('/')[2])
  return {state:'blocked',code:'source_mismatch',message:'当前视频与任务来源不一致，未保存错误来源'};
 // Recognize a platform error screen, not user-written titles/comments containing these words.
 const unavailable=all('body *').some(n=>visible(n)&&!Array.from(n.children).some(visible)&&
  !n.closest('[data-e2e="comment-item"], [data-e2e="video-desc"], .VDYK8Xd7, h1, a[href*="/video/"], [id^="waterfall_item_"]')&&
  /^(你要观看的视频不存在|视频已删除|该视频已删除|视频暂时无法观看|该视频暂时无法观看|作品不存在)$/.test(text(n)));
 if(unavailable&&['source','open','read','advance'].includes(cfg.command))
  return {state:'skipped',code:'source_unavailable',message:'平台显示该视频不可用，跳过此条，不再等待评论区'};
 if(cfg.command==='source'){
  if(!source)return {state:'blocked',code:'invalid_source',message:'来源视频地址无效'};
  // Live-observed original-publication node. Modal players can contain multiple unrelated sources.
  if(!/^\/video\/\d+\/?$/.test(page.pathname))return {state:'skipped',code:'source_time_unknown',message:'请打开单个视频详情核验原发布时间'};
  const candidates=all('[data-e2e="detail-video-publish-time"]').filter(n=>visible(n)&&
   !n.closest('[data-e2e="comment-item"],[data-e2e="comment-list"],[data-e2e="video-desc"],.VDYK8Xd7,h1,a[href*="/video/"],[id^="waterfall_item_"]'));
  if(candidates.length===1){
   const node=candidates[0],label=text(node);
   const raw=label.replace(/^发布时间\s*[:：]\s*/,'');
   if(!label||!raw||/^(加载中|正在加载)[.…]*$/.test(raw))return {state:'waiting',code:'source_loading',message:'来源发布时间尚在加载，继续等待'};
   const times=[...(node.matches('time[datetime]')?[node]:[]),...all('time[datetime]',node)].filter(visible);
   const iso=times.length===1?String(times[0].getAttribute('datetime')||''):'';
   if(/^发布时间\s*[:：]/.test(label)&&raw&&raw.length<=200&&iso.length<=80&&!/编辑|更新|修改/.test(raw))return {state:'ready',sourcePublishedAt:raw,sourcePublishedAtISO:iso};
  }
  if(!candidates.length)return {state:'waiting',code:'source_loading',message:'视频已开始加载，等待原发布时间；到时限仍未知则跳过'};
  return {state:'skipped',code:'source_time_unknown',message:'原发布时间字段歧义或无效，跳过，不用评论时间代替'};
 }
 const lists=all('[data-e2e="comment-list"]').filter(visible);
 if(lists.length>1)return {state:'blocked',code:'ambiguous_comments',message:'检测到多个评论区，无法确认来源，请打开单个视频再继续'};
 const root=lists[0]||document, nodes=all('[data-e2e="comment-item"]',root).filter(visible);
 // Only standalone UI inside this one visible comment list can prove zero. A video
 // title, body-wide count, user comment or unknown layout can never end collection.
 const list=lists[0];
 const userContent='[data-e2e="comment-item"],[data-e2e="video-desc"],.VDYK8Xd7,h1,a[href*="/video/"],[id^="waterfall_item_"],a[href*="/user/"]';
 const uiNodes=list?all('*',list).filter(n=>visible(n)&&!n.closest(userContent)&&!all(userContent,n).some(visible)):[];
 const labels=[...new Set(uiNodes.map(visibleText).filter(t=>t&&t.length<=100))];
 const counts=labels.map(t=>t.match(/^全部评论\s*[（(]\s*([0-9]+(?:\.[0-9]+)?\s*[万千亿wWkK]?)\s*[)）]$/)?.[1]).filter(t=>t!==undefined);
 const positiveCount=counts.some(t=>!/^0$/.test(t.trim()));
 const zeroLabels=labels.filter(t=>/^全部评论\s*[（(]\s*0\s*[)）]$/.test(t)||/^(暂无评论|还没有评论)$/.test(t));
 const commentLoading=!!list&&(!!list.closest('[aria-busy="true"]')||uiNodes.some(n=>n.matches('[aria-busy="true"]')||/^(加载中[.。…]*|正在加载[.。…]*|评论加载中[.。…]*)$/.test(visibleText(n))));
 const zeroCandidate=!!list&&!nodes.length&&!commentLoading&&!positiveCount&&zeroLabels.length>0;
 const explicitZero=confirmEmptyComments(list,source||String(currentId||''),zeroLabels.sort().join('|'),zeroCandidate);
 if(cfg.command==='open'){
  if(nodes.length||explicitZero)return {state:'ready',explicitZero};
  if(zeroCandidate)return {state:'waiting',explicitZero:false,reason:'empty_confirmation_pending',message:'平台显示暂无评论，等待短暂稳定确认'};
  const buttons=all('[data-e2e="feed-comment-icon"]').filter(visible);
  const button=buttons.length===1?buttons[0]:buttons.find(n=>{const r=n.getBoundingClientRect();return r.top>=0&&r.left>=0&&r.bottom<=(document.documentElement.clientHeight||Infinity)&&r.right<=(document.documentElement.clientWidth||Infinity)});
  if(button){if(button.dataset.audioLocalClicked!=='1'){button.dataset.audioLocalClicked='1';button.click()}return {state:'waiting',message:'正在打开公开评论区'}}
  return {state:'waiting',message:'等待视频评论区或评论按钮'};
 }
 if(!source)return {state:'blocked',code:'invalid_source',message:'来源视频地址无效'};
 if(cfg.command==='read'){
  const rows=[], ids=new Set();let skipped=0,folded=0;
  for(const n of nodes){
   const info=all('.comment-item-info-wrap',n).find(x=>x.closest('[data-e2e="comment-item"]')===n), a=info&&$('a[href*="/user/"]',info);
   if(!a){skipped++;continue}
   const profile=link(a.href,'profile'), name=text(a).replace(/\s*作者$/,'').trim().slice(0,100);
   const contentNode=info.nextElementSibling;
   if(!contentNode||contentNode.closest('[data-e2e="comment-item"]')!==n||$('[data-e2e="comment-item"], .comment-item-info-wrap',contentNode)){skipped++;continue}
   let content=text(contentNode);
   // Emoji are visible content too; never substitute body/card text or a reply for a missing comment.
   if(!content)content=all('img[alt]',contentNode).map(img=>img.getAttribute('alt')).filter(Boolean).join('');
   content=content.slice(0,6000);
   if(/^(该评论被折叠|评论已删除|该评论已删除|评论暂不可见)$/.test(content)){folded++;continue}
   if(!profile||!name||!content){skipped++;continue}
   const id=all('[id^="tooltip_"]',n).find(x=>x.closest('[data-e2e="comment-item"]')===n)?.id.replace('tooltip_','')||'', dedup=id||profile+'|'+content;
   if(ids.has(dedup))continue;ids.add(dedup);
   const timeNode=contentNode.nextElementSibling;
   const timeEl=timeNode&&(timeNode.matches('time[datetime]')?timeNode:$('time[datetime]',timeNode));
   const ownTime=timeEl&&visible(timeEl)&&!/编辑|更新/.test(text(timeNode))&&timeEl.closest('[data-e2e="comment-item"]')===n;
   rows.push({publishedAtISO:ownTime?String(timeEl.getAttribute('datetime')||'').slice(0,80):'',commentId:id.slice(0,100),platform:'douyin',industry:String(cfg.industry||'general').slice(0,30),product:String(cfg.keyword||'').slice(0,60),
    text:content,authorName:name,authorId:new URL(profile).pathname.split('/user/')[1],profileUrl:profile,
    publishedAt:text(contentNode?.nextElementSibling).slice(0,200),sourceUrl:source,
    sourceTitle:String(cfg.sourceTitle||text($('h1'))||'').slice(0,300),acquisition:'local_webview',contactSnippet:'',contactSourceUrl:''});
   if(rows.length===limit(cfg.maxComments,50,200))break;
  }
  return {state:nodes.length||explicitZero?'ready':'waiting',comments:rows,explicitZero,
   diagnostics:{loaded:nodes.length,parsed:rows.length,skipped,folded},
   message:rows.length?'仅保存平台已经加载的公开评论，非全量':explicitZero?'平台零评论状态已稳定确认':nodes.length?'已检查本批评论，均折叠或无法解析；继续有限翻页':zeroCandidate?'暂无评论状态待稳定确认':'评论尚未加载，等待至本视频时限'};
 }
 if(cfg.command==='advance'){
  if(explicitZero)return {state:'ready',moved:false,reason:'explicit_zero'};
  if(!list||!nodes.length)return {state:'waiting',moved:false,reason:'no_comment_list'};
  let scroller=list;
  while(scroller&&scroller!==document.body){
   const css=getComputedStyle(scroller);
   if(/auto|scroll/.test(css.overflowY)&&scroller.scrollHeight>scroller.clientHeight+4)break;
   scroller=scroller.parentElement;
  }
  if(!scroller||scroller===document.body){
   scroller=document.scrollingElement||document.documentElement;
   const last=nodes[nodes.length-1];
   const before=scroller.scrollTop||0;
   last.scrollIntoView({block:'end',behavior:'auto'});
   scroller.scrollBy({top:Math.max(240,Math.round((scroller.clientHeight||400)*0.7)),behavior:'auto'});
   return {state:'ready',moved:Math.abs((scroller.scrollTop||0)-before)>1,reason:'document_scroll'};
  }
  const before=scroller.scrollTop||0;
  scroller.scrollBy({top:Math.max(240,Math.round(scroller.clientHeight*0.8)),behavior:'auto'});
  return {state:'ready',moved:Math.abs((scroller.scrollTop||0)-before)>1,reason:'comment_scroll'};
 }
 return {state:'blocked',message:'不支持的读取命令'};
}
