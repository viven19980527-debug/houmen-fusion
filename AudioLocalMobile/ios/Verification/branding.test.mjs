import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
const root=new URL('../AudioLocal/',import.meta.url);
test('iOS branding changes visible name and style without changing local identity',()=>{
 const info=readFileSync(new URL('Info.plist',root),'utf8');
 assert.match(info,/<key>CFBundleDisplayName<\/key><string>后门<\/string>/);
 assert.match(info,/<key>UIUserInterfaceStyle<\/key><string>Dark<\/string>/);
 assert.match(readFileSync(new URL('../AudioLocal.xcodeproj/project.pbxproj',root),'utf8'),/cn\.shengxun\.local/);
 assert.match(readFileSync(new URL('CommentStore.swift',root),'utf8'),/appendingPathComponent\("ShengxunLocal"/);
 assert.match(readFileSync(new URL('BrowserCollector.swift',root),'utf8'),/后门 0\.2\.0/);
});
test('all iOS app icons have required exact square dimensions and opaque RGB PNG encoding',()=>{
 const dir=new URL('Assets.xcassets/AppIcon.appiconset/',root);
 const entries=JSON.parse(readFileSync(new URL('Contents.json',dir),'utf8')).images;
 assert.equal(entries.length,9);
 for(const item of entries){
  const data=readFileSync(new URL(item.filename,dir));
  assert.equal(data.subarray(0,8).toString('hex'),'89504e470d0a1a0a');
  const size=Number(item.size.split('x')[0])*Number(item.scale.replace('x',''));
  assert.equal(data.readUInt32BE(16),size);assert.equal(data.readUInt32BE(20),size);
  assert.equal(data[24],8);assert.equal(data[25],2,'RGB, no alpha channel');
  assert.ok(data.length>500,'not an empty image');
 }
});
