import ICAL from 'ical.js';
export type CalendarEvent={id:string;title:string;start:Date;end:Date;allDay:boolean;attendees:string[];location:string;description:string};
export function eventsFromICS(text:string,from:Date,to:Date):CalendarEvent[]{
 const calendar=new ICAL.Component(ICAL.parse(text));
 calendar.getAllSubcomponents('vtimezone').forEach(c=>{const tz=new ICAL.Timezone(c);ICAL.TimezoneService.register(tz,tz.tzid)});
 const parts=calendar.getAllSubcomponents('vevent');const result:CalendarEvent[]=[];
 for(const component of parts){if(component.hasProperty('recurrence-id')||component.getFirstPropertyValue('status')==='CANCELLED')continue;const event=new ICAL.Event(component);parts.filter(c=>c.getFirstPropertyValue('uid')===event.uid&&c.hasProperty('recurrence-id')).forEach(c=>event.relateException(c));
 const add=(start:any)=>{const occurrence=event.getOccurrenceDetails(start);if(occurrence.item.component.getFirstPropertyValue('status')==='CANCELLED')return;const first=occurrence.startDate.toJSDate(),end=occurrence.endDate.toJSDate();if(end<=from||first>=to)return;result.push({id:`ics:${event.uid}|${Math.floor(first.getTime()/1000)}`,title:occurrence.item.summary||'Untitled',start:first,end,allDay:occurrence.startDate.isDate,attendees:component.getAllProperties('attendee').map(p=>String(p.getParameter('cn')||p.getFirstValue())),location:occurrence.item.location||'',description:occurrence.item.description||''})};
 if(event.isRecurring()){const iterator=event.iterator();for(let count=0;count<50000;count++){const next=iterator.next();if(!next||next.toJSDate()>=to)break;add(next)}}else add(event.startDate);
 }return result.sort((a,b)=>a.start.getTime()-b.start.getTime());
}
