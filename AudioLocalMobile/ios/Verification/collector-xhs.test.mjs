import {test} from 'node:test';
import assert from 'node:assert/strict';
import {parseHTML} from 'linkedom';
import {readFile} from 'node:fs/promises';
import vm from 'node:vm';

// Entirely synthetic DOM; NOT live/platform/device validation. Selector candidates are
// documented by https://github.com/yichuanhu/xhs-skill/blob/main/references/browse.md.
// No reference commands are run. No browser, credentials, network or real-user fixtures.
const script=await readFile(new URL('../AudioLocal/collector-xhs.js',import.meta.url),'utf8');
const hex=i=>(0x650000000000000000000000n+BigInt(i)).toString(16);
const note=hex(1), author=hex(20), keyword='音响', origin='https://www.xiaohongshu.com';
const source=origin+'/explore/'+note+'?xsec_token=fixture_token%2B%2F%3D&xsec_source=pc_search';
const search=origin+'/search_result?keyword='+encodeURIComponent(keyword);
const profile='/user/profile/'+author;
const esc=s=>String(s).replaceAll('&','&amp;').replaceAll('"','&quot;').replaceAll('<','&lt;');
function comment(i,{name='合成用户',href=profile,body='这套多少钱',date='<span>3天前</span><span>广东</span>',extra='',attrs='',nameHTML,contentHTML}={}){
 return `<section class="comment-item" id="comment-${hex(i)}" ${attrs}><div class="name">${nameHTML??`<a href="${esc(href)}">${esc(name)}</a>`}</div><div class="content">${contentHTML??esc(body)}</div><div class="date">${date}</div>${extra}</section>`;
}
function detail(comments,{extra='',title='合成笔记',attrs=''}={}){
 return `<article ${attrs.includes('id=')?'':'id="noteContainer"'} ${attrs}><div id="detail-title">${esc(title)}</div><div id="detail-desc">非采集正文</div>${extra}<div class="fixture-comments">${comments}</div></article>`;
}
function card(i,{href=origin+'/explore/'+hex(i),title='音响示例',extra='',attrs=''}={}){
 return `<article class="note-item" ${attrs}><a class="cover" href="${esc(href)}">封面</a><div class="title">${esc(title)}</div>${extra}</article>`;
}
function filters({latest=true,week=true}={}){
 return `<div class="filter"><span>筛选</span></div><div class="filters-wrapper"><div class="filters"><span>排序依据</span><div class="tag-container"><span class="tags ${latest?'':'active'}">综合</span><span class="tags ${latest?'active':''}">最新</span></div></div><div class="filters"><span>发布时间</span><div class="tag-container"><span class="tags ${week?'':'active'}">不限</span><span class="tags ${week?'active':''}">一周内</span></div></div></div>`;
}
function page(html,url=source,{controls=true,mouseEvents=false}={}){
 if(controls&&['/search_result','/search_result_ai'].includes(new URL(url).pathname))html=filters()+html;
 let now=100000;

 const {document,Event}=parseHTML('<html><body>'+html+'</body></html>');
 let clicked=0;
 for(const n of document.querySelectorAll('*')){
  n.getBoundingClientRect=()=>({width:300,height:40,top:10,left:10,right:310,bottom:50});
  n.click=()=>{clicked++;};
 }
 const ctx=vm.createContext({document,location:new URL(url),URL,...(mouseEvents?{MouseEvent:Event}:{}),Date:{now:()=>now},getComputedStyle:n=>({display:n.style?.display||'block',visibility:n.style?.visibility||'visible',overflowY:n.style?.overflowY||'visible'})});
 vm.runInContext(script,ctx);
 const rawRun=(cfg,elapsed=1500)=>{now+=elapsed;return JSON.parse(JSON.stringify(vm.runInContext('collectXiaohongshuPage('+JSON.stringify({sourceUrl:source,keyword,...cfg})+')',ctx)));};
 return {document,rawRun,clicks:()=>clicked,run:cfg=>{if(cfg.command==='search'){rawRun({...cfg,command:'prepare_search'});rawRun({...cfg,command:'prepare_search'});}return rawRun(cfg);}};
}
function scrollable(n,{height=300,total=1500,top=0,move=true}={}){
 Object.defineProperty(n,'clientHeight',{value:height,configurable:true});
 Object.defineProperty(n,'scrollHeight',{value:total,configurable:true});
 n.scrollTop=top;const calls=[];
 n.scrollBy=o=>{calls.push(o);if(move)n.scrollTop=Math.min(total-height,n.scrollTop+o.top);};
 return calls;
}

test('search extracts loaded cover URLs without manufacturing/stripping tokens',()=>{
 const r=page(card(1,{href:source}),search).run({command:'search'});
 assert.equal(r.state,'ready');assert.deepEqual(r.videos,[{id:note,url:source,title:'音响示例',sourcePublishedAt:'',sourcePublishedAtISO:''}]);
});
test('search supports observed /search_result/ID path and relative loaded href',()=>{
 const href='/search_result/'+note+'?xsec_token=fixture&xsec_source=pc_search';
 assert.equal(page(card(1,{href}),search).run({command:'search'}).videos[0].url,origin+href);
});
test('search is exact keyword scoped, rejects duplicate keyword, no recommendation fallback',()=>{
 for(const url of [search+'&keyword=音响',origin+'/search_result?keyword=功放'])assert.equal(page(card(1),url).run({command:'search'}).code,'source_mismatch');
 assert.equal(page(card(1),origin+'/explore').run({command:'search'}).state,'waiting');
 assert.equal(page(card(1),search).run({command:'search',keyword:'服务'}).code,'source_mismatch');
});
test('arbitrary industry and keyword are passed without fixed audio categories',()=>{
 const row=page(detail(comment(1))).run({command:'read',keyword:'定制窗帘',industry:'home'}).comments[0];
 assert.equal(row.product,'定制窗帘');assert.equal(row.industry,'home');assert.equal(row.platform,'xiaohongshu');
});
test('search requires visible own card cover, excludes generic note anchors',()=>{
 const html=card(1,{attrs:'hidden'})+card(2,{attrs:'style="display:none"'})+card(3,{attrs:'aria-hidden="true"'})+
  `<a href="${source}">泛链接</a>`+card(4);
 const r=page(html,search).run({command:'search'});assert.deepEqual(r.videos.map(x=>x.id),[hex(4)]);
});
test('search deduplicates note IDs and hard caps candidate discovery at 40',()=>{
 const html=Array.from({length:8},(_,i)=>card(i+1)).join('')+card(1,{href:source});
 const p=page(html,search);assert.equal(p.run({command:'search',maxCandidates:999}).videos.length,8);
 assert.equal(p.run({command:'search',maxCandidates:2}).videos.length,2);assert.equal(p.run({command:'search'}).found,8);
});
test('note URL rejects unsafe origin, userinfo, port, path, fragments and unexpected query',()=>{
 const bad=['http://www.xiaohongshu.com/explore/'+note,'https://xiaohongshu.com.evil.test/explore/'+note,
  'https://u:p@www.xiaohongshu.com/explore/'+note,'https://www.xiaohongshu.com:8443/explore/'+note,
  origin+'/explore/not-24-hex',source+'&access_token=secret',source+'&xsec_token=second',source+'#fragment',
  origin+'/explore/'+note+'?xsec_source=a&xsec_source=b',origin+'/explore/'+note+'?xsec_token=%00'];
 for(const href of bad){
  assert.equal(page(card(1,{href}),search).run({command:'search'}).videos.length,0,href);
  assert.equal(page(detail(comment(1))).run({command:'read',sourceUrl:href}).code,'invalid_source');
 }
});
test('token/source lengths and serialized 1600-byte source cap are enforced',()=>{
 for(const href of [origin+'/explore/'+note+'?xsec_token='+'a'.repeat(1025),origin+'/explore/'+note+'?xsec_source='+'a'.repeat(81),origin+'/explore/'+note+'?xsec_token='+'%E4%B8%AD'.repeat(300)])
  assert.equal(page(card(1,{href}),search).run({command:'search'}).videos.length,0);
 const href=origin+'/explore/'+note+'?xsec_token='+'a'.repeat(1024)+'&xsec_source='+'b'.repeat(80);
 assert.equal(page(card(1,{href}),search).run({command:'search'}).videos[0].url,href);
});
test('main document must be exact supported HTTPS origin',()=>{
 for(const url of ['http://www.xiaohongshu.com/explore/'+note,'https://user@www.xiaohongshu.com/explore/'+note,'https://evil.xiaohongshu.com/explore/'+note,'https://www.xiaohongshu.com:8443/explore/'+note])
  assert.equal(page(detail(comment(1)),url).run({command:'read'}).code,'invalid_origin');
});
test('login and verification prompts block without any click',()=>{
 for(const [cue,code] of [['请先登录','login'],['小红书扫码登录','login'],['登录后查看更多内容','login'],['请完成安全验证','verification'],['拖动滑块完成验证','verification'],['操作频繁，请稍后再试','verification']]){
  const p=page('<div role="dialog"><p>'+cue+'</p></div>'+detail(comment(1)));
  for(const command of ['open','read','advance'])assert.equal(p.run({command}).code,code);
  assert.equal(p.clicks(),0);
 }
 assert.equal(page('',origin+'/login').run({command:'search'}).code,'login');
});
test('hidden prompts and user comment text cannot masquerade as visible login dialog',()=>{
 const p=page('<p hidden>请先登录</p><p style="display:none">安全验证</p>'+detail(comment(1,{body:'请先登录是平台提示，不是我的需求'})));
 assert.equal(p.run({command:'read'}).state,'ready');
});
test('direct note identity must match, unknown detail structure waits',()=>{
 for(const command of ['open','read','advance'])assert.equal(page(detail(comment(1)),origin+'/explore/'+hex(2)).run({command}).code,'source_mismatch');
 assert.equal(page(comment(1)).run({command:'read'}).state,'waiting');
 for(const sourceUrl of ['',null,undefined])assert.equal(page(detail(comment(1))).run({command:'read',sourceUrl}).code,'invalid_source');
});
test('search modal requires unique matching note href inside detail, never background covers',()=>{
 const matching=detail(comment(1),{extra:`<a href="${esc(source)}">笔记链接</a>`,attrs:'role="dialog"'});
 assert.equal(page(card(1,{href:source})+matching,search).run({command:'read'}).state,'ready');
 const noLink=detail(comment(1),{attrs:'role="dialog"'});
 assert.equal(page(card(1,{href:source})+noLink,search).run({command:'read'}).code,'unconfirmed_source');
 const two=detail(comment(1),{extra:`<a href="${esc(source)}">本条</a><a href="/explore/${hex(2)}">其他</a>`});
 assert.equal(page(two,search).run({command:'read'}).code,'unconfirmed_source');
});
test('multiple visible details block; a hidden detail is ignored',()=>{
 assert.equal(page(detail(comment(1))+detail(comment(2))).run({command:'read'}).code,'ambiguous_details');
 assert.equal(page(detail(comment(1))+'<div hidden>'+detail(comment(2))+'</div>').run({command:'read'}).comments.length,1);
});
test('comment fields and canonical public profile map to native contract; no demographic guesses',()=>{
 const row=page(detail(comment(1,{href:profile+'?channel_type=web_search_result_notes',body:'我30岁，电话13800000000，怎么买'}))).run({command:'read'}).comments[0];
 assert.equal(row.authorName,'合成用户');assert.equal(row.profileUrl,origin+profile);assert.equal(row.authorId,author);
 assert.equal(row.sourceUrl,source);assert.equal(row.commentId,hex(1));assert.equal(row.publishedAt,'3天前·广东');
 assert.equal(row.publishedAtISO,'');assert.equal(row.contactSnippet,'');assert.equal(row.contactSourceUrl,'');
 assert.equal(row.age,undefined);assert.equal(row.region,undefined);assert.equal(row.sourceTitle,'合成笔记');
});
test('parent and nested reply own name/content/date never cross',()=>{
 const nested=comment(2,{name:'回复用户',body:'回复内容',href:'/user/profile/'+hex(21),date:'<span>昨天</span><span>浙江</span>'});
 const rows=page(detail(comment(1,{extra:nested}))).run({command:'read'}).comments;
 assert.equal(rows.length,2);assert.equal(rows[0].authorName,'合成用户');assert.equal(rows[0].text,'这套多少钱');
 assert.equal(rows[0].publishedAt,'3天前·广东');assert.equal(rows[1].authorName,'回复用户');assert.equal(rows[1].publishedAt,'昨天·浙江');
});
test('a name span inside its own profile anchor is supported without sibling user inference',()=>{
 const html=comment(1).replace('<div class="name"><a href="'+profile+'">合成用户</a></div>',
  '<a href="'+profile+'"><span class="name">合成用户</span></a>');
 const row=page(detail(html)).run({command:'read'}).comments[0];
 assert.equal(row.authorName,'合成用户');assert.equal(row.profileUrl,origin+profile);
});
test('missing parent fields cannot be filled from nested replies',()=>{
 const nested=comment(2,{name:'仅回复用户'});
 const parent=`<section class="comment-item" id="comment-${hex(1)}"><div class="content">父正文</div>${nested}</section>`;
 const r=page(detail(parent)).run({command:'read'});assert.equal(r.comments.length,1);assert.equal(r.comments[0].commentId,hex(2));assert.equal(r.diagnostics.skipped,1);
});
test('hidden/empty/unsafe/ambiguous author and content skip safely',()=>{
 const html=comment(1,{attrs:'hidden'})+comment(2,{name:''})+comment(3,{body:''})+
  comment(4,{href:'https://evil.test'+profile})+comment(5,{nameHTML:'<a href="'+profile+'">甲</a><a href="/user/profile/'+hex(21)+'">乙</a>'})+
  comment(6,{extra:'<div class="content">其他正文</div>'})+comment(7);
 const r=page(detail(html)).run({command:'read'});assert.equal(r.comments.length,1);assert.equal(r.comments[0].commentId,hex(7));
});
test('hidden child text is excluded and visible emoji-only comment is retained',()=>{
 const html=comment(1,{contentHTML:'需要报价<span hidden>不应采集</span>'})+comment(2,{contentHTML:'<img alt="[赞]">'});
 const rows=page(detail(html)).run({command:'read'}).comments;
 assert.equal(rows[0].text,'需要报价');assert.equal(rows[1].text,'[赞]');
});
test('folded/deleted comment placeholders are not saved',()=>{
 const r=page(detail(comment(1,{body:'该评论被折叠'})+comment(2,{body:'评论已删除'})+comment(3))).run({command:'read'});
 assert.equal(r.comments.length,1);assert.equal(r.diagnostics.folded,2);
});
test('rows deduplicate by comment ID and enforce maxComments 200',()=>{
 const html=Array.from({length:205},(_,i)=>comment(i)).join('')+comment(1);
 const p=page(detail(html));assert.equal(p.run({command:'read',maxComments:999}).comments.length,200);
 assert.equal(p.run({command:'read',maxComments:3}).comments.length,3);
 const repeated=page(detail(comment(1)+comment(1))).run({command:'read'});assert.equal(repeated.comments.length,1);
});
test('visible own datetime is preserved, edit/update/hidden datetime is not publication time',()=>{
 for(const prefix of ['编辑于','更新于']){
  const row=page(detail(comment(1,{date:prefix+'<time datetime="2026-10-25T12:00:00+08:00">今天</time>'}))).run({command:'read'}).comments[0];
  assert.equal(row.publishedAtISO,'');assert.ok(row.publishedAt.startsWith(prefix));
 }
 const value='2026-10-24T12:00:00+08:00';
 const plain=page(detail(comment(1,{date:'<time datetime="'+value+'">昨天</time>'}))).run({command:'read'}).comments[0];
 assert.equal(plain.publishedAtISO,value);
 const hidden=page(detail(comment(1,{date:'昨天<time hidden datetime="'+value+'">今天</time>'}))).run({command:'read'}).comments[0];
 assert.equal(hidden.publishedAt,'昨天');assert.equal(hidden.publishedAtISO,'');
 for(const prefix of ['编辑于','更新于']){
  const row=page(detail(comment(1,{date:prefix+'<span>昨天</span><span>广东</span>'}))).run({command:'read'}).comments[0];
  assert.ok(row.publishedAt.startsWith(prefix));assert.equal(row.publishedAtISO,'');
 }
});
test('explicit zero requires detail total with exact wording and no visible rows',()=>{
 const p=page(detail('<div class="total">共 0 条评论</div>'));
 assert.equal(p.run({command:'read'}).explicitZero,false);
 for(const command of ['open','read','advance'])assert.equal(p.run({command}).state,'ready');
 assert.equal(p.run({command:'read'}).explicitZero,true);assert.deepEqual(p.run({command:'read'}).comments,[]);
 for(const total of ['没有内容','0','共 10 条评论'])assert.equal(page(detail('<div class="total">'+total+'</div>')).run({command:'read'}).state,'waiting');
 assert.equal(page(detail(comment(1)+'<div class="total">共0条评论</div>')).run({command:'read'}).explicitZero,false);
});
test('advance uses nearest actual scrollable ancestor, never clicks reply or interaction controls',()=>{
 const p=page(detail(comment(1)+'<button class="show-more">展开回复</button><button class="like-wrapper">赞</button>'));
 const inner=p.document.querySelector('.fixture-comments');inner.style.overflowY='auto';
 const calls=scrollable(inner), outer=scrollable(p.document.body);p.document.body.style.overflowY='scroll';
 const r=p.run({command:'advance'});assert.equal(r.state,'ready');assert.equal(r.moved,true);assert.equal(calls.length,1);assert.equal(outer.length,0);assert.equal(p.clicks(),0);
});
test('advance can scroll the detail boundary but never falls back to document/body',()=>{
 const p=page(detail(comment(1))),boundary=p.document.querySelector('#noteContainer');boundary.style.overflowY='auto';
 const calls=scrollable(boundary,{move:false}),outside=scrollable(p.document.documentElement);
 const r=p.run({command:'advance'});assert.equal(r.state,'ready');assert.equal(r.moved,false);assert.equal(calls.length,1);assert.equal(outside.length,0);
 assert.equal(page(detail(comment(1))).run({command:'advance'}).reason,'no_scrollable_detail_container');
});
test('missing comments are waiting rather than zero or success',()=>{
 for(const command of ['open','read','advance'])assert.equal(page(detail('')).run({command}).state,'waiting');
});
test('unsupported commands do not act, and no network or hidden-state hooks are implemented',()=>{
 assert.equal(page(detail(comment(1))).run({command:'like'}).code,'unsupported_command');
 assert.doesNotMatch(script,/\bfetch\s*\(|XMLHttpRequest|document\.cookie|localStorage|sessionStorage|__INITIAL_STATE__/);
});

test('live observed cover href permits an empty optional source label, not an empty token',()=>{
 const href=origin+'/explore/'+note+'?xsec_token=fixture&xsec_source=';
 assert.equal(page(card(1,{href}),search).run({command:'search'}).videos[0].url,href);
 assert.equal(page(card(1,{href:origin+'/explore/'+note+'?xsec_token='}),search).run({command:'search'}).videos.length,0);
 assert.equal(page(card(1,{href:origin+'/explore/'+note+'?xsec_token=a%20b'}),search).run({command:'search'}).videos.length,0);
});


test('source reads only one original date tied to the same note details',()=>{
 const date='<div class="date"><time datetime="2026-10-24T12:00:00+08:00">2026-10-24 12:00</time></div>';
 const r=page(detail(comment(1),{extra:date})).run({command:'source'});
 assert.deepEqual(r,{state:'ready',sourcePublishedAt:'2026-10-24 12:00',sourcePublishedAtISO:'2026-10-24T12:00:00+08:00'});
 assert.equal(page(detail(comment(1))).run({command:'source'}).code,'source_loading');
 assert.equal(page(detail(comment(1),{extra:'<div class="date">编辑于昨天</div>'})).run({command:'source'}).code,'source_time_unknown');
 assert.equal(page(detail(comment(1),{extra:date+date})).run({command:'source'}).code,'source_time_unknown');
 assert.equal(page(detail(comment(1)),origin+'/explore/'+hex(2)).run({command:'source'}).code,'source_mismatch');
});

test('source never borrows dates from title, description, comments or background cards',()=>{
 const html=detail(comment(1)).replace('非采集正文','<span class="date">2026-10-24</span>')+
  card(2,{extra:'<div class="date">2026-10-25</div>'});
 assert.equal(page(html).run({command:'source'}).code,'source_loading');
 assert.equal(page(detail(comment(1),{extra:'<div class="date" hidden>2026-10-25</div>'})).run({command:'source'}).code,'source_loading');
 const modal=detail(comment(1),{attrs:'role="dialog"',extra:'<div class="date">2026-10-24</div>'});
 assert.equal(page(card(1)+modal,search).run({command:'source'}).code,'unconfirmed_source');
});

test('unavailable notes skip source/open/read/advance, not only time out',()=>{
 for(const cue of ['笔记已删除','该笔记不存在','当前笔记无法浏览']){
  for(const command of ['source','open','read','advance']){
   const r=page('<p>'+cue+'</p>').run({command});
   assert.equal(r.state,'skipped');assert.equal(r.code,'source_unavailable');
  }
 }
 assert.equal(page(detail(comment(1,{body:'笔记已删除'}),{title:'笔记已删除'})).run({command:'read'}).state,'ready');
});

test('source supports native-accepted discovery item URL without ID-date inference',()=>{
 const url=origin+'/discovery/item/'+note;
 const r=page(detail(comment(1),{extra:'<div class="date">昨天</div>'}),url).run({command:'source',sourceUrl:url});
 assert.equal(r.state,'ready');assert.equal(r.sourcePublishedAt,'昨天');assert.equal(r.sourcePublishedAtISO,'');
 assert.equal(page(card(1),search).run({command:'search'}).latestOrderConfirmed,true);
});


test('XHS latest/week filters require observed controls, exclusive selection and refreshed stable results',()=>{
 const p=page(filters({latest:false,week:false})+card(1),search,{controls:false});
 for(const group of p.document.querySelectorAll('.filters'))for(const n of group.querySelectorAll('.tags'))n.click=()=>{for(const other of group.querySelectorAll('.tags'))other.classList.remove('active');n.classList.add('active');};
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting'); // stale old result
 p.document.querySelector('.cover').setAttribute('href','/explore/'+hex(2));
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'ready');
 assert.equal(p.rawRun({command:'search'}).latestOrderConfirmed,true);
});

test('XHS search path accepts one extra encoding only, with actual input agreeing',()=>{
 const ai=origin+'/search_result_ai?keyword='+encodeURIComponent(encodeURIComponent(keyword));
 const r=page('<input id="search-input-ai" value="音响">'+card(1,{extra:'<div class="time">3小时前</div>'}),ai).run({command:'search'});
 assert.equal(r.state,'ready');assert.equal(r.videos[0].sourcePublishedAt,'3小时前');
 assert.equal(page('<input id="search-input-ai" value="其他">'+card(1),ai).run({command:'search'}).code,'source_mismatch');
 assert.equal(page(card(1),origin+'/search_result_ai?keyword='+encodeURIComponent(encodeURIComponent(encodeURIComponent(keyword)))).run({command:'search'}).code,'source_mismatch');
});

test('XHS hidden filter duplicate does not count, but two visible active choices block',()=>{
 const p=page(card(1),search);const group=p.document.querySelector('.tag-container');
 const extra=p.document.createElement('span');extra.getBoundingClientRect=()=>({width:100,height:20,top:1,left:1,right:101,bottom:21});extra.className='tags active';extra.textContent='最新';extra.setAttribute('aria-hidden','true');group.appendChild(extra);
 assert.equal(p.run({command:'search'}).state,'ready');extra.removeAttribute('aria-hidden');
 assert.equal(p.rawRun({command:'prepare_search'}).code,'latest_sort_unconfirmed');
 assert.equal(page(card(1),search,{controls:false}).rawRun({command:'search'}).state,'waiting');
});

test('XHS fixed observed source query allowed once, arbitrary/duplicate sources rejected',()=>{
 for(const value of ['web_explore_feed','web_user_page']){
  const url=source+'&source='+value;
  const r=page(detail(comment(1)),url).run({command:'read',sourceUrl:url});
  assert.equal(r.state,'ready');assert.equal(r.comments[0].sourceUrl,url);
  const searchResult=page(card(1,{href:url}),search).run({command:'search'});
  assert.equal(searchResult.videos[0].url,url);assert.equal(searchResult.videos[0].id,note);
  const metadata=page(detail('',{extra:'<div class="bottom-container"><span class="date">2天前 广东</span></div>'}),url)
   .run({command:'source',sourceUrl:url});
  assert.equal(metadata.state,'ready');assert.equal(metadata.sourcePublishedAt,'2天前');
 }
 for(const extra of ['&source=evil','&source=web_user_page_extra','&source=',
  '&source=web_explore_feed&source=web_explore_feed','&source=web_user_page&source=web_user_page',
  '&source=web_explore_feed&source=web_user_page'])
  assert.equal(page(detail(comment(1))).run({command:'read',sourceUrl:source+extra}).code,'invalid_source');
});

test('XHS loading/temporary just-now source is not proof; explicit no result terminates honestly',()=>{
 const html=detail(comment(1),{attrs:'id="noteContainer"',extra:'<div class="date">刚刚</div><div>加载中</div>'});
 assert.equal(page(html).run({command:'source'}).state,'waiting');
 assert.equal(page(html.replace('<div>加载中</div>','')).run({command:'source'}).code,'source_loading');
 const empty=page('<p>没有找到相关内容</p>',search).run({command:'search'});
 assert.equal(empty.state,'ready');assert.equal(empty.explicitEmpty,true);assert.deepEqual(empty.videos,[]);
});

test('XHS search advance uses visible result scroller after preparation',()=>{
 const p=page('<div class="result-container">'+card(1)+'</div>',search);
 const area=p.document.querySelector('.result-container');area.style.overflowY='auto';const calls=scrollable(area);
 p.run({command:'search'});assert.equal(p.rawRun({command:'search_advance'}).moved,true);assert.equal(calls.length,1);
 assert.equal(p.rawRun({command:'search_advance',keyword:'wrong'}).code,'source_mismatch');assert.equal(calls.length,1);
});


test('XHS source waits until asynchronous metadata actually arrives',()=>{
 const p=page(detail(comment(1),{extra:'<div class="date"></div>'}));
 assert.equal(p.run({command:'source'}).state,'waiting');
 const n=p.document.querySelector('article > .date');n.textContent='2026-10-25 12:30';
 const r=p.run({command:'source'});assert.equal(r.state,'ready');assert.equal(r.sourcePublishedAt,'2026-10-25 12:30');
 assert.equal(page(detail(comment(1))).run({command:'source'}).state,'waiting');
});


test('XHS identical latest/week results accept >=4s stable sample instead of waiting forever',()=>{
 const p=page(filters({latest:false,week:false})+card(1),search,{controls:false});
 for(const group of p.document.querySelectorAll('.filters'))for(const n of group.querySelectorAll('.tags'))n.click=()=>{for(const other of group.querySelectorAll('.tags'))other.classList.remove('active');n.classList.add('active');};
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 for(let n=0;n<3;n++)assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 let r;for(let n=0;n<3;n++)r=p.rawRun({command:'prepare_search'});
 assert.equal(r.state,'ready');assert.equal(r.orderingEvidence,'selected_stable_sample');
});

test('XHS same-ID proof never passes while visible loading persists',()=>{
 const p=page(filters({latest:false,week:false})+card(1)+'<p role="status">正在加载...</p>',search,{controls:false});
 for(const group of p.document.querySelectorAll('.filters'))for(const n of group.querySelectorAll('.tags'))n.click=()=>{for(const other of group.querySelectorAll('.tags'))other.classList.remove('active');n.classList.add('active');};
 for(let n=0;n<10;n++)assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 p.document.querySelector('[role="status"]').remove();
 for(let n=0;n<3;n++)assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 let r;for(let n=0;n<3;n++)r=p.rawRun({command:'prepare_search'});assert.equal(r.state,'ready');
 p.document.querySelector('.filters-wrapper').setAttribute('aria-busy','true');assert.equal(p.rawRun({command:'search'}).state,'waiting');
});


test('XHS source date stays inside the observed noteContainer, never sibling aside/main',()=>{
 const markers='<h1 id="detail-title">示例笔记</h1><div id="detail-desc">笔记正文</div>';
 const unrelated='<aside><div class="date">2026-10-25 12:00</div></aside>';
 const absent=page('<main><div id="noteContainer">'+markers+'</div>'+unrelated+'</main>').run({command:'source'});
 assert.equal(absent.state,'waiting');assert.equal(absent.code,'source_loading');
 const own=page('<main><div id="noteContainer">'+markers+'<div class="date">2026-10-24 11:00</div></div>'+unrelated+'</main>').run({command:'source'});
 assert.equal(own.state,'ready');assert.equal(own.sourcePublishedAt,'2026-10-24 11:00');
 const noBoundary=page('<main><div>'+markers+'</div>'+unrelated+'</main>').run({command:'source'});
 assert.equal(noBoundary.state,'waiting');assert.equal(noBoundary.code,'source_loading');
});


test('XHS detail without loaded comments cannot borrow sidebar comments or totals',()=>{
 const own=detail(''),outside='<aside>'+comment(2)+'<div class="total">共0条评论</div></aside>';
 const p=page('<main>'+own+outside+'</main>');
 for(const command of ['open','read','advance']){const r=p.run({command});assert.equal(r.state,'waiting');assert.notEqual(r.explicitZero,true);assert.equal(r.comments,undefined);}
 const valid=page('<main>'+detail(comment(1))+'<aside>'+comment(2)+'</aside></main>').run({command:'read'});
 assert.equal(valid.state,'ready');assert.equal(valid.comments.length,1);assert.equal(valid.comments[0].commentId,hex(1));
});

test('XHS advance never scrolls sidebar or page outside the current note boundary',()=>{
 const p=page('<main>'+detail(comment(1))+'<aside>'+comment(2)+'</aside></main>');
 const sidebar=p.document.querySelector('aside');sidebar.style.overflowY='auto';const sideCalls=scrollable(sidebar);
 const main=p.document.querySelector('main');main.style.overflowY='auto';const mainCalls=scrollable(main);
 const pageCalls=scrollable(p.document.documentElement);
 const r=p.run({command:'advance'});assert.equal(r.state,'waiting');assert.equal(r.reason,'no_scrollable_detail_container');
 assert.equal(sideCalls.length,0);assert.equal(mainCalls.length,0);assert.equal(pageCalls.length,0);
});


test('XHS loaded folded or unparseable nodes yield ready empty batches and allow bounded advance',()=>{
 const p=page(detail(comment(1,{body:'该评论被折叠'})+comment(2,{href:'https://invalid.test/user/profile/'+author})));
 const r=p.run({command:'read'});assert.equal(r.state,'ready');assert.deepEqual(r.comments,[]);assert.equal(r.explicitZero,false);
 assert.deepEqual(r.diagnostics,{loaded:2,parsed:0,skipped:1,folded:1});
 const list=p.document.querySelector('.fixture-comments');list.style.overflowY='auto';scrollable(list);
 assert.equal(p.run({command:'advance'}).moved,true);
});

test('XHS total zero needs two confirmations separated by at least one second',()=>{
 const p=page(detail('<div class="total">共 0 条评论</div>'));
 assert.equal(p.rawRun({command:'read'},0).explicitZero,false);
 assert.equal(p.rawRun({command:'read'},500).explicitZero,false);
 const r=p.rawRun({command:'read'},500);assert.equal(r.state,'ready');assert.equal(r.explicitZero,true);assert.deepEqual(r.comments,[]);
 assert.deepEqual(p.run({command:'advance'}),{state:'ready',moved:false,reason:'explicit_zero'});
});

test('XHS busy/loading/positive conflicts suppress zero, including busy detail ancestor',()=>{
 for(const extra of ['<div class="total">共 8 条评论</div>','<div class="total">共 1.2万 条评论</div>','<p>加载中...</p>','<span aria-busy="true"></span>']){
  const p=page(detail('<div class="total">共 0 条评论</div>'+extra));
  for(let i=0;i<4;i++){const r=p.run({command:'read'});assert.equal(r.state,'waiting');assert.equal(r.explicitZero,false);}
 }
 for(const attr of ['aria-busy="true"','']){
  const html=detail('<div class="total">共 0 条评论</div>',{attrs:attr});
  const p=page(attr?html:'<section aria-busy="true">'+html+'</section>');
  for(let i=0;i<3;i++)assert.equal(p.run({command:'read'}).explicitZero,false);
  p.document.querySelector('[aria-busy]').removeAttribute('aria-busy');
  assert.equal(p.run({command:'read'}).explicitZero,false);assert.equal(p.run({command:'read'}).explicitZero,true);
 }
 const p=page(detail('<div class="total">共 0 条评论</div><p hidden>加载中</p><span hidden aria-busy="true"></span><div class="total" hidden>共8条评论</div>'));
 p.run({command:'read'});assert.equal(p.run({command:'read'}).explicitZero,true);
});

test('XHS zero cannot be borrowed from description, title, a comment or a sidebar',()=>{
 for(const html of [detail('',{title:'共0条评论'}),detail('').replace('非采集正文','<div class="total">共0条评论</div>'),detail('')+'<aside><div class="total">共0条评论</div></aside>']){
  const p=page(html);for(let i=0;i<3;i++)assert.notEqual(p.run({command:'read'}).explicitZero,true);
 }
 const user=page(detail(comment(1,{contentHTML:'<div class="total">共0条评论</div>'}))).run({command:'read'});
 assert.equal(user.state,'ready');assert.equal(user.explicitZero,false);assert.equal(user.comments[0].text,'共0条评论');
});

test('XHS comment-area login/CAPTCHA still blocks zero, excluding user comments',()=>{
 for(const [cue,code] of [['请先登录','login'],['请完成安全验证','verification']]){
  const p=page(detail('<div class="total">共0条评论</div><p>'+cue+'</p>'));
  for(const command of ['open','read','advance'])assert.equal(p.run({command}).code,code);
  const user=page(detail(comment(1,{body:cue}))).run({command:'read'});assert.equal(user.state,'ready');assert.equal(user.explicitZero,false);
 }
});

test('XHS empty confirmation resets after loading, conflicting total, or platform challenge',()=>{
 for(const cue of ['加载中','请先登录','请完成安全验证','共8条评论']){
  const p=page(detail('<div class="total">共0条评论</div><p class="total" id="changing"></p>'));
  p.run({command:'read'});assert.equal(p.run({command:'read'}).explicitZero,true);
  p.document.querySelector('#changing').textContent=cue;assert.notEqual(p.run({command:'read'}).explicitZero,true);
  p.document.querySelector('#changing').textContent='';assert.equal(p.run({command:'read'}).explicitZero,false);assert.equal(p.run({command:'read'}).explicitZero,true);
 }
});

test('XHS missing total and long poll gap cannot reuse old stable-zero evidence',()=>{
 const p=page(detail('<div class="total">共0条评论</div>'));
 p.run({command:'read'});assert.equal(p.run({command:'read'}).explicitZero,true);
 assert.equal(p.rawRun({command:'read'},6000).explicitZero,false);assert.equal(p.run({command:'read'}).explicitZero,true);
 const total=p.document.querySelector('.total');total.classList.remove('total');
 assert.equal(p.run({command:'read'}).state,'waiting');
 total.classList.add('total');assert.equal(p.run({command:'read'}).explicitZero,false);assert.equal(p.run({command:'read'}).explicitZero,true);
});


test('XHS 30/90 windows use only observed unlimited choice and keep native window explicit',()=>{
 for(const days of [30,90]){
  const p=page(filters({week:false})+card(1),search,{controls:false});
  const r=p.run({command:'search',sourceWindowDays:days});assert.equal(r.state,'ready');assert.equal(r.latestOrderConfirmed,true);
  assert.equal(r.sourceWindowDays,days);assert.equal(r.timeFilterApplied,'不限');assert.equal(r.videos.length,1);assert.doesNotMatch(r.message,/一周内/);
 }
 const r=page(card(1),search).run({command:'search'});assert.equal(r.sourceWindowDays,7);assert.equal(r.timeFilterApplied,'一周内');
});

test('XHS latest proof cannot cross windows even if same unlimited results are stable',()=>{
 const p=page(filters({week:false})+card(1),search,{controls:false});assert.equal(p.run({command:'search',sourceWindowDays:30}).state,'ready');
 assert.equal(p.rawRun({command:'prepare_search',sourceWindowDays:90}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search',sourceWindowDays:90}).state,'ready');
 const r=p.rawRun({command:'search',sourceWindowDays:90});assert.equal(r.state,'ready');assert.equal(r.sourceWindowDays,90);
});

test('XHS wider search clears selected week through actual unlimited filter option',()=>{
 const p=page(card(1),search);const group=[...p.document.querySelectorAll('.filters')].find(n=>n.textContent.startsWith('发布时间'));
 const options=[...group.querySelectorAll('.tags')];let clicked=0;
 for(const node of options)node.click=()=>{clicked++;for(const other of options)other.classList.remove('active');node.classList.add('active');};
 assert.equal(p.rawRun({command:'prepare_search',sourceWindowDays:90}).state,'waiting');assert.equal(clicked,1);
 assert.equal(options.find(n=>n.textContent==='不限').classList.contains('active'),true);
 let r;for(let i=0;i<5;i++)r=p.rawRun({command:'prepare_search',sourceWindowDays:90});
 assert.equal(r.state,'ready');assert.equal(r.timeFilterApplied,'不限');assert.equal(clicked,1);
});

test('XHS invalid windows or absent unlimited option block instead of relabeling old week proof',()=>{
 for(const days of [-1,0,8,31,91,'90',null])assert.equal(page(card(1),search).rawRun({command:'prepare_search',sourceWindowDays:days}).code,'invalid_source_window');
 const p=page(card(1),search);[...p.document.querySelectorAll('.tags')].find(n=>n.textContent==='不限').remove();
 assert.equal(p.rawRun({command:'prepare_search',sourceWindowDays:30}).code,'latest_sort_unconfirmed');
});

test('XHS explicit empty wider-window result carries its exact requested boundary',()=>{
 const p=page(filters({week:false})+'<p>没有找到相关笔记</p>',search,{controls:false});
 const r=p.run({command:'search',sourceWindowDays:30});assert.equal(r.state,'ready');assert.deepEqual(r.videos,[]);
 assert.equal(r.sourceWindowDays,30);assert.equal(r.timeFilterApplied,'不限');assert.equal(r.explicitEmpty,true);
});


const observedEmpty='<div class="comments-el"><div class="no-comments"><img alt=""><p class="no-comments-text"> 这是一片荒地<span class="focus-comments">点击评论</span></p></div></div>';
test('live-shaped XHS empty comments without total become stable zero, never click comment CTA',()=>{
 const p=page(detail(observedEmpty));
 assert.equal(p.rawRun({command:'open'},0).state,'waiting');
 assert.equal(p.rawRun({command:'read'},500).explicitZero,false);
 const r=p.rawRun({command:'read'},500);assert.equal(r.state,'ready');assert.equal(r.explicitZero,true);assert.deepEqual(r.comments,[]);
 assert.deepEqual(p.run({command:'advance'}),{state:'ready',moved:false,reason:'explicit_zero'});assert.equal(p.clicks(),0);
});

test('XHS live empty wording outside exact detail structure never proves zero',()=>{
 for(const html of [detail('')+observedEmpty,detail('<p>这是一片荒地点击评论</p>'),
  detail('').replace('非采集正文',observedEmpty),detail(observedEmpty.replace('comments-el','not-comments')),
  detail(observedEmpty.replace('点击评论','点击查看')),detail('<div hidden>'+observedEmpty+'</div>')]){
  const p=page(html);for(let i=0;i<3;i++)assert.notEqual(p.run({command:'read'}).explicitZero,true);
 }
 const user=page(detail(comment(1,{contentHTML:observedEmpty}))).run({command:'read'});
 assert.equal(user.state,'ready');assert.equal(user.explicitZero,false);
});

test('XHS observed empty UI remains subordinate to loading, positive counts and platform gates',()=>{
 for(const extra of ['<p>加载中</p>','<span aria-busy="true"></span>','<div class="total">共8条评论</div>']){
  const p=page(detail(observedEmpty+extra));for(let i=0;i<3;i++){const r=p.run({command:'read'});assert.equal(r.state,'waiting');assert.equal(r.explicitZero,false);}
 }
 for(const [cue,code] of [['请先登录','login'],['请完成安全验证','verification']])assert.equal(page(detail(observedEmpty+'<p>'+cue+'</p>')).run({command:'read'}).code,code);
 const r=page(detail(observedEmpty+comment(1,{body:'该评论被折叠'}))).run({command:'read'});
 assert.equal(r.state,'ready');assert.equal(r.explicitZero,false);assert.deepEqual(r.comments,[]);
});

test('XHS observed bottom date separates exact calendar clock and known region while preserving raw label',()=>{
 const p=page(detail(observedEmpty,{title:'匿名设备笔记',extra:'<div class="bottom-container"><span class="date">昨天 12:16 广东</span></div>'}));
 const r=p.run({command:'source'});assert.equal(r.state,'ready');assert.equal(r.sourcePublishedAt,'昨天 12:16');
 assert.equal(r.sourcePublishedAtLabel,'昨天 12:16 广东');assert.equal(r.sourceTimeNormalization,'xhs_bottom_date_region');assert.equal(r.sourcePublishedAtISO,'');
});

test('XHS region normalization never strips arbitrary date prose or invents structural evidence',()=>{
 for(const raw of ['昨天 12:16 待定地点','昨天 12:16 广东 买一送一','10-24 上海','昨天 25:61 广东','两天前 广东','2周前 广东','2天前 广东 买一送一','2天前 待定地点']){
  const r=page(detail('',{extra:'<div class="bottom-container"><span class="date">'+raw+'</span></div>'})).run({command:'source'});
  assert.equal(r.sourcePublishedAt,raw);assert.equal(r.sourceTimeNormalization,undefined);
 }
 for(const extra of ['<span class="date">昨天 12:16 广东</span>','<div class="bottom-container"><div class="date">昨天 12:16 广东</div></div>']){
  const r=page(detail('',{extra})).run({command:'source'});assert.equal(r.sourcePublishedAt,'昨天 12:16 广东');assert.equal(r.sourceTimeNormalization,undefined);
 }
 const edited=page(detail('',{extra:'<div class="bottom-container"><span class="date">昨天 12:16 广东 编辑</span></div>'})).run({command:'source'});
 assert.equal(edited.code,'source_time_unknown');
});


test('XHS profile navigation preserves loaded encoded xsec values while removing only observed tracking',()=>{
 const query='channel_type=web_search_result_notes&xsec_token=fixture%2b%2F%3D%25&parent_page_channel_type=web_profile_board&xsec_source=pc_user';
 const r=page(detail(comment(1,{href:profile+'?'+query}))).run({command:'read'});
 assert.equal(r.comments.length,1);assert.equal(r.comments[0].profileUrl,origin+profile+'?xsec_token=fixture%2b%2F%3D%25&xsec_source=pc_user');
 assert.equal(r.comments[0].authorId,author);
 const reordered=page(detail(comment(1,{href:profile+'?xsec_source=pc_user&xsec_token=fixture%2B%2F%3D'}))).run({command:'read'});
 assert.equal(reordered.comments[0].profileUrl,origin+profile+'?xsec_source=pc_user&xsec_token=fixture%2B%2F%3D');
});

test('different XHS profile navigation tokens keep one author identity for native canonical grouping',()=>{
 const r=page(detail(comment(1,{href:profile+'?xsec_token=fixture_a&xsec_source=pc_user'})+
  comment(2,{href:profile+'?xsec_token=fixture_b&xsec_source=pc_user'}))).run({command:'read'});
 assert.equal(r.comments.length,2);assert.deepEqual(r.comments.map(c=>c.authorId),[author,author]);
 assert.equal(new Set(r.comments.map(c=>new URL(c.profileUrl).pathname)).size,1);
 assert.notEqual(r.comments[0].profileUrl,r.comments[1].profileUrl); // Navigation is not the identity key.
});

test('XHS profile rejects unknown or repeated query fields, malformed values and unsafe origins',()=>{
 const bad=[profile+'?unknown=ignored',profile+'?tracking=ignored',profile+'?xsec_token=a&xsec_token=b',
  profile+'?xsec_source=a&xsec_source=b',profile+'?xsec_token=',profile+'?xsec_token',profile+'?xsec_token=a&',
  profile+'?xsec_token=%00',profile+'?xsec_token=a%20b',profile+'?xsec_token=%GG',profile+'?xsec_token=%',
  profile+'?channel_type=unobserved',profile+'?parent_page_channel_type=unobserved',profile+'?source=web_explore_feed',profile+'?source=web_user_page',
  profile+'?xsec_token='+'a'.repeat(1025),profile+'?xsec_source='+'a'.repeat(81),profile+'#fragment',profile+'?',
  'https://www.xiaohongshu.com.evil.test'+profile,'https://evil.xiaohongshu.com'+profile,
  'https://user@www.xiaohongshu.com'+profile,'https://www.xiaohongshu.com:8443'+profile,
  'https://%77ww.xiaohongshu.com'+profile,'http://www.xiaohongshu.com'+profile];
 for(const href of bad){const r=page(detail(comment(1,{href}))).run({command:'read'});assert.deepEqual(r.comments,[],href);assert.equal(r.diagnostics.skipped,1);}
});

test('XHS profile allows empty optional source, raw plus and no-query URLs without fabricating xsec fields',()=>{
 for(const [href,expected] of [[profile,origin+profile],[profile+'?xsec_source=',origin+profile+'?xsec_source='],
  [profile+'?xsec_token=fixture+raw',origin+profile+'?xsec_token=fixture+raw'],
  [profile+'?channel_type=web_search_result_notes&parent_page_channel_type=web_profile_board',origin+profile]]){
  const r=page(detail(comment(1,{href}))).run({command:'read'});assert.equal(r.comments[0].profileUrl,expected);
 }
});


test('XHS observed numeric relative source date plus region keeps exact supported prefix',()=>{
 for(const raw of ['2天前','15分钟前','3小时前','2 天前']){
  const label=raw+' 广东';
  const p=page(detail(observedEmpty,{title:'匿名接线笔记',extra:'<div class="bottom-container"><span class="date">'+label+'</span></div>'}));
  const r=p.run({command:'source'});assert.equal(r.state,'ready');assert.equal(r.sourcePublishedAt,raw);
  assert.equal(r.sourcePublishedAtLabel,label);assert.equal(r.sourceTimeNormalization,'xhs_bottom_date_region');assert.equal(r.sourcePublishedAtISO,'');
  assert.equal(p.run({command:'read'}).state,'waiting');
  assert.equal(p.run({command:'read'}).explicitZero,true);
 }
});

test('XHS strict bottom date region split supports calendar labels and full-year dates only',()=>{
 for(const raw of ['今天','昨天','前天','今天 08:01','昨天12:16','前天 23:59:01',
  '2026-10-25','2026-10-25 12:16','2026-1-2 00:00','2026-02-30']){
  const label=raw+' 上海';
  const r=page(detail('',{extra:'<div class="bottom-container"><span class="date">'+label+'</span></div>'})).run({command:'source'});
  assert.equal(r.state,'ready');assert.equal(r.sourcePublishedAt,raw);assert.equal(r.sourcePublishedAtLabel,label);
  assert.equal(r.sourceTimeNormalization,'xhs_bottom_date_region');assert.equal(r.sourcePublishedAtISO,'');
  // Separation is not date validation: native SourcePublicationGate rejects impossible dates.
 }
});

test('XHS just-now regional placeholder and loading never become source publication proof',()=>{
 for(const extra of ['<div class="bottom-container"><span class="date">刚刚 广东</span></div>',
  '<div class="bottom-container"><span class="date">2天前 广东</span></div><div>加载中</div>']){
  const r=page(detail('',{extra})).run({command:'source'});
  assert.equal(r.state,'waiting');assert.equal(r.code,'source_loading');assert.equal(r.sourcePublishedAt,undefined);
 }
});


test('XHS observed nonempty comment shape accepts web_user_board tracking and preserves public navigation',()=>{
 const query='channel_type=web_search_result_notes&parent_page_channel_type=web_user_board&xsec_token=fixture_comment%2B%2F%3D&xsec_source=pc_comment';
 const html=detail(comment(1,{name:'合成评论者甲',href:profile+'?'+query,
  date:'<span>09-06</span><span class="location">福建</span>'})+
  comment(2,{name:'合成评论者乙',href:'/user/profile/'+hex(21)+'?'+query,
  date:'<span>09-08</span><span class="location">浙江</span>'}),
  {extra:'<div class="total">共42条评论</div>'});
 const url=source+'&source=web_user_page';
 const r=page(html,url).run({command:'read',sourceUrl:url});
 assert.equal(r.state,'ready');assert.equal(r.explicitZero,false);assert.equal(r.comments.length,2);
 assert.deepEqual(r.comments.map(c=>c.publishedAt),['09-06·福建','09-08·浙江']);
 assert.deepEqual(r.comments.map(c=>c.authorId),[author,hex(21)]);
 assert.equal(r.comments[0].profileUrl,origin+profile+'?xsec_token=fixture_comment%2B%2F%3D&xsec_source=pc_comment');
 assert.equal(r.comments[0].sourceUrl,url);assert.equal(r.comments[0].commentId,hex(1));
 assert.equal(r.comments[0].publishedAtISO,''); // Rendered comment date is not a source timestamp.
 assert.ok(r.comments.every(c=>!c.profileUrl.includes('channel_type=')));
});

test('XHS comment profile observed tracking exception remains exact and single-valued',()=>{
 for(const query of ['parent_page_channel_type=web_user_board_extra',
  'parent_page_channel_type=web_user_board&parent_page_channel_type=web_profile_board',
  'parent_page_channel_type=web_user_board&unknown=1']){
  const r=page(detail(comment(1,{href:profile+'?'+query}))).run({command:'read'});
  assert.deepEqual(r.comments,[]);assert.equal(r.diagnostics.skipped,1);
 }
});


test('XHS matching search waits for blank input hydration, then requires a fresh stable latest proof',()=>{
 const p=page('<input id="search-input-ai" value="">'+card(1),origin+'/search_result_ai?keyword='+encodeURIComponent(keyword));
 const input=p.document.querySelector('#search-input-ai');
 for(const command of ['prepare_search','search','search_advance']){
  const r=p.rawRun({command});assert.equal(r.state,'waiting');assert.equal(r.latestOrderConfirmed,false);assert.deepEqual(r.videos,[]);
 }
 assert.equal(p.clicks(),0);
 input.value=keyword;
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'ready');
 assert.equal(p.rawRun({command:'search'}).videos.length,1);
 input.value=' ';
 assert.equal(p.rawRun({command:'search'}).state,'waiting');
 input.value=keyword;
 assert.equal(p.rawRun({command:'search'}).state,'waiting');
 assert.equal(p.rawRun({command:'search'}).state,'ready');
});

test('XHS matching search waits for filter mount instead of treating hydration as an unsupported platform',()=>{
 const p=page('<input id="search-input-ai" value="音响"><div id="delayed-filters" hidden>'+filters()+'</div>'+card(1),search,{controls:false});
 for(let i=0;i<3;i++){
  const r=p.rawRun({command:'prepare_search'});assert.equal(r.state,'waiting');assert.equal(r.latestOrderConfirmed,false);assert.deepEqual(r.videos,[]);
 }
 assert.equal(p.clicks(),0);
 p.document.querySelector('#delayed-filters').removeAttribute('hidden');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'ready');
 assert.equal(p.rawRun({command:'search'}).videos.length,1);
 // A disappearing control cannot reuse an earlier ready proof.
 p.document.querySelector('#delayed-filters').setAttribute('hidden','');
 assert.equal(p.rawRun({command:'search'}).state,'waiting');
 p.document.querySelector('#delayed-filters').removeAttribute('hidden');
 assert.equal(p.rawRun({command:'search'}).state,'waiting');
 assert.equal(p.rawRun({command:'search'}).state,'ready');
});

test('XHS hydration waiting never masks explicit keyword mismatch, bad origin, login or CAPTCHA',()=>{
 const cases=[
  ['<input id="search-input-ai" value="其他">',search,'source_mismatch'],
  ['<input id="search-input-ai" value="">',origin+'/search_result?keyword=其他','source_mismatch'],
  ['<input id="search-input-ai" value="">',search+'&keyword='+encodeURIComponent(keyword),'source_mismatch'],
  ['<input id="search-input-ai" value="">','https://evil.invalid/search_result?keyword='+encodeURIComponent(keyword),'invalid_origin'],
  ['<input id="search-input-ai" value=""><p>请先登录</p>',search,'login'],
  ['<input id="search-input-ai" value=""><p>请完成安全验证</p>',search,'verification'],
  ['<input id="search-input-ai" value=""><input id="search-input-ai" value="">',search,'source_mismatch']
 ];
 for(const [html,url,code] of cases){
  const p=page(html,url,{controls:false});const r=p.rawRun({command:'prepare_search'});
  assert.equal(r.state,'blocked');assert.equal(r.code,code);assert.equal(p.clicks(),0);
 }
});


test('XHS both observed search input IDs validate exact visible keyword on current route',()=>{
 const url=search+'&source=web_explore_feed&type=51';
 for(const id of ['search-input','search-input-ai']){
  const valid=page('<input id="'+id+'" value="音响">'+card(1),url).run({command:'search'});
  assert.equal(valid.state,'ready');assert.equal(valid.latestOrderConfirmed,true);
  const wrong=page('<input id="'+id+'" value="其他">'+card(1),url).rawRun({command:'prepare_search'});
  assert.equal(wrong.state,'blocked');assert.equal(wrong.code,'source_mismatch');
  const p=page('<input id="'+id+'" value="">'+card(1),url);
  assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
  p.document.querySelector('#'+id).value=keyword;
  assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
  assert.equal(p.rawRun({command:'prepare_search'}).state,'ready');
 }
});

test('XHS search input union accepts one visible field but never two competing observed fields',()=>{
 for(const [active,other] of [['search-input','search-input-ai'],['search-input-ai','search-input']]){
  const p=page('<input id="'+active+'" value="音响"><input hidden id="'+other+'" value="其他">'+card(1),search);
  assert.equal(p.run({command:'search'}).state,'ready');
  p.document.querySelector('#'+other).removeAttribute('hidden');
  const r=p.rawRun({command:'search'});assert.equal(r.state,'blocked');assert.equal(r.code,'source_mismatch');
  p.document.querySelector('#'+other).value=keyword;
  assert.equal(p.rawRun({command:'prepare_search'}).code,'source_mismatch');
 }
});


test('XHS observed hover-only filter opens by normal events and is trusted only on a later visible-menu poll',()=>{
 // Event-backed synthetic fixture, not a real WKWebView/platform interaction test.
 const html=filters().replace('<div class="filters-wrapper">','<div hidden class="filters-wrapper">')+card(1);
 const p=page(html,search,{controls:false,mouseEvents:true});
 const toggle=p.document.querySelector('.filter'),menu=p.document.querySelector('.filters-wrapper'),events=[];
 toggle.addEventListener('mouseover',e=>events.push([e.type,e.bubbles]));
 toggle.addEventListener('mouseenter',e=>{events.push([e.type,e.bubbles]);menu.removeAttribute('hidden');});
 toggle.click();assert.equal(menu.hasAttribute('hidden'),true); // click alone does not open this shape
 const clicks=p.clicks();
 const opened=p.rawRun({command:'prepare_search'});
 assert.equal(opened.state,'waiting');assert.equal(opened.latestOrderConfirmed,false);assert.deepEqual(opened.videos,[]);
 assert.equal(p.clicks(),clicks);assert.deepEqual(events,[['mouseover',true],['mouseenter',false]]);
 assert.equal(menu.hasAttribute('hidden'),false);
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');
 assert.equal(p.rawRun({command:'prepare_search'}).state,'ready');
 assert.equal(p.rawRun({command:'search'}).videos.length,1);
});

test('XHS ignored hover events fail explicitly after three attempts, never fabricate filter selection',()=>{
 const p=page('<div class="filter"><span>筛选</span></div>'+card(1),search,{controls:false,mouseEvents:true});
 const toggle=p.document.querySelector('.filter'),events=[];
 for(const type of ['mouseover','mouseenter'])toggle.addEventListener(type,e=>events.push(e.type));
 for(let i=0;i<3;i++){
  const r=p.rawRun({command:'prepare_search'});assert.equal(r.state,'waiting');assert.equal(r.latestOrderConfirmed,false);
 }
 const failed=p.rawRun({command:'prepare_search'});
 assert.equal(failed.state,'blocked');assert.equal(failed.code,'latest_sort_unconfirmed');assert.equal(failed.latestOrderConfirmed,false);
 assert.equal(events.length,6);assert.equal(p.clicks(),0);assert.equal(p.document.querySelector('.filters-wrapper'),null);
 assert.equal(p.document.querySelector('.tags.active'),null);
});

test('XHS hover is confined to the unique visible filter and cannot accept duplicate real menus',()=>{
 const html='<div hidden class="filter"><span>筛选</span></div>'+filters().replace('<div class="filters-wrapper">','<div hidden class="filters-wrapper">')+card(1);
 const p=page(html,search,{controls:false,mouseEvents:true});
 const toggles=[...p.document.querySelectorAll('.filter')],events=[];
 toggles[0].addEventListener('mouseenter',()=>events.push('hidden'));
 toggles[1].addEventListener('mouseenter',()=>events.push('visible'));
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');assert.deepEqual(events,['visible']);
 toggles[0].removeAttribute('hidden');
 assert.equal(p.rawRun({command:'prepare_search'}).code,'latest_sort_unconfirmed');assert.deepEqual(events,['visible']);
 const duplicate=page(filters()+filters()+card(1),search,{controls:false,mouseEvents:true});
 assert.equal(duplicate.rawRun({command:'prepare_search'}).code,'latest_sort_unconfirmed');assert.equal(duplicate.clicks(),0);
});


test('XHS observed filtered label reopens closed real menu and revalidates active selections',()=>{
 const html=filters().replace('<span>筛选</span>','<span>已筛选</span>')+card(1);
 const p=page(html,search,{controls:false,mouseEvents:true});
 const toggle=p.document.querySelector('.filter'),menu=p.document.querySelector('.filters-wrapper');
 const selected=()=>[...menu.querySelectorAll('.tags.active')].map(n=>n.textContent);
 assert.deepEqual(selected(),['最新','一周内']);
 assert.equal(p.run({command:'search'}).state,'ready');
 menu.setAttribute('hidden','');let opened=0;
 toggle.addEventListener('mouseenter',()=>{opened++;menu.removeAttribute('hidden');});
 const retry=p.rawRun({command:'prepare_search'});
 assert.equal(retry.state,'waiting');assert.equal(retry.latestOrderConfirmed,false);assert.deepEqual(retry.videos,[]);
 assert.equal(opened,1);assert.deepEqual(selected(),['最新','一周内']);
 assert.equal(p.rawRun({command:'prepare_search'}).state,'ready');
 assert.equal(p.rawRun({command:'search'}).videos.length,1);
 assert.equal(p.clicks(),0);
});

test('XHS filtered-label toggle still excludes aria-hidden duplicates and arbitrary similar labels',()=>{
 const html='<div aria-hidden="true" class="filter"><span>已筛选</span></div>'+filters().replace('<span>筛选</span>','<span>已筛选</span>').replace('<div class="filters-wrapper">','<div hidden class="filters-wrapper">')+card(1);
 const p=page(html,search,{controls:false,mouseEvents:true});
 const toggles=[...p.document.querySelectorAll('.filter')],entered=[];
 toggles[0].addEventListener('mouseenter',()=>entered.push('hidden'));
 toggles[1].addEventListener('mouseenter',()=>entered.push('visible'));
 assert.equal(p.rawRun({command:'prepare_search'}).state,'waiting');assert.deepEqual(entered,['visible']);
 for(const label of ['已筛选其他','全部筛选']){
  const q=page('<div class="filter"><span>'+label+'</span></div>'+card(1),search,{controls:false,mouseEvents:true});
  let calls=0;q.document.querySelector('.filter').addEventListener('mouseenter',()=>calls++);
  assert.equal(q.rawRun({command:'prepare_search'}).state,'waiting');assert.equal(calls,0);
 }
});


test('XHS observed nested bottom-left source date supports two real-shaped anonymous comments',()=>{
 const query='channel_type=web_search_result_notes&parent_page_channel_type=web_user_board&xsec_token=fixture_nested%2B%2F%3D&xsec_source=pc_comment';
 const directName=(id,nickname)=>'<a class="name" href="'+esc('/user/profile/'+id+'?'+query)+'">'+nickname+'</a>';
 const rows=comment(1,{nameHTML:'',date:'<span>3小时前</span><span class="location">广东</span>'})
  .replace('<div class="name"></div>',directName(author,'匿名用户甲'))+
  comment(2,{nameHTML:'',date:'<span>2小时前</span><span class="location">福建</span>'})
  .replace('<div class="name"></div>',directName(hex(21),'匿名用户乙'));
 const metadata='<div class="note-content"><div class="bottom-container"><div class="bottom-left"><span class="date" selected-disabled-search="">6小时前 广东</span></div></div></div>';
 const p=page(detail('<div class="note-scroller"><div class="total">共2条评论</div>'+rows+'</div>',{extra:metadata}));
 const sourceResult=p.run({command:'source'});
 assert.equal(sourceResult.state,'ready');assert.equal(sourceResult.sourcePublishedAt,'6小时前');
 assert.equal(sourceResult.sourcePublishedAtLabel,'6小时前 广东');assert.equal(sourceResult.sourceTimeNormalization,'xhs_bottom_date_region');
 const read=p.run({command:'read'});assert.equal(read.state,'ready');assert.equal(read.comments.length,2);
 assert.deepEqual(read.comments.map(c=>c.authorId),[author,hex(21)]);
 assert.deepEqual(read.comments.map(c=>c.publishedAt),['3小时前·广东','2小时前·福建']);
 assert.equal(read.comments[0].profileUrl,origin+profile+'?xsec_token=fixture_nested%2B%2F%3D&xsec_source=pc_comment');
 const scroller=p.document.querySelector('.note-scroller');scroller.style.overflowY='scroll';
 const moved=scrollable(scroller,{height:706,total:2674});
 assert.equal(p.run({command:'advance'}).moved,true);assert.equal(moved.length,1);
});

test('XHS nested source-date exception remains exact and rejects edited publication metadata',()=>{
 for(const extra of [
  '<div class="bottom-container"><div class="unknown"><span class="date">6小时前 广东</span></div></div>',
  '<div class="bottom-left"><span class="date">6小时前 广东</span></div>',
  '<div class="bottom-container"><div class="wrapper"><div class="bottom-left"><span class="date">6小时前 广东</span></div></div></div>',
  '<div class="bottom-container"><div class="bottom-left"><div class="date">6小时前 广东</div></div></div>'
 ]){
  const r=page(detail('',{extra})).run({command:'source'});
  assert.equal(r.sourcePublishedAt,'6小时前 广东');assert.equal(r.sourceTimeNormalization,undefined);
 }
 for(const label of ['编辑于 6小时前 广东','6小时前 广东 编辑于今天']){
  const extra='<div class="bottom-container"><div class="bottom-left"><span class="date">'+label+'</span></div></div>';
  assert.equal(page(detail('',{extra})).run({command:'source'}).code,'source_time_unknown');
 }
});
