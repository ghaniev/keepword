import {test} from 'node:test';
import assert from 'node:assert/strict';
import {layoutDay} from '../src/calendarLayout.ts';
test('places overlaps in lanes and clips events spanning midnight',()=>{
 const day=new Date(2026,9,22);const event=(id,start,end)=>({id,start:new Date(2026,9,22,start),end:new Date(2026,9,22,end),allDay:false});
 const items=layoutDay([event('a',9,11),event('b',10,12),event('c',13,14),event('overnight',-1,1)],day);
 assert.equal(items[0].start,0);assert.equal(items[1].lanes,2);assert.notEqual(items[1].lane,items[2].lane);assert.equal(items[3].lanes,1);
});
