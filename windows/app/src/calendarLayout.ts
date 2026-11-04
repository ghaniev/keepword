import type {CalendarEvent} from './ics';
export function layoutDay(events:CalendarEvent[],day:Date){
 const from=new Date(day);from.setHours(0,0,0,0);const to=new Date(from);to.setDate(to.getDate()+1);
 const visible=events.filter(e=>!e.allDay&&e.start<to&&e.end>from).sort((a,b)=>a.start.getTime()-b.start.getTime());
 const placed: {event:CalendarEvent;start:number;end:number;lane:number;lanes:number}[]=[];
 let cluster:typeof placed=[],ends:number[]=[];
 const finish=()=>{for(const item of cluster)item.lanes=ends.length;cluster=[];ends=[];};
 for(const event of visible){
  const minutes=(date:Date)=>date.getHours()*60+date.getMinutes();
  const start=event.start<from?0:minutes(event.start),end=event.end>=to?1440:minutes(event.end);
  if(cluster.length&&ends.every(end=>end<=start))finish();
  let lane=ends.findIndex(end=>end<=start);if(lane<0)lane=ends.length;ends[lane]=end;
  const item={event,start,end:Math.max(start+15,end),lane,lanes:1};cluster.push(item);placed.push(item);
 }
 finish();return placed;
}
