/* Experimental iOS Xiaohongshu adapter; synthetic fixtures, NOT live verified.
 * Selector evidence: original author's public DOM notes, not this session's browser:
 * https://github.com/yichuanhu/xhs-skill/blob/main/references/browse.md
 * Documented candidates: .note-item a.cover, [class*=title], #detail-title,
 * #detail-desc, .comment-item (comment-{hex}), .name, .content, .date, .total.
 * Generic a[href], span, time[datetime] and role=dialog checks below are conservative
 * structural guards, NOT claims that those extra structures were observed live.
 * Reads rendered public DOM only. No requests, credentials, hidden state, token
 * generation, account actions, contact/age inference or reply expansion. Only observed search filter controls are clicked.
 */
function collectXiaohongshuPage(cfg) {
 'use strict';
 cfg=cfg||{};
 const all=(s,n=document)=>Array.from(n.querySelectorAll(s));
 const visible=n=>{
  if(!n||n.nodeType!==1||n.closest('[hidden],[aria-hidden="true"]'))return false;
  try{
   for(let p=n;p;p=p.parentElement){const s=getComputedStyle(p);if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse')return false;}
   const r=n.getBoundingClientRect();return r.width>0&&r.height>0;
  }catch{return false;}
 };
 // Do not include hidden children or a nested reply in a parent's field.
 const text=n=>{
  if(!visible(n))return '';
  const owner=n.closest('.comment-item');
  const walk=p=>{
   if(p.nodeType===3)return p.textContent||'';
   if(p.nodeType!==1||!visible(p)||/^(SCRIPT|STYLE|NOSCRIPT|TEMPLATE)$/.test(p.tagName))return '';
   if(owner&&p!==owner&&p.matches('.comment-item'))return '';
   return Array.from(p.childNodes).map(walk).join('');
  };
  return walk(n).trim();
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
 const cap=(v,f,max)=>Number.isFinite(Number(v))?Math.max(1,Math.min(max,Math.floor(Number(v)))):f;
 const blocked=(code,message)=>({state:'blocked',code,message});
 const safeOrigin=u=>u.protocol==='https:'&&!u.username&&!u.password&&(!u.port||u.port==='443')&&['www.xiaohongshu.com','xiaohongshu.com'].includes(u.hostname);
 const noteID=u=>u.pathname.match(/^\/(?:explore|search_result|discovery\/item)\/([0-9a-f]{24})\/?$/i)?.[1].toLowerCase()||'';
 function noteLink(value){
  try{
   if(typeof value!=='string'||!value.trim())return '';
   const u=new URL(String(value),location.href);
   if(!safeOrigin(u)||!noteID(u)||u.hash||u.href.length>1600)return '';
   for(const key of u.searchParams.keys()){
    if(!['xsec_token','xsec_source','source'].includes(key)||u.searchParams.getAll(key).length!==1)return '';
    const val=u.searchParams.get(key)||'';
    if(key==='source'&&!['web_explore_feed','web_user_page'].includes(val))return '';
    if((key==='xsec_token'&&!val)||val.length>(key==='xsec_token'?1024:80)||/[\s\u0000-\u001f\u007f]/.test(val))return '';
   }
   // Preserve the already-loaded href and its allowed navigation token exactly as URL serializes it.
   return u.href;
  }catch{return '';}
 }
 function profileLink(value){
  try{
   if(typeof value!=='string'||!value||/[\s\u0000-\u001f\u007f\\]/.test(value)||/%(?![0-9a-f]{2})/i.test(value))return '';
   if(/^[a-z][a-z0-9+.-]*:/i.test(value)&&!/^https:\/\/(?:www\.)?xiaohongshu\.com(?::443)?\//i.test(value))return '';
   const u=new URL(value,location.href);
   if(!safeOrigin(u)||!/^\/user\/profile\/[0-9a-f]{24}\/?$/i.test(u.pathname)||u.href.includes('#')||u.href.length>1600||u.href.endsWith('?'))return '';
   const kept=[],seen=new Set();
   for(const part of (u.search?u.search.slice(1).split('&'):[])){
    const separator=part.indexOf('=');if(separator<1)return '';
    const key=part.slice(0,separator),rawValue=part.slice(separator+1);
    if(!['xsec_token','xsec_source','channel_type','parent_page_channel_type'].includes(key)||seen.has(key))return '';
    seen.add(key);
    const decoded=decodeURIComponent(rawValue);
    if(/[\s\u0000-\u001f\u007f]/.test(decoded))return '';
    if(key==='channel_type'){if(decoded!=='web_search_result_notes')return '';continue;}
    if(key==='parent_page_channel_type'){if(!['web_profile_board','web_user_board'].includes(decoded))return '';continue;}
    if((key==='xsec_token'&&!decoded)||decoded.length>(key==='xsec_token'?1024:80))return '';
    // Preserve the existing encoded navigation value byte-for-byte; never manufacture it.
    kept.push(part);
   }
   // Navigation retains allowed fields. Native profileIdentity still groups the canonical path.
   return 'https://www.xiaohongshu.com'+u.pathname.replace(/\/$/,'')+(kept.length?'?'+kept.join('&'):'');
  }catch{return '';}
 }
 let page;
 try{page=new URL(String(location.href));}catch{return blocked('invalid_page','无法识别当前页面地址');}
 if(!safeOrigin(page))return blocked('invalid_origin','当前不在小红书官方 HTTPS 页面，已停止');
 if(/^\/login(?:\/|$)/.test(page.pathname))return blocked('login','平台要求登录，请本人完成后继续；不会自动处理登录');
 // Inspect visible UI prompts only, excluding user-written cards, descriptions and comments.
 const prompts=all('body *').filter(n=>visible(n)&&!n.closest('.comment-item,.note-item,#detail-desc,#detail-title')&&
  !Array.from(n.children).some(visible)).map(text).filter(t=>t&&t.length<=180);
 if(prompts.some(t=>/请完成.*验证|安全验证|拖动滑块|滑块验证|验证后继续|访问频繁|操作频繁|异常访问|访问受限/.test(t)))
  {clearEmptyConfirmations();return blocked('verification','平台要求验证或限制访问，已暂停；请本人在平台完成，不自动绕过');}
 if(prompts.some(t=>/登录后.*(?:查看|更多|搜索)|登录查看更多|请先登录|扫码登录|手机号登录|登录小红书/.test(t)))
  {clearEmptyConfirmations();return blocked('login','平台要求登录，请本人完成后继续；不会自动处理登录');}

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
  if(options.pending){
   // A valid search document can finish native navigation before its SPA controls hydrate.
   // Invalidate any previous ready proof; the caller's existing deadline bounds this wait.
   state.ready=false;state.last='';state.stable=0;state.sameSince=null;state.sameCount=0;
   return waiting(options.pending);
  }
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
  if(!['/search_result','/search_result_ai'].includes(page.pathname))return {state:'waiting',videos:[],message:'等待小红书关键词搜索页，不读取推荐内容'};
  let term=page.searchParams.get('keyword')||'';
  if(term!==String(cfg.keyword||'')&&page.pathname==='/search_result_ai'){try{term=decodeURIComponent(term);}catch{}}
  const inputs=all('#search-input-ai,#search-input').filter(visible);
  const inputValue=inputs.length===1?String(inputs[0].value||''):null;
  if(!String(cfg.keyword||'').trim()||page.searchParams.getAll('keyword').length!==1||term!==String(cfg.keyword)||inputs.length>1||(inputValue!==null&&inputValue.trim()&&inputValue!==String(cfg.keyword)))
   return blocked('source_mismatch','当前搜索关键词与任务不一致');
  if(inputValue!==null&&!inputValue.trim())return latestGate({pending:'搜索地址已匹配，等待平台搜索框完成加载',sourceWindowDays,timeLabel},'',false);
  const found=new Map();
  for(const card of all('.note-item').filter(visible)){
   const covers=all('a.cover',card).filter(a=>visible(a)&&a.closest('.note-item')===card);
   const links=[...new Set(covers.map(a=>noteLink(a.getAttribute('href')||'')).filter(Boolean))];
   if(links.length!==1)continue;
   const url=links[0], id=noteID(new URL(url));
   const title=all('[class*="title"]',card).find(n=>visible(n)&&n.closest('.note-item')===card);
   const dates=all('.time',card).filter(n=>visible(n)&&n.closest('.note-item')===card);
   const raw=dates.length===1?text(dates[0]):'';
   if(!found.has(id))found.set(id,{id,url,title:text(title).slice(0,300),sourcePublishedAt:raw.length<=200?raw:'',sourcePublishedAtISO:''});
  }
  const wrappers=all('.filters-wrapper').filter(visible), toggles=all('.filter').filter(n=>visible(n)&&!n.closest('.note-item,.comment-item')&&all('span',n).some(s=>visible(s)&&['筛选','已筛选'].includes(text(s))));
  let options;
  if(!wrappers.length&&!toggles.length)options={pending:'搜索地址已匹配，等待平台筛选控件加载'};
  else if(!wrappers.length&&toggles.length===1)options={open:()=>{
   // Live desktop UI opens on mouse entry, not click. Attempt normal DOM events only;
   // latestGate limits retries and requires the real unique menu on a later poll.
   const toggle=toggles[0];
   if(typeof MouseEvent==='function'){
    toggle.dispatchEvent(new MouseEvent('mouseover',{bubbles:true}));
    toggle.dispatchEvent(new MouseEvent('mouseenter',{bubbles:false}));
   }else toggle.click();
  }};
  else if(wrappers.length!==1)options={error:'无法确认唯一小红书筛选栏，未读取综合结果'};
  else{
   const groups=all('.filters',wrappers[0]).filter(visible);
   const named=name=>groups.filter(n=>Array.from(n.children).some(c=>c.tagName==='SPAN'&&visible(c)&&text(c)===name));
   const sg=named('排序依据'),tg=named('发布时间');
   if(sg.length!==1||tg.length!==1)options={error:'无法确认小红书排序和发布时间筛选组'};
   else{
    const sort=all('.tag-container .tags',sg[0]).filter(visible),times=all('.tag-container .tags',tg[0]).filter(visible);
    const latest=sort.filter(n=>text(n)==='最新'),week=times.filter(n=>text(n)===timeLabel);
    const sa=sort.filter(n=>n.classList.contains('active')),ta=times.filter(n=>n.classList.contains('active'));
    options=latest.length===1&&week.length===1&&sa.length<=1&&ta.length<=1?
     {latest:latest[0],week:week[0],latestSelected:sa.length===1&&sa[0]===latest[0],weekSelected:ta.length===1&&ta[0]===week[0]}:
     {error:'小红书最新或指定时间状态不唯一，未读取结果'};
   }
  }
  const explicitEmpty=prompts.some(t=>/^(没有找到相关内容|暂无搜索结果|没有找到相关笔记|未找到相关笔记|暂时没有找到你想要的内容)$/.test(t));
  options.loading=prompts.some(t=>/^(加载中[.。…]*|正在加载[.。…]*|搜索中[.。…]*)$/.test(t))||all('[aria-busy="true"]').some(n=>visible(n)&&!n.closest('.note-item,.comment-item,#detail-title,#detail-desc'));
  options.sourceWindowDays=sourceWindowDays;options.timeLabel=timeLabel;
  const gate=latestGate(options,[...found.keys()].join('|'),explicitEmpty);
  if(gate.state!=='ready')return gate;
  if(cfg.command==='prepare_search')return gate;
  if(cfg.command==='search_advance')return {...advanceSearch(all('.note-item').filter(visible)),sourceWindowDays,timeFilterApplied:timeLabel};
  const videos=[...found.values()].slice(0,cap(cfg.maxCandidates,40,40));
  return {state:videos.length||explicitEmpty?'ready':'waiting',videos,found:found.size,explicitEmpty,latestOrderConfirmed:true,sourceWindowDays,timeFilterApplied:timeLabel,
   message:videos.length?'平台最新/指定时间筛选已确认，原生逐条核验窗口内笔记原发布时间':'平台明确没有符合筛选的笔记'};
 }
 if(!['source','open','read','advance'].includes(cfg.command))return blocked('unsupported_command','不支持的读取命令');
 const source=noteLink(cfg.sourceUrl||'');
 if(!source)return blocked('invalid_source','笔记来源地址无效，未读取评论');
 const wanted=noteID(new URL(source)), current=noteID(page);
 if(current&&(!noteLink(page.href)||current!==wanted))return blocked('source_mismatch','当前笔记与任务来源不一致');
 if(prompts.some(t=>/^(笔记已删除|该笔记已删除|笔记不存在|该笔记不存在|当前笔记无法浏览|笔记暂时无法查看|该笔记暂时无法查看)$/.test(t)))
  return {state:'skipped',code:'source_unavailable',message:'平台显示此笔记不可用，跳过此条'};
 const titles=all('#detail-title').filter(visible), descriptions=all('#detail-desc').filter(visible);
 const markers=[...titles,...descriptions];
 if(titles.length>1||descriptions.length>1)return blocked('ambiguous_details','存在多个详情区，无法确认评论来源');
 if(!markers.length)return {state:'waiting',message:'等待可识别笔记详情，不从搜索卡片或推荐区读取评论'};
 const dialogs=all('[role="dialog"]').filter(n=>visible(n)&&markers.some(m=>n.contains(m)));
 const independentDialogs=dialogs.filter(n=>!dialogs.some(other=>other!==n&&other.contains(n)));
 if(independentDialogs.length>1)return blocked('ambiguous_details','存在多个详情弹层，无法确认评论来源');
 // All source, comment-count, comment and scroll operations share this exact hard boundary.
 function resolveDetailBoundary(){
  const notes=all('#noteContainer').filter(n=>visible(n)&&markers.every(m=>n.contains(m)));
  if(notes.length>1)return {error:'存在多个笔记详情容器，无法确认来源'};
  if(notes.length===1)return {node:notes[0]};
  const exactDialogs=independentDialogs.filter(n=>markers.every(m=>n.contains(m)));
  if(exactDialogs.length===1)return {node:exactDialogs[0]};
  const articles=all('article').filter(n=>visible(n)&&markers.every(m=>n.contains(m)));
  return articles.length===1?{node:articles[0]}:{node:null};
 }
 const boundary=resolveDetailBoundary();
 if(boundary.error)return blocked('ambiguous_details',boundary.error);
 const detailBoundary=boundary.node;
 if(!detailBoundary)return {state:'waiting',code:'source_loading',message:'等待唯一笔记详情容器，不读取旁栏或背景内容'};
 if(!current){
  const ids=new Set(all('a[href]',detailBoundary).filter(a=>visible(a)&&!a.closest('.note-item,.comment-item'))
   .map(a=>noteLink(a.getAttribute('href')||'')).filter(Boolean).map(u=>noteID(new URL(u))));
  if(ids.size!==1||!ids.has(wanted))return blocked('unconfirmed_source','详情没有唯一匹配的公开笔记链接');
 }
 if(cfg.command==='source'){
  const loading=all('*',detailBoundary).some(n=>visible(n)&&!n.closest('.comment-item,#detail-title,#detail-desc')&&!Array.from(n.children).some(visible)&&/^(加载中|加载中\.{0,3}|正在加载[.…]*)$/.test(text(n)));
  if(loading)return {state:'waiting',code:'source_loading',message:'笔记详情仍在加载，不把临时刚刚当作发布时间'};
  let scope=markers[0].parentElement;
  while(scope&&detailBoundary.contains(scope)&&!markers.every(m=>scope.contains(m)))scope=scope.parentElement;
  if(!scope||!detailBoundary.contains(scope))return blocked('ambiguous_details','发布时间详情范围不明确，未读取');
  let metadataScope=null;
  for(let n=scope;n&&detailBoundary.contains(n);n=n.parentElement){
   if(all('.date',n).some(d=>visible(d)&&!d.closest('.comment-item,.note-item,#detail-title,#detail-desc'))){metadataScope=n;break;}
   if(n===detailBoundary)break;
  }
  const dates=metadataScope?all('.date',metadataScope).filter(n=>visible(n)&&!n.closest('.comment-item,.note-item,#detail-title,#detail-desc')):[];
  if(dates.length===1){
   const date=dates[0],label=text(date);
   if(!label||label==='刚刚'||/^(加载中|正在加载)[.…]*$/.test(label))return {state:'waiting',code:'source_loading',message:'笔记原发布时间仍在加载，暂不使用临时显示值'};
   let raw=label,normalization='';
   // Live-observed shapes: #noteContainer .bottom-container > span.date or > .bottom-left > span.date =
   // "昨天 12:16 广东" / "2天前 广东". Only this exact metadata structure and a supported
   // date prefix + known province-level short label are separable; native validates dates.
   // No MM-DD year inference or arbitrary trailing prose truncation.
   const dateParent=date.parentElement;
   const observedDatePlacement=dateParent?.matches('.bottom-container')||
    (dateParent?.matches('.bottom-left')&&dateParent.parentElement?.matches('.bottom-container'));
   if(label.length<=200&&date.matches('span.date')&&observedDatePlacement){
    const separate=label.match(/^((?:[0-9]{1,8}\s*(?:分钟|小时|天)前|刚刚|(?:今天|昨天|前天)(?:\s*(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?)?|[0-9]{4}-[0-9]{1,2}-[0-9]{1,2}(?:\s+(?:[01]?\d|2[0-3]):[0-5]\d(?::[0-5]\d)?)?))\s+(北京|天津|河北|山西|内蒙古|辽宁|吉林|黑龙江|上海|江苏|浙江|安徽|福建|江西|山东|河南|湖北|湖南|广东|广西|海南|重庆|四川|贵州|云南|西藏|陕西|甘肃|青海|宁夏|新疆|台湾|香港|澳门)$/);
    if(separate){raw=separate[1];normalization='xhs_bottom_date_region';}
   }
   if(raw==='刚刚')return {state:'waiting',code:'source_loading',message:'笔记原发布时间仍在加载，暂不使用临时显示值'};
   const times=[...(date.matches('time[datetime]')?[date]:[]),...all('time[datetime]',date)].filter(visible);
   // Native verifies the original date and the selected 7/30/90-day source window.
   if(raw&&label.length<=200&&raw!=='刚刚'&&!/编辑|更新|修改/.test(label))return {state:'ready',sourcePublishedAt:raw,
    sourcePublishedAtISO:times.length===1?String(times[0].getAttribute('datetime')||'').slice(0,80):'',
    ...(normalization?{sourcePublishedAtLabel:label,sourceTimeNormalization:normalization}:{})};
  }
  if(!dates.length)return {state:'waiting',code:'source_loading',message:'笔记详情已出现，等待原发布时间；到时限仍未知则跳过'};
  return {state:'skipped',code:'source_time_unknown',message:'笔记原发布时间歧义或无效，跳过；不以评论或编辑时间替代'};
 }
 // Live empty-state evidence is also bounded by the confirmed detail, never body text.
 const userContent='.comment-item,.note-item,#detail-title,#detail-desc';
 const emptyPrompts=all('.comments-el > .no-comments > .no-comments-text',detailBoundary).filter(n=>{
  if(!visible(n)||n.closest(userContent))return false;
  const actions=all('.focus-comments',n).filter(visible);
  return actions.length===1&&text(actions[0])==='点击评论'&&text(n).replace(/\s+/g,'')==='这是一片荒地点击评论';
 });
 // Only climb within the confirmed note. A sibling sidebar's comments/total never qualify.
 let root=markers[0];
 while(root&&detailBoundary.contains(root)&&(!markers.every(m=>root.contains(m))||
  (!all('.comment-item,.total',root).some(visible)&&!emptyPrompts.some(n=>root.contains(n))))){
  if(root===detailBoundary){root=null;break;}
  root=root.parentElement;
 }
 if(!root||!detailBoundary.contains(root)){clearEmptyConfirmations();return {state:'waiting',message:'当前笔记评论结构尚未加载，未读取旁栏内容'};}
 const nodes=all('.comment-item',root).filter(visible);
 // Count evidence remains inside the same hard detail boundary, never title/body/comment text.
 const uiNodes=all('*',detailBoundary).filter(n=>visible(n)&&!n.closest(userContent)&&!all(userContent,n).some(visible));
 const totals=all('.total',root).filter(n=>visible(n)&&!n.closest(userContent)&&!all(userContent,n).some(visible));
 const counts=totals.map(n=>text(n).match(/^共\s*([0-9]+(?:\.[0-9]+)?\s*[万千亿wWkK]?)\s*条评论$/)?.[1]).filter(t=>t!==undefined);
 const positiveCount=counts.some(t=>!/^0$/.test(t.trim()));
 const zeroLabels=[...new Set(totals.map(text).filter(t=>/^共\s*0\s*条评论$/.test(t)))];
 if(emptyPrompts.length===1&&root.contains(emptyPrompts[0]))zeroLabels.push('empty:comments-el:no-comments:这是一片荒地');
 const commentLoading=!!detailBoundary.closest('[aria-busy="true"]')||uiNodes.some(n=>n.matches('[aria-busy="true"]')||/^(加载中[.。…]*|正在加载[.。…]*|评论加载中[.。…]*)$/.test(text(n)));
 const zeroCandidate=!nodes.length&&!commentLoading&&!positiveCount&&zeroLabels.length>0;
 const explicitZero=confirmEmptyComments(detailBoundary,wanted,zeroLabels.sort().join('|'),zeroCandidate);
 if(cfg.command==='open')return {state:nodes.length||explicitZero?'ready':'waiting',explicitZero,message:'等待详情中的公开评论；不自动展开回复或发送互动'};
 if(cfg.command==='read'){
  const rows=[], seen=new Set();let skipped=0,folded=0;
  const own=(selector,n)=>all(selector,n).filter(el=>visible(el)&&el.closest('.comment-item')===n);
  for(const n of nodes){
   const names=own('.name',n), contents=own('.content',n), dates=own('.date',n);
   if(names.length!==1||contents.length!==1||dates.length>1||all('.comment-item',contents[0]).length){skipped++;continue;}
   const nameNode=names[0], contentNode=contents[0];
   if(nameNode.contains(contentNode)||contentNode.contains(nameNode)){skipped++;continue;}
   const containingAnchor=nameNode.closest('a[href]');
   const anchors=[...(containingAnchor?[containingAnchor]:[]),...all('a[href]',nameNode)]
    .filter(a=>visible(a)&&a.closest('.comment-item')===n);
   const profiles=[...new Set(anchors.map(a=>profileLink(a.getAttribute('href')||'')).filter(Boolean))];
   const author=text(nameNode).slice(0,100);let content=text(contentNode);
   if(!content)content=all('img[alt]',contentNode).filter(visible).map(img=>img.getAttribute('alt')||'').join('');
   content=content.slice(0,6000);
   if(/^(该评论被折叠|评论已删除|该评论已删除|评论暂不可见)$/.test(content)){folded++;continue;}
   if(profiles.length!==1||!author||!content){skipped++;continue;}
   const profile=profiles[0], id=n.id.match(/^comment-([0-9a-f]{1,64})$/i)?.[1].toLowerCase()||'';
   const identity=JSON.stringify(id?['id',id]:['fallback',profile,content]);
   if(seen.has(identity))continue;seen.add(identity);
   const dateNode=dates[0], dateText=text(dateNode);
   const spans=dateNode?all('span',dateNode).filter(s=>visible(s)&&s.closest('.comment-item')===n&&!all('span',s).some(visible)):[];
   const pieces=spans.map(text).filter(Boolean);
   const publishedAt=(!/编辑|更新/.test(dateText)&&pieces.length===2?pieces.join('·'):dateText).slice(0,200);
   const times=dateNode?[...(dateNode.matches('time[datetime]')?[dateNode]:[]),...all('time[datetime]',dateNode)]
    .filter(t=>visible(t)&&t.closest('.comment-item')===n):[];
   const publishedAtISO=times.length===1&&!/编辑|更新/.test(dateText)?String(times[0].getAttribute('datetime')||'').slice(0,80):'';
   rows.push({commentId:id,platform:'xiaohongshu',industry:String(cfg.industry||'general').slice(0,40),product:String(cfg.keyword||'').slice(0,60),
    text:content,authorName:author,authorId:new URL(profile).pathname.split('/').pop(),profileUrl:profile,
    publishedAt,publishedAtISO,sourceUrl:source,sourceTitle:String(cfg.sourceTitle||text(titles[0])||'').slice(0,300),
    acquisition:'local_webview',contactSnippet:'',contactSourceUrl:''});
   if(rows.length>=cap(cfg.maxComments,200,200))break;
  }
  return {state:nodes.length||explicitZero?'ready':'waiting',comments:rows,explicitZero,
   diagnostics:{loaded:nodes.length,parsed:rows.length,skipped,folded},
   message:rows.length?'仅读取已加载公开评论；实验适配、非全量':explicitZero?'平台零评论状态已稳定确认':nodes.length?'已检查本批评论，均折叠或无法解析；继续有限翻页':zeroCandidate?'暂无评论状态待稳定确认':'评论尚未加载，等待至本笔记时限'};
 }
 if(explicitZero)return {state:'ready',moved:false,reason:'explicit_zero'};
 if(!nodes.length)return {state:'waiting',moved:false,reason:'no_comments'};
 let scroller=nodes[0].parentElement;
 while(scroller&&detailBoundary.contains(scroller)){
  const css=getComputedStyle(scroller);
  if(/auto|scroll/.test(css.overflowY)&&scroller.scrollHeight>scroller.clientHeight+4&&typeof scroller.scrollBy==='function')break;
  if(scroller===detailBoundary){scroller=null;break;}
  scroller=scroller.parentElement;
 }
 if(!scroller||!detailBoundary.contains(scroller))return {state:'waiting',moved:false,reason:'no_scrollable_detail_container'};
 const before=scroller.scrollTop||0;
 scroller.scrollBy({top:Math.max(240,Math.round(scroller.clientHeight*0.8)),behavior:'auto'});
 return {state:'ready',moved:Math.abs((scroller.scrollTop||0)-before)>1,reason:'visible_comment_scroll'};
}
