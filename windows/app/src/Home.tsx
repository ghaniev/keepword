import {Row,dateLabel,edit,timestamp,useRows,useT} from './api';
import Icon from './Icon';

export default function Home({meetings,revision,language,onOpen,onBrowse,onCalendar,onRecord,onError}:{
  meetings:Row[];revision:number;language:string;onOpen:(id:string)=>void;
  onBrowse:()=>void;onCalendar:()=>void;onRecord:()=>void;onError:(message:string)=>void;
}) {
  const t=useT();
  const actions=useRows('actions',null,revision,onError);
  const soon=new Date();soon.setHours(0,0,0,0);soon.setDate(soon.getDate()+3);
  const due=actions.filter(a=>!a.completed&&a.due_date&&new Date(a.due_date)<soon);
  const hour=new Date().getHours();
  return <section className="page home"><div className="home-content">
    <div className="home-heading"><h1>{t(hour<12?'Good morning':hour<18?'Good afternoon':'Good evening')}</h1><p>{new Date().toLocaleDateString(language,{weekday:'long',day:'numeric',month:'long'})}</p></div>
    <section className="home-section"><h2><Icon name="calendar"/>{t('Upcoming Meetings')}</h2><div className="calendar-connect"><div><strong>{t('Your schedule, alongside your notes')}</strong><p>{t('Open your calendar to view meetings and start a recording.')}</p></div><button className="secondary" onClick={onCalendar}>{t('Open calendar')}</button></div></section>
    <section className="home-section"><h2><Icon name="check"/>{t('Due Soon')}{due.length>0&&<span className="count">{due.length}</span>}</h2>{!due.length?<p className="section-placeholder">{t('No open action items with a due date.')}</p>:due.slice(0,6).map(a=><div className="action-row" key={a.id}><input type="checkbox" aria-label={a.text} checked={false} onChange={()=>edit('action',String(a.id),{completed:true}).catch(e=>onError(String(e)))}/><div className="grow"><span>{a.text}</span><small>{a.assignee} · <button className="link" onClick={()=>onOpen(a.meeting_id)}>{a.meeting_title}</button></small></div><small className="due-date">{dateLabel(a.due_date,language,false)}</small></div>)}</section>
    <section className="home-section"><div className="section-heading"><h2><Icon name="document"/>{t('Recent Documents')}</h2><button className="link" onClick={onBrowse}>{t('Show all')} <span aria-hidden="true">›</span></button></div>
      {meetings.length?<ul className="cards">{meetings.slice(0,6).map(m=><li key={m.id}><button className="meeting-card" onClick={()=>onOpen(m.id)}><h3>{m.title}</h3><small>{dateLabel(m.createdAt,language)} · {timestamp(m.duration)}</small><p>{m.summary||t('No summary yet')}</p></button></li>)}</ul>:<div className="first-recording"><Icon name="waveform" size={30}/><h3>{t('Record Your First Call')}</h3><p>{t('Record a call or import an audio file.')}</p><button className="secondary" onClick={onRecord}><Icon name="record"/>{t('Start Recording')}</button></div>}
    </section>
  </div></section>;
}
