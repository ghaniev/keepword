import {test} from 'node:test';
import assert from 'node:assert/strict';
import {eventsFromICS} from '../src/ics.ts';
const from=new Date('2026-10-19T00:00:00Z'),to=new Date('2026-10-26T00:00:00Z');
const wrap=(events)=>`BEGIN:VCALENDAR\r\nVERSION:2.0\r\n${events}\r\nEND:VCALENDAR`;
test('expands recurring events and respects excluded dates',()=>{
 const events=eventsFromICS(wrap('BEGIN:VEVENT\r\nUID:daily\r\nDTSTART:20261019T090000Z\r\nDTEND:20261019T100000Z\r\nRRULE:FREQ=DAILY;COUNT=3\r\nEXDATE:20261020T090000Z\r\nSUMMARY:Standup\r\nEND:VEVENT'),from,to);
 assert.deepEqual(events.map(e=>e.start.toISOString()),['2026-10-19T09:00:00.000Z','2026-10-21T09:00:00.000Z']);
});
test('moves a single recurring instance without duplicating it',()=>{
 const events=eventsFromICS(wrap('BEGIN:VEVENT\r\nUID:series\r\nDTSTART:20261019T090000Z\r\nDTEND:20261019T100000Z\r\nRRULE:FREQ=DAILY;COUNT=2\r\nSUMMARY:Planning\r\nEND:VEVENT\r\nBEGIN:VEVENT\r\nUID:series\r\nRECURRENCE-ID:20261020T090000Z\r\nDTSTART:20261020T110000Z\r\nDTEND:20261020T120000Z\r\nSUMMARY:Moved planning\r\nEND:VEVENT'),from,to);
 assert.equal(events.length,2);assert.equal(events[1].start.toISOString(),'2026-10-20T11:00:00.000Z');assert.equal(events[1].title,'Moved planning');
});
test('unfolds Unicode titles and recognizes all-day events',()=>{
 const events=eventsFromICS(wrap('BEGIN:VEVENT\r\nUID:day\r\nDTSTART;VALUE=DATE:20261021\r\nDTEND;VALUE=DATE:20261022\r\nSUMMARY:Планирование \r\n команды\r\nEND:VEVENT'),from,to);
 assert.equal(events[0].allDay,true);assert.equal(events[0].title,'Планирование команды');
});
