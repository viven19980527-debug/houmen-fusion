import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parseHTML} from 'linkedom';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

// Synthetic DOM fixtures only: no production user records or browser session data.
const script=await readFile(new URL('../AudioLocal/collector-ios.js',import.meta.url),'utf8');
const source='https://www.douyin.com/video/7530630967543811388';
const keyword='线阵音响';
const search='https://www.douyin.com/search/'+encodeURIComponent(keyword);
const profile='/user/fixture_author_01';
const id=i=>String(7530630967543811000n+BigInt(i));
const escape=s=>String(s).replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;');
function item(key,{name='测试用户',content='这套多少钱',href=profile,tooltip=true,after='',bodyHTML=false}={}){
 return `<section data-e2e="comment-item"><div class="comment-item-info-wrap"><a href="${escape(href)}">${escape(name)}</a>${tooltip?`<span id="tooltip_${escape(key)}"></span>`:''}</div><div class="fixture-content">${bodyHTML?content:escape(content)}</div><div class="fixture-date">1天前·测试地点</div>${after}</section>`;
}
const list=body=>`<div data-e2e="comment-list">${body}</div>`;
const card=(key,{duration='00:31',image=true,anchor=true,title='线阵音响实测'}={})=>`<article id="waterfall_item_${key}">${image?'<div class="videoImage"></div>':''}<div>${duration}</div>${anchor?`<a href="/video/${key}">${title}</a>`:`<div>${title}</div>`}</article>`;
function toolbar({latest=true,week=true}={}){
 return `<div id="search-toolbar-container"><div class="jjU9T0dQ" tabindex="0"><span>筛选</span><div><div class="_tawtVou">排序依据</div><span class="eXMmo3JR ${latest?'':'sDNqBVWH'}" data-index1="0" data-index2="0">综合排序</span><span class="eXMmo3JR ${latest?'sDNqBVWH':''}" data-index1="0" data-index2="1">最新发布</span></div><div><div class="_tawtVou">发布时间</div><span class="eXMmo3JR ${week?'':'sDNqBVWH'}" data-index1="1" data-index2="0">不限</span><span class="eXMmo3JR ${week?'sDNqBVWH':''}" data-index1="1" data-index2="2">一周内</span></div></div></div>`;
}
function page(body,url=source,{controls=true}={}){
 if(controls&&new URL(url).pathname.startsWith('/search/'))body=toolbar()+body;
 let now=100000;

 const {document}=parseHTML('<html><body>'+body+'</body></html>');
 for(const n of document.querySelectorAll('*')){
  n.getBoundingClientRect=()=>{
   let hidden=false;
   for(let p=n;p;p=p.parentElement)if(p.style?.display==='none'||p.style?.visibility==='hidden')hidden=true;
   return {width:hidden?0:300,height:hidden?0:40,top:10,left:10,right:310,bottom:50};
  };
 }
 Object.defineProperty(document.documentElement,'clientWidth',{value:390,configurable:true});
 Object.defineProperty(document.documentElement,'clientHeight',{value:844,configurable:true});
 const context=vm.createContext({document,location:new URL(url),URL,Date:{now:()=>now},getComputedStyle:n=>({display:n.style?.display||'block',visibility:n.style?.visibility||'visible',overflowY:n.style?.overflowY||'visible'})});
 vm.runInContext(script,context);
 const rawRun=(cfg,elapsed=1500)=>{now+=elapsed;return JSON.parse(JSON.stringify(vm.runInContext('collectAudioPage('+JSON.stringify({sourceUrl:source,keyword,...cfg})+')',context)));};
 return {document,rawRun,run:cfg=>{if(cfg.command==='search'){rawRun({...cfg,command:'prepare_search'});rawRun({...cfg,command:'prepare_search'});}return rawRun(cfg);}};
}
function scrollable(element,{height=300,total=1800,top=0,move=true}={}){
 Object.defineProperty(element,'clientHeight',{value:height,configurable:true});
 Object.defineProperty(element,'scrollHeight',{value:total,configurable:true});
 element.scrollTop=top;
 const calls=[];
 element.scrollBy=options=>{calls.push(options);if(move)element.scrollTop=Math.min(total-height,element.scrollTop+options.top)};
 return calls;
}

test('iOS v013: waterfall IDs cannot manufacture URLs; only actual visible video links',()=>{
 const fixture=card(id(1),{anchor:false})+card(id(2))+card(id(3),{duration:'直播中',image:false,anchor:false})+card(id(4),{duration:'',title:'图文内容'})+card(id(5),{duration:'',image:false,title:'相关搜索'})+`<div hidden>${card(id(6))}</div>`;
 const r=page(`<div id="waterFallScrollContainer">${fixture}</div>`,search).run({command:'search',maxVideos:5});
 assert.equal(r.state,'ready');assert.equal(r.found,1);assert.deepEqual(r.videos.map(x=>x.id),[id(2)]);
});
test('iOS v013: search deduplicates actual links and bounds candidate discovery at 40',()=>{
 const fixture=Array.from({length:7},(_,i)=>card(id(i))).join('');
 const p=page(`<div id="waterFallScrollContainer">${fixture}</div>`,search);
 assert.equal(p.run({command:'search'}).videos.length,7);
 assert.equal(p.run({command:'search',maxCandidates:100}).videos.length,7);
 assert.equal(p.run({command:'search',maxCandidates:3}).videos.length,3);
 assert.equal(p.run({command:'search',maxCandidates:0}).videos.length,1);
 assert.equal(p.run({command:'search',maxCandidates:'bad'}).videos.length,7);
 assert.equal(p.run({command:'search'}).found,7);
});
test('iOS v012: bare video anchors retain old caller compatibility; unsafe links excluded',()=>{
 const p=page(`<a href="${source}">视频</a><a href="https://evil.example/video/${id(2)}">外站</a><a href="https://www.douyin.com:8443/video/${id(3)}">错误端口</a><a href="https://name@www.douyin.com/video/${id(4)}">用户信息URL</a>`,search);
 assert.deepEqual(p.run({command:'search'}).videos.map(x=>x.url),[source]);
});
test('iOS v012: search keyword and page path must match the current task',()=>{
 assert.equal(page(card(id(1)),search).run({command:'search',keyword:'功放'}).code,'source_mismatch');
 assert.equal(page(card(id(1)),source).run({command:'search'}).state,'waiting');
 assert.equal(page(`<a href="${source}">视频</a>`,search).run({command:'search',keyword:''}).code,'source_mismatch');
});
test('iOS v012: direct video and search-modal source agree; mismatched modal is blocked',()=>{
 const body=list(item('one'));
 assert.equal(page(body).run({command:'read'}).state,'ready');
 assert.equal(page(body,search+'?modal_id=7530630967543811388').run({command:'read'}).state,'ready');
 for(const command of ['open','read','advance'])assert.equal(page(body,search+'?modal_id='+id(1)).run({command}).code,'source_mismatch');
});
test('iOS v012: rejects unsupported main origins, credentials and non-default ports',()=>{
 for(const url of ['http://www.douyin.com/video/7530630967543811388','https://douyin.com.evil.example/video/7530630967543811388','https://evildouyin.com/video/7530630967543811388','https://name@www.douyin.com/video/7530630967543811388','https://www.douyin.com:8443/video/7530630967543811388'])assert.equal(page(list(item('one')),url).run({command:'read'}).state,'blocked',url);
 assert.equal(page(list(item('one')),'https://www.douyin.com:443/video/7530630967543811388').run({command:'read'}).state,'ready');
});
test('iOS v012: source and profile URL validation excludes external origins and ports',()=>{
 for(const url of ['https://evil.example/video/7530630967543811388','http://www.douyin.com/video/7530630967543811388','https://www.douyin.com:8443/video/7530630967543811388','https://www.douyin.com/user/not_a_video'])assert.equal(page(list(item('one'))).run({command:'read',sourceUrl:url}).code,'invalid_source');
 const bad=['https://evil.example/user/person','https://www.douyin.com:8443/user/person','https://www.douyin.com.evil.example/user/person','https://name:pass@www.douyin.com/user/person','javascript:alert(1)'];
 const r=page(list(bad.map((href,i)=>item('bad'+i,{href})).join('')+item('good'))).run({command:'read'});
 assert.equal(r.comments.length,1);assert.equal(r.diagnostics.skipped,5);
});
test('iOS v012: login and CAPTCHA stop search/open/read/advance before any action',()=>{
 for(const cue of ['请完成下方验证','请完成安全验证','拖动滑块','请先完成验证','登录后即可搜索更多精彩视频','请登录后查看评论','登录后才能查看评论']){
  const p=page(`<p>${cue}</p>`+list(item('one'))+'<button data-e2e="feed-comment-icon">评论</button>');
  let clicks=0;p.document.querySelector('button').click=()=>clicks++;
  for(const command of ['search','open','read','advance'])assert.equal(p.run({command}).state,'blocked',cue+' '+command);
  assert.equal(clicks,0);
 }
});
test('iOS v012: multiple visible comment lists are ambiguous; hidden list is ignored',()=>{
 for(const command of ['open','read','advance'])assert.equal(page(list(item('one'))+list(item('two'))).run({command}).code,'ambiguous_comments');
 const r=page(list(item('one'))+'<div hidden>'+list(item('two'))+'</div>').run({command:'read'});
 assert.equal(r.comments.length,1);assert.equal(r.diagnostics.loaded,1);
});
test('iOS v012: rows contain public author identity, exact content/source and no contact guesses',()=>{
 const r=page(list(item('public',{name:'公开昵称 作者',content:'需要两套线阵，报价多少？'}))).run({command:'read',sourceTitle:'样例视频'});
 assert.equal(r.state,'ready');assert.equal(r.comments.length,1);
 assert.deepEqual(r.comments[0],{publishedAtISO:'',commentId:'public',platform:'douyin',industry:'general',product:keyword,text:'需要两套线阵，报价多少？',authorName:'公开昵称',authorId:'fixture_author_01',profileUrl:'https://www.douyin.com'+profile,publishedAt:'1天前·测试地点',sourceUrl:source,sourceTitle:'样例视频',acquisition:'local_webview',contactSnippet:'',contactSourceUrl:''});
 assert.deepEqual(r.diagnostics,{loaded:1,parsed:1,skipped:0,folded:0});
});
test('iOS v012: normal nested replies retain their own author/content/ID',()=>{
 const reply=item('reply',{name:'回复用户',href:'/user/reply_author_02',content:'请发功放参数'});
 const r=page(list(item('parent',{name:'父评论用户',content:'这套多少钱',after:`<div class="fixture-replies">${reply}</div>`}))).run({command:'read'});
 assert.deepEqual(r.comments.map(x=>[x.commentId,x.authorName,x.text]),[['parent','父评论用户','这套多少钱'],['reply','回复用户','请发功放参数']]);
});
test('iOS v012: parent lacking its own tooltip must not steal nested reply ID or hide reply',()=>{
 const reply=item('reply',{name:'回复用户',href:'/user/reply_author_02',content:'请发功放参数'});
 const r=page(list(item('parent',{name:'父评论用户',content:'这套多少钱',tooltip:false,after:`<div class="fixture-replies">${reply}</div>`}))).run({command:'read'});
 assert.deepEqual(r.comments.map(x=>[x.commentId,x.authorName,x.text]),[['','父评论用户','这套多少钱'],['reply','回复用户','请发功放参数']]);
});
test('iOS v012: missing parent content must not combine reply card text with parent author',()=>{
 const reply=item('reply',{name:'回复用户',href:'/user/reply_author_02',content:'请发功放参数'});
 const body=`<section data-e2e="comment-item"><div class="comment-item-info-wrap"><a href="${profile}">父评论用户</a><span id="tooltip_parent"></span></div><div class="fixture-replies">${reply}</div></section>`;
 const r=page(list(body)).run({command:'read'});
 assert.deepEqual(r.comments.map(x=>[x.commentId,x.authorName,x.text]),[['reply','回复用户','请发功放参数']]);
 assert.equal(r.diagnostics.skipped,1);
});
test('iOS v012: hidden, malformed, folded/deleted and duplicate rows have honest diagnostics',()=>{
 const body=item('same')+item('same')+'<div hidden>'+item('hidden')+'</div>'+item('folded',{content:'该评论被折叠'})+item('deleted',{content:'评论已删除'})+item('bad',{href:'https://evil.example/user/person'})+item('empty',{content:''})+'<section data-e2e="comment-item"><div>没有作者结构</div></section>';
 const r=page(list(body)).run({command:'read'});
 assert.equal(r.comments.length,1);assert.deepEqual(r.diagnostics,{loaded:7,parsed:1,skipped:3,folded:2});
});
test('iOS v012: emoji-only comments use visible image alt text, never whole comment-card text',()=>{
 const r=page(list(item('emoji',{content:'<img alt="[赞]"><img alt="[强]">',bodyHTML:true})+item('empty',{content:''}))).run({command:'read'});
 assert.equal(r.comments.length,1);assert.equal(r.comments[0].text,'[赞][强]');assert.equal(r.diagnostics.skipped,1);
});
test('iOS v012: default50 and maximum200 examined rows, no age or region guessed',()=>{
 const p=page(list(Array.from({length:240},(_,i)=>item('scan-'+i)).join('')));
 assert.equal(p.run({command:'read'}).comments.length,50);
 assert.equal(p.run({command:'read',maxComments:999}).comments.length,200);
 assert.equal(p.run({command:'read',maxComments:35}).comments.length,35);
 assert.equal('age' in p.run({command:'read'}).comments[0],false);
});

test('iOS v012: successive loaded pages expose newly loaded rows and never exceed 50 per read',()=>{
 const p=page(list(Array.from({length:35},(_,i)=>item('id'+i)).join('')));
 const first=p.run({command:'read',maxComments:50}).comments;
 const root=p.document.querySelector('[data-e2e="comment-list"]');
 root.innerHTML=Array.from({length:60},(_,i)=>item('id'+(i+25))).join('');
 for(const n of root.querySelectorAll('*'))n.getBoundingClientRect=()=>({width:300,height:40,top:10,left:10,bottom:50,right:310});
 const second=p.run({command:'read',maxComments:50}).comments;
 assert.equal(first.length,35);assert.equal(second.length,50);assert.equal(second[0].commentId,'id25');assert.equal(second.at(-1).commentId,'id74');
 assert.equal(new Set([...first,...second].map(x=>x.commentId)).size,75);
});
test('iOS v012: missing comments remain waiting; only explicit zero allows ready/zero',()=>{
 for(const body of ['加载中','暂无评论','全部评论(10)','全部评论(100)']){
  const r=page('<p>'+body+'</p>').run({command:'read'});assert.equal(r.state,'waiting');assert.equal(r.explicitZero,false);
 }
 for(const cue of ['全部评论 (0)','全部评论（0）']){
  const p=page(list('<p>'+cue+'</p>'));
  assert.equal(p.run({command:'open'}).state,'waiting');
  assert.equal(p.run({command:'open'}).state,'ready');
  assert.deepEqual(p.run({command:'read'}).comments,[]);assert.equal(p.run({command:'read'}).explicitZero,true);
  assert.deepEqual(p.run({command:'advance'}),{state:'ready',moved:false,reason:'explicit_zero'});
 }
});
test('iOS v012: old Android open command without source clicks once; visible comments do not click',()=>{
 const p=page('<button data-e2e="feed-comment-icon">评论</button>');let clicks=0;
 p.document.querySelector('button').click=()=>clicks++;
 assert.equal(p.run({command:'open',sourceUrl:undefined}).state,'waiting');p.run({command:'open',sourceUrl:undefined});assert.equal(clicks,1);
 const loaded=page(list(item('one'))+'<button data-e2e="feed-comment-icon">评论</button>');loaded.document.querySelector('button').click=()=>{throw new Error('unnecessary click')};
 assert.equal(loaded.run({command:'open'}).state,'ready');
});
test('iOS v012: bounded list scrolling reports actual movement and end-of-list accurately',()=>{
 const p=page(list(item('one'))),root=p.document.querySelector('[data-e2e="comment-list"]');root.style.overflowY='auto';
 const calls=scrollable(root,{height:400,total:1000});
 assert.deepEqual(p.run({command:'advance'}),{state:'ready',moved:true,reason:'comment_scroll'});assert.equal(calls[0].top,320);
 root.scrollTop=600;assert.deepEqual(p.run({command:'advance'}),{state:'ready',moved:false,reason:'comment_scroll'});
});
test('iOS v012: ancestor list scroller is preferred over document scrolling',()=>{
 const p=page('<div id="scroll-parent">'+list(item('one'))+'</div>'),parent=p.document.querySelector('#scroll-parent');parent.style.overflowY='scroll';
 const calls=scrollable(parent,{height:500,total:2000});
 assert.equal(p.run({command:'advance'}).reason,'comment_scroll');assert.equal(calls.length,1);assert.equal(calls[0].top,400);
});
test('iOS v012: document fallback scrolls last comment into view and reports document movement',()=>{
 const p=page(list(item('one')+item('two')));let lastSeen=0;
 const rows=p.document.querySelectorAll('[data-e2e="comment-item"]');rows[0].scrollIntoView=()=>{throw new Error('must scroll last visible comment')};rows[1].scrollIntoView=()=>lastSeen++;
 const calls=scrollable(p.document.documentElement,{height:800,total:3000});
 Object.defineProperty(p.document,'scrollingElement',{value:p.document.documentElement,configurable:true});
 assert.deepEqual(p.run({command:'advance'}),{state:'ready',moved:true,reason:'document_scroll'});
 assert.equal(lastSeen,1);assert.equal(calls[0].top,560);
});
test('iOS v012: no list means no advance action; unknown commands are blocked',()=>{
 assert.deepEqual(page('<p>视频加载中</p>').run({command:'advance'}),{state:'waiting',moved:false,reason:'no_comment_list'});
 assert.equal(page(list(item('one'))).run({command:'unknown'}).state,'blocked');
});

test('iOS v012: reads own visible time datetime and preserves human label',()=>{
 const body=item('time').replace('1天前·测试地点','<time datetime="2026-10-24T09:00:00+08:00">昨天</time>·广东');
 const row=page(list(body)).run({command:'read'}).comments[0];
 assert.equal(row.publishedAtISO,'2026-10-24T09:00:00+08:00');
 assert.equal(row.publishedAt,'昨天·广东');
});
test('iOS v012: never steals date from nested replies',()=>{
 const reply=item('reply').replace('1天前·测试地点','<time datetime="2026-10-24T09:00:00+08:00">昨天</time>');
 const rows=page(list(item('parent',{after:reply}))).run({command:'read'}).comments;
 assert.equal(rows[0].publishedAtISO,'');
 assert.equal(rows[1].publishedAtISO,'2026-10-24T09:00:00+08:00');
});

test('iOS v012: editing timestamps are not publication timestamps',()=>{
 const body=item('edited').replace('1天前·测试地点','编辑于<time datetime="2026-10-24T09:00:00+08:00">昨天</time>·广东');
 assert.equal(page(list(body)).run({command:'read'}).comments[0].publishedAtISO,'');
});
test('iOS v012: arbitrary product/service keywords do not require audio categories',()=>{
 for(const term of ['窗帘定制','上门保洁','咖啡豆','Brand X service']) {
  const url='https://www.douyin.com/search/'+encodeURIComponent(term);
  const r=page(card(id(1),{title:term}),url).run({command:'search',keyword:term});
  assert.equal(r.videos.length,1);
 }
});

test('iOS v012: user-selected industry is included without replacing the custom keyword',()=>{
 const p=page(list(item('industry')));
 const row=p.run({command:'read',industry:'home',keyword:'定制窗帘'}).comments[0];
 assert.equal(row.industry,'home');assert.equal(row.product,'定制窗帘');
});


test('iOS v013: only genuine href survives a mismatched waterfall layout id',()=>{
 const html=card(id(1)).replace('href="/video/'+id(1)+'"','href="/video/'+id(2)+'"');
 const r=page(html,search).run({command:'search'});
 assert.deepEqual(r.videos.map(x=>x.id),[id(2)]);
 assert.equal(page(card(id(1),{anchor:false}),search).run({command:'search'}).videos.length,0);
});

test('iOS v013: video-tab source metadata is separate from title and comment time',()=>{
 const p=page('<a href="'+source+'"><div class="VDYK8Xd7">Brand X 新品</div><span class="faDtinfi"><time datetime="2026-10-24T10:00:00+08:00">昨天</time></span></a>',search+'?type=video');
 const r=p.run({command:'search'}),v=r.videos[0];
 assert.equal(v.title,'Brand X 新品');assert.equal(v.sourcePublishedAt,'昨天');
 assert.equal(v.sourcePublishedAtISO,'2026-10-24T10:00:00+08:00');
 assert.equal(r.latestOrderConfirmed,true);
 const many=page(Array.from({length:45},(_,i)=>`<a href="/video/${id(i)}">视频${i}</a>`).join(''),search);
 assert.equal(many.run({command:'search',maxCandidates:100}).videos.length,40);
});

test('iOS v013: deleted/unavailable video skips immediately instead of waiting for comments',()=>{
 for(const cue of ['你要观看的视频不存在','视频已删除','该视频已删除','视频暂时无法观看','作品不存在']){
  for(const command of ['source','open','read','advance']){
   const r=page('<p>'+cue+'</p>').run({command});
   assert.equal(r.state,'skipped');assert.equal(r.code,'source_unavailable');
  }
 }
 assert.notEqual(page('<p hidden>你要观看的视频不存在</p>'+list(item('alive'))).run({command:'source'}).code,'source_unavailable');
 assert.equal(page('<h1>你要观看的视频不存在</h1>'+list(item('alive',{content:'你要观看的视频不存在'}))).run({command:'read'}).state,'ready');
});

test('iOS v013: source date requires original publication metadata and strict source identity',()=>{
 const p=page('<h1>视频标题2026-10-25</h1><div data-e2e="detail-video-publish-time">发布时间：<time datetime="2026-10-24T10:00:00+08:00">2026-10-24 10:00</time></div>'+list(item('one')));
 assert.deepEqual(p.run({command:'source'}),{state:'ready',sourcePublishedAt:'2026-10-24 10:00',sourcePublishedAtISO:'2026-10-24T10:00:00+08:00'});
 assert.equal(p.run({command:'source',sourceUrl:'https://www.douyin.com/video/'+id(9)}).code,'source_mismatch');
 assert.equal(p.run({command:'source',sourceUrl:''}).code,'invalid_source');
 assert.equal(page('<h1>发布时间：2026-10-25</h1>'+list(item('date',{content:'发布时间：2026-10-25'}))).run({command:'source'}).code,'source_loading');
 assert.equal(page('<h1>视频</h1><p data-e2e="detail-video-publish-time">发布时间：编辑于2026-10-25</p>').run({command:'source'}).code,'source_time_unknown');
 assert.equal(page('<p>加载中</p>').run({command:'source'}).state,'waiting');
 assert.equal(page('<h1>视频</h1><div data-e2e="detail-video-publish-time">发布时间：2026-10-24</div><div data-e2e="detail-video-publish-time">发布时间：2026-10-23</div>').run({command:'source'}).code,'source_time_unknown');
});


test('latest/week gate refuses default order until both controls and refreshed result are stable',()=>{
 const p=page(toolbar({latest:false,week:false})+`<div id="waterFallScrollContainer"><a href="/video/${id(1)}">旧列表</a></div>`,search,{controls:false});
 const select=(i,j)=>{const option=p.document.querySelector(`[data-index1="${i}"][data-index2="${j}"]`);option.click=()=>{for(const n of p.document.querySelectorAll(`[data-index1="${i}"]`))n.classList.remove('sDNqBVWH');option.classList.add('sDNqBVWH');};};
 select(0,1);select(1,2);
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting'); // old result did not refresh
 const a=p.document.querySelector('#waterFallScrollContainer a');a.setAttribute('href','/video/'+id(2));
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'ready');
 assert.equal(p.rawRun({command:'search'}).latestOrderConfirmed,true);
 p.document.querySelector('[data-index1="0"][data-index2="1"]').classList.remove('sDNqBVWH');
 p.document.querySelector('[data-index1="0"][data-index2="0"]').classList.add('sDNqBVWH');
 assert.equal(p.rawRun({command:'search'}).state,'waiting');
});

test('latest gate does not trust title text, hidden duplicate options, or selected ambiguity',()=>{
 assert.equal(page('<h1>最新发布 一周内</h1>'+card(id(1)),search,{controls:false}).rawRun({command:'search'}).code,'latest_sort_unconfirmed');
 const p=page(card(id(1)),search);
 const extra=p.document.createElement('span');extra.getBoundingClientRect=()=>({width:100,height:20,top:1,left:1,right:101,bottom:21});extra.setAttribute('data-index1','0');extra.className='sDNqBVWH';extra.textContent='最多点赞';
 p.document.querySelector('._tawtVou').parentElement.appendChild(extra);
 assert.equal(p.rawRun({command:'prepare_search'}).code,'latest_sort_unconfirmed');
 extra.setAttribute('aria-hidden','true');
 assert.equal(p.run({command:'search'}).state,'ready');
});

test('explicit empty latest search is a ready empty result, not a fake data failure',()=>{
 const r=page('<p>没有找到相关结果</p>',search).run({command:'search'});
 assert.equal(r.state,'ready');assert.equal(r.explicitEmpty,true);assert.deepEqual(r.videos,[]);assert.equal(r.latestOrderConfirmed,true);
});

test('search_advance scrolls only after keyword and latest proof; does not mutate comments',()=>{
 const p=page(`<div id="waterFallScrollContainer">${card(id(1))}</div>`,search);
 const root=p.document.querySelector('#waterFallScrollContainer');root.style.overflowY='auto';const calls=scrollable(root);
 p.run({command:'search'});assert.equal(p.rawRun({command:'search_advance'}).moved,true);assert.equal(calls.length,1);
 assert.equal(p.rawRun({command:'search_advance',keyword:'wrong'}).code,'source_mismatch');assert.equal(calls.length,1);
});

test('comment/title text mentioning login or security is not a platform gate',()=>{
 const p=page('<h1>安全验证教程</h1><p hidden>请完成安全验证</p>'+list(item('literal',{content:'安全验证后请登录后查看评论'})));
 assert.equal(p.run({command:'read'}).state,'ready');
});


test('source waits through asynchronous metadata appearance instead of skipping early video DOM',()=>{
 const p=page('<h1>视频已渲染</h1><span data-e2e="detail-video-publish-time"></span>');
 assert.equal(p.run({command:'source'}).state,'waiting');
 const n=p.document.querySelector('[data-e2e="detail-video-publish-time"]');n.textContent='发布时间：2026-10-25 11:22';
 assert.equal(p.run({command:'source'}).state,'ready');assert.equal(p.run({command:'source'}).sourcePublishedAt,'2026-10-25 11:22');
 const absent=page('<video></video><h1>详情</h1>');assert.equal(absent.run({command:'source'}).state,'waiting');
});


test('same-ID latest/week response eventually passes only after >=3 polls spanning >=4 seconds',()=>{
 const p=page(toolbar({latest:false,week:false})+card(id(1)),search,{controls:false});
 for(const i of ['0','1'])for(const n of p.document.querySelectorAll(`[data-index1="${i}"]`))n.click=()=>{for(const other of p.document.querySelectorAll(`[data-index1="${i}"]`))other.classList.remove('sDNqBVWH');n.classList.add('sDNqBVWH');};
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 for(let n=0;n<3;n++)assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting'); // only 3s since first stable poll
 let r;for(let n=0;n<3;n++)r=p.rawRun({command:'prepare_search'});
 assert.equal(r.state,'ready');assert.equal(r.orderingEvidence,'selected_stable_sample');
});

test('visible search loading invalidates proof and prevents same-ID stable fallback',()=>{
 const p=page(toolbar({latest:false,week:false})+card(id(1))+'<p role="status">加载中</p>',search,{controls:false});
 for(const i of ['0','1'])for(const n of p.document.querySelectorAll(`[data-index1="${i}"]`))n.click=()=>{for(const other of p.document.querySelectorAll(`[data-index1="${i}"]`))other.classList.remove('sDNqBVWH');n.classList.add('sDNqBVWH');};
 for(let n=0;n<10;n++)assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 p.document.querySelector('[role="status"]').remove();
 for(let n=0;n<3;n++)assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 let r;for(let n=0;n<3;n++)r=p.rawRun({command:'prepare_search'});assert.equal(r.state,'ready');
 p.document.querySelector('#search-toolbar-container').setAttribute('aria-busy','true');
 assert.equal(p.rawRun({command:'search'}).state,'waiting');
});


test('loaded but folded or unparseable DY nodes yield ready empty batches, never invented zero',()=>{
 const p=page(list(item('fold',{content:'该评论被折叠'})+item('bad',{href:'https://invalid.test/user/person'})));
 const r=p.run({command:'read'});
 assert.equal(r.state,'ready');assert.deepEqual(r.comments,[]);assert.equal(r.explicitZero,false);
 assert.deepEqual(r.diagnostics,{loaded:2,parsed:0,skipped:1,folded:1});
 const listNode=p.document.querySelector('[data-e2e="comment-list"]');listNode.style.overflowY='auto';scrollable(listNode);
 assert.equal(p.run({command:'advance'}).moved,true);
});

test('DY zero must be independent current-list UI and stable for at least one second',()=>{
 for(const html of ['<h1>全部评论(0)</h1>','<p>全部评论(0)</p>',list('<h1>全部评论(0)</h1>'),list('<div data-e2e="video-desc">全部评论(0)</div>'),list('<div><span hidden>全部评论(0)</span></div>')]){
  const p=page(html);for(let i=0;i<3;i++){const r=p.run({command:'read'});assert.equal(r.state,'waiting');assert.equal(r.explicitZero,false);}
 }
 for(const cue of ['全部评论 ( 0 )','暂无评论','还没有评论']){
  const p=page(list('<p>'+cue+'</p>'));
  assert.equal(p.rawRun({command:'read'},0).explicitZero,false);
  assert.equal(p.rawRun({command:'read'},500).explicitZero,false);
  const r=p.rawRun({command:'read'},500);assert.equal(r.state,'ready');assert.equal(r.explicitZero,true);assert.deepEqual(r.comments,[]);
 }
});

test('DY visible loading, busy and positive counts override an otherwise empty UI',()=>{
 for(const extra of ['<p>全部评论(12)</p>','<p>全部评论(1.2万)</p>','<p>加载中...</p>','<span aria-busy="true"></span>']){
  const p=page(list('<p>暂无评论</p><p>全部评论(0)</p>'+extra));
  for(let i=0;i<4;i++){const r=p.run({command:'read'});assert.equal(r.state,'waiting');assert.equal(r.explicitZero,false);}
 }
 const p=page('<section aria-busy="true">'+list('<p>全部评论(0)</p>')+'</section>');
 for(let i=0;i<3;i++)assert.equal(p.run({command:'read'}).explicitZero,false);
 p.document.querySelector('section').removeAttribute('aria-busy');
 assert.equal(p.run({command:'read'}).explicitZero,false);assert.equal(p.run({command:'read'}).explicitZero,true);
 const hidden=page(list('<p>全部评论(0)</p><p hidden>加载中</p><span hidden aria-busy="true"></span><p hidden>全部评论(8)</p>'));
 hidden.run({command:'read'});assert.equal(hidden.run({command:'read'}).explicitZero,true);
});

test('DY platform login/CAPTCHA inside comment-list blocks, actual comment text never does',()=>{
 for(const [cue,code] of [['请登录后查看评论','login'],['登录后才能查看评论','login'],['请完成安全验证','verification'],['拖动滑块','verification']]){
  const p=page(list('<p>全部评论(0)</p><p>'+cue+'</p>'));
  for(const command of ['open','read','advance'])assert.equal(p.run({command}).code,code);
  const user=page(list(item('user',{content:cue}))).run({command:'read'});assert.equal(user.state,'ready');assert.equal(user.explicitZero,false);assert.equal(user.comments[0].text,cue);
 }
 const p=page(list('<p>全部评论(0)</p><div><p hidden>请完成安全验证</p></div>'));
 p.run({command:'read'});assert.equal(p.run({command:'read'}).explicitZero,true);
});

test('DY loading or blocked state invalidates earlier empty confirmation',()=>{
 for(const cue of ['加载中','请登录后查看评论','请完成安全验证','全部评论(2)']){
  const p=page(list('<p>全部评论(0)</p><p id="changing"></p>'));p.run({command:'read'});assert.equal(p.run({command:'read'}).explicitZero,true);
  p.document.querySelector('#changing').textContent=cue;assert.notEqual(p.run({command:'read'}).explicitZero,true);
  p.document.querySelector('#changing').textContent='';assert.equal(p.run({command:'read'}).explicitZero,false);assert.equal(p.run({command:'read'}).explicitZero,true);
 }
});

test('DY replacing comment-list or a long poll gap requires fresh zero confirmation',()=>{
 const p=page(list('<p>全部评论(0)</p>'));p.run({command:'read'});assert.equal(p.run({command:'read'}).explicitZero,true);
 assert.equal(p.rawRun({command:'read'},6000).explicitZero,false);assert.equal(p.run({command:'read'}).explicitZero,true);
 p.document.body.innerHTML=list('<p>全部评论(0)</p>');
 for(const n of p.document.body.querySelectorAll('*'))n.getBoundingClientRect=()=>({width:300,height:40});
 assert.equal(p.run({command:'read'}).explicitZero,false);assert.equal(p.run({command:'read'}).explicitZero,true);
});


test('DY 30/90 source windows use observed unlimited control with explicit native-window proof',()=>{
 for(const days of [30,90]){
  const p=page(toolbar({week:false})+card(id(1)),search,{controls:false});
  const r=p.run({command:'search',sourceWindowDays:days});
  assert.equal(r.state,'ready');assert.equal(r.latestOrderConfirmed,true);assert.equal(r.sourceWindowDays,days);
  assert.equal(r.timeFilterApplied,'不限');assert.equal(r.videos.length,1);assert.doesNotMatch(r.message,/一周内/);
 }
 const r=page(card(id(1)),search).run({command:'search'});assert.equal(r.sourceWindowDays,7);assert.equal(r.timeFilterApplied,'一周内');
});

test('DY changing source window invalidates prior latest proof even with identical unlimited results',()=>{
 const p=page(toolbar({week:false})+card(id(1)),search,{controls:false});
 assert.equal(p.run({command:'search',sourceWindowDays:30}).state,'ready');
 const first=p.rawRun({command:'prepare_search',sourceWindowDays:90});assert.equal(first.state,'waiting');assert.equal(first.latestOrderConfirmed,false);
 assert.equal(p.rawRun({command:'prepare_search',sourceWindowDays:90}).state,'ready');
 const r=p.rawRun({command:'search',sourceWindowDays:90});assert.equal(r.state,'ready');assert.equal(r.sourceWindowDays,90);
});

test('DY wider window actively clears selected week only via observed unlimited option',()=>{
 const p=page(card(id(1)),search);const options=p.document.querySelectorAll('span[data-index1="1"]');let clicked=0;
 for(const node of options)node.click=()=>{clicked++;for(const other of options)other.classList.remove('sDNqBVWH');node.classList.add('sDNqBVWH');};
 assert.equal(p.rawRun({command:'prepare_search',sourceWindowDays:30}).state,'waiting');assert.equal(clicked,1);
 assert.equal(p.document.querySelector('span[data-index1="1"][data-index2="0"]').classList.contains('sDNqBVWH'),true);
 let r;for(let i=0;i<5;i++)r=p.rawRun({command:'prepare_search',sourceWindowDays:30});
 assert.equal(r.state,'ready');assert.equal(r.timeFilterApplied,'不限');assert.equal(clicked,1);
});

test('DY invalid windows or missing unlimited choice never silently use seven-day results',()=>{
 for(const days of [0,8,31,91,365,'30',null])assert.equal(page(card(id(1)),search).rawRun({command:'prepare_search',sourceWindowDays:days}).code,'invalid_source_window');
 const p=page(card(id(1)),search);p.document.querySelector('span[data-index1="1"][data-index2="0"]').remove();
 assert.equal(p.rawRun({command:'prepare_search',sourceWindowDays:30}).code,'latest_sort_unconfirmed');
});

test('DY explicit empty wider-window result preserves requested native date boundary',()=>{
 const p=page(toolbar({week:false})+'<p>未找到相关视频</p>',search,{controls:false});
 const r=p.run({command:'search',sourceWindowDays:90});assert.equal(r.state,'ready');assert.deepEqual(r.videos,[]);
 assert.equal(r.sourceWindowDays,90);assert.equal(r.timeFilterApplied,'不限');assert.equal(r.explicitEmpty,true);
});
