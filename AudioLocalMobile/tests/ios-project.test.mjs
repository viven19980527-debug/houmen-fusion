import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,access} from 'node:fs/promises';
const root=new URL('../',import.meta.url);
test('iOS工程静态检查：共享采集脚本与资源存在，无手机号登录/管理后台',async()=>{
 const project=await readFile(new URL('ios/AudioLocal.xcodeproj/project.pbxproj',root),'utf8');
 for(const f of ['AudioLocalApp.swift','HomeView.swift','CommentStore.swift','BrowserCollector.swift']){assert.ok(project.includes(f));const code=await readFile(new URL('ios/AudioLocal/'+f,root),'utf8');assert.equal(/chatgpt\.site|TWILIO_|signin-with-chatgpt|CNContactStore|CTTelephonyNetworkInfo/.test(code),false)}
 assert.ok(project.includes('AudioLocal/collector-ios.js'));assert.ok(project.includes('IPHONEOS_DEPLOYMENT_TARGET = 16.0'));
 const manifest=await readFile(new URL('ios/AudioLocal/Info.plist',root),'utf8');assert.equal(/NSCameraUsageDescription|NSContactsUsageDescription|NSLocationWhenInUseUsageDescription|NSAllowsArbitraryLoads/.test(manifest),false);
 const storage=await readFile(new URL('ios/AudioLocal/CommentStore.swift',root),'utf8');assert.ok(storage.includes('isExcludedFromBackup = true'));assert.ok(storage.includes('[.atomic, .completeFileProtection]'));
 const assets=new URL('ios/AudioLocal/Assets.xcassets/AppIcon.appiconset/',root),json=JSON.parse(await readFile(new URL('Contents.json',assets),'utf8'));for(const image of json.images)await access(new URL(image.filename,assets));
});
test('iOS网页不暴露原生消息桥，任务支持停止与后台取消（静态检查，不是编译）',async()=>{const code=await readFile(new URL('ios/AudioLocal/BrowserCollector.swift',root),'utf8');assert.equal(/userContentController\.add\(|addScriptMessageHandler/.test(code),false);assert.ok(code.includes('task?.cancel()'));assert.ok(code.includes('try Task.checkCancellation()'));const ui=await readFile(new URL('ios/AudioLocal/HomeView.swift',root),'utf8');assert.ok(ui.includes('phase != .active'));assert.ok(ui.includes('.onDisappear { collector.stop() }'))});
