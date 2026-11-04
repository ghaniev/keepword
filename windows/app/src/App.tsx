import {useEffect,useState,useRef} from 'react';
import {listen} from '@tauri-apps/api/event';
import {call,view,edit,Locale,Row,useT,timestamp,statusLabel,useRows} from './api';
import Document from './Document';
import Chat from './Chat';
import Settings from './Settings';
import Organization from './Organization';
import Calendar from './Calendar';
import Overlay from './Overlay';
import Icon,{IconName} from './Icon';
import Home from './Home';
import {dateLabel} from './api';
const SECTIONS: {name:string;icon:IconName}[]=[{name:'Home',icon:'home'},{name:'Chat',icon:'chat'},{name:'Calendar',icon:'calendar'},{name:'Action Items',icon:'check'},{name:'People',icon:'people'},{name:'Tags',icon:'tag'},{name:'Live queries',icon:'repeat'}];
const appIcon=new URL('../app-icon.png',import.meta.url).href;
export default function App(){const[language,setLanguage]=useState(localStorage.getItem('language')||'ru');const overlay=new URLSearchParams(location.search).get('overlay');return <Locale.Provider value={language}>{overlay?<Overlay initialId={overlay}/>:<Shell language={language} onLanguage={s=>{setLanguage(s);localStorage.setItem('language',s)}}/>}</Locale.Provider>}
function Shell({language,onLanguage}:{language:string;onLanguage:(s:string)=>void}){
 const t=useT();const[section,setSection]=useState('Home'),[meetings,setMeetings]=useState<Row[]>([]),[selected,setSelected]=useState(''),[seek,setSeek]=useState(-1),[revision,setRevision]=useState(0),[error,setError]=useState(''),[search,setSearch]=useState(''),[results,setResults]=useState<Row[]|null>(null),[recording,setRecording]=useState<Row|null>(null),[mode,setMode]=useState('both'),[mics,setMics]=useState<string[]>([]),[mic,setMic]=useState(''),[busy,setBusy]=useState(false),[levels,setLevels]=useState({mic:0,system:0}),[folder,setFolder]=useState('');const recordingRef=useRef<Row|null>(null);
 const folders=useRows('folders',null,revision,setError),templates=useRows('templates',null,revision,setError);const[editingFolder,setEditingFolder]=useState<Row|null>(null);
 const[callPrompt,setCallPrompt]=useState<Row|null>(null);
 useEffect(()=>{const off=listen<Row>('call-detected',e=>setCallPrompt(e.payload));const live=listen<string>('live-error',e=>setError(e.payload));return()=>{off.then(f=>f());live.then(f=>f())}},[]);
 const open=(id:string,time=-1)=>{if(folder==='unsorted'?meetings.find(m=>m.id===id)?.folderId:folder&&!meetings.some(m=>m.id===id&&m.folderId===folder))setFolder('');setSection('Documents');setSelected(id);setSeek(time);setSearch('');setResults(null)};
 const refresh=()=>call<Row[]>('list_meetings').then(setMeetings).catch(e=>setError(String(e)));
 useEffect(()=>{refresh();call<Row>('preferences').then(p=>onLanguage(p.settings.language)).catch(e=>setError(String(e)));call<string[]>('input_devices').then(setMics).catch(e=>setError(String(e)));
 const off=listen('library-changed',()=>{setRevision(r=>r+1);refresh()});const meter=listen<Row>('recorder',({payload:e})=>{if(e.kind==='level')setLevels(l=>e.mic?{...l,mic:e.rms}:{...l,system:e.rms});else setError(e.message||'The microphone is delivering silence. Check Windows microphone permissions.');});
 const timer=setInterval(()=>call<Row|null>('recording_state').then(r=>{recordingRef.current=r;setRecording(r)}).catch(()=>{}),500);
 const key=(e:KeyboardEvent)=>{if(e.ctrlKey&&e.key.toLowerCase()==='b'&&recordingRef.current){e.preventDefault();edit('bookmark',recordingRef.current.id,{time:recordingRef.current.elapsed,label:''}).catch(e=>setError(String(e)))}};window.addEventListener('keydown',key);
 return()=>{off.then(f=>f());meter.then(f=>f());clearInterval(timer);window.removeEventListener('keydown',key)}},[]);
 useEffect(()=>{if(!search.trim()){setResults(null);return;}const timer=setTimeout(()=>view<Row[]>('search',null,search).then(setResults).catch(e=>setError(String(e))),250);return()=>clearTimeout(timer)},[search,revision]);
 async function toggle(){if(busy)return;setBusy(true);try{if(recording){await call('stop_recording');setRecording(null);setLevels({mic:0,system:0})}else{const r=await call<Row>('start_recording',{title:`${language==='ru'?'Встреча':'Meeting'} ${new Date().toLocaleString(language)}`,mode,mic:mic||null});if(r.warning)setError(r.warning);setRecording({id:r.id,elapsed:0,paused:false,muted:false});open(r.id)}}catch(e){setError(String(e))}finally{setBusy(false);refresh()}}
 function navigate(s:string){setSection(s);setSelected('');setFolder('');setSearch('')}
 const filtered=meetings.filter(m=>folder==='unsorted'?!m.folderId:!folder||m.folderId===folder);
 const listTitle=folder==='unsorted'?t('Unsorted'):folder?folders.find(f=>f.id===folder)?.name??t('Folders'):t('All Notes');
 function browse(scope:string){const rows=meetings.filter(m=>scope==='unsorted'?!m.folderId:!scope||m.folderId===scope);setFolder(scope);setSection('Documents');setSelected(rows[0]?.id??'');setSeek(-1);setSearch('')}
 async function importMedia(){try{const ids=await call<string[]>('import_media');if(ids[0])open(ids[0]);refresh()}catch(e){setError(String(e))}}
 async function newNote(){try{const id=await call<string>('new_note',{title:t('New note')});open(id);refresh()}catch(e){setError(String(e))}}
 return <div className="root">
  <aside className="sidebar" aria-label={t('Navigation')}>
   <div className="brand"><img className="brand-icon" src={appIcon} alt=""/><strong>Keepword</strong></div>
   <div className="record-row">
    <button className={recording?'record on':'record'} disabled={busy} onClick={toggle}><Icon name={recording?'stop':'record'}/>{busy?t('Please wait…'):recording?timestamp(recording.elapsed):t('Record')}</button>
    <button className="import-button" title={t('Import')} aria-label={t('Import')} onClick={importMedia}><Icon name="import"/></button>
   </div>
   {recording&&<div className="controls">
    <button title={t(recording.paused?'Resume':'Pause')} aria-label={t(recording.paused?'Resume':'Pause')} onClick={()=>call('set_paused',{paused:!recording.paused}).catch(e=>setError(String(e)))}><Icon name={recording.paused?'play':'pause'}/></button>
    <button className={recording.muted?'muted-mic':''} title={t(recording.muted?'Unmute':'Mute')} aria-label={t(recording.muted?'Unmute':'Mute')} onClick={()=>call('set_mic_muted',{muted:!recording.muted}).catch(e=>setError(String(e)))}><Icon name="mic"/></button>
    <button title={t('Bookmark')} aria-label={t('Bookmark')} onClick={()=>edit('bookmark',recording.id,{time:recording.elapsed,label:''}).catch(e=>setError(String(e)))}><Icon name="bookmark"/></button>
    <button title={t('Overlay')} aria-label={t('Overlay')} onClick={()=>call('show_overlay',{id:recording.id}).catch(e=>setError(String(e)))}><Icon name="expand"/></button>
    {(['mic','system'] as const).map(source=><div key={source} className="meter"><span>{t(source==='mic'?'Mic':'System')}</span><div><i style={{width:`${levels[source]*100}%`}}/></div></div>)}
   </div>}
   <nav aria-label={t('Sections')}>{SECTIONS.map(s=><button key={s.name} aria-current={section===s.name?'page':undefined} className={section===s.name?'item active':'item'} onClick={()=>navigate(s.name)}><Icon name={s.icon}/><span>{t(s.name)}</span>{s.name==='Chat'&&<small className="beta-badge">Beta</small>}</button>)}</nav>
   <div className="folder-heading"><span>{t('Folders')}</span><button aria-label={t('New folder')} title={t('New folder')} onClick={()=>{setEditingFolder({id:'',name:'',parent_id:null,context:'',color:'blue',icon:'folder',template_id:null})}}><Icon name="plus" size={14}/></button></div>
   <div className="folders">
    <button className={section==='Documents'&&!folder?'item active':'item'} onClick={()=>browse('')}><Icon name="tray"/><span>{t('All Notes')}</span><small className="count">{meetings.length}</small></button>
    <button className={section==='Documents'&&folder==='unsorted'?'item active':'item'} onClick={()=>browse('unsorted')}><Icon name="tray"/><span>{t('Unsorted')}</span><small className="count">{meetings.filter(m=>!m.folderId).length}</small></button>
    {folders.map(f=><div className="folder-row" key={f.id}><button className={folder===f.id&&section==='Documents'?'item active':'item'} onClick={()=>browse(f.id)} onContextMenu={e=>{e.preventDefault();setEditingFolder({...f})}} style={{paddingLeft:f.parent_id?24:10}}><Icon name="folder" style={{color:f.color}}/><span>{f.name}</span><small className="count">{f.count}</small></button><button className="folder-edit" title={t('Edit folder')} aria-label={`${t('Edit folder')}: ${f.name}`} onClick={()=>setEditingFolder({...f})}>⋯</button></div>)}
   </div>
   <button className={section==='Recently Deleted'?'item active':'item'} onClick={()=>navigate('Recently Deleted')}><Icon name="trash"/>{t('Recently Deleted')}</button>
   <div className="sidebar-bottom"><div className="record-settings"><select aria-label={t('Recording mode')} disabled={!!recording} value={mode} onChange={e=>setMode(e.target.value)}><option value="both">{t('Microphone + System Audio')}</option><option value="micOnly">{t('Microphone Only')}</option><option value="systemOnly">{t('System Audio Only')}</option></select><select aria-label={t('Microphone')} disabled={!!recording} value={mic} onChange={e=>setMic(e.target.value)}><option value="">{t('Default microphone')}</option>{mics.map(m=><option key={m}>{m}</option>)}</select></div>
    <button className={section==='Settings'?'item active':'item'} onClick={()=>navigate('Settings')}><Icon name="settings"/>{t('Settings')}</button>
   </div>
  </aside>
  <main>
   <header className="topbar"><span className="toolbar-title">{section==='Documents'?listTitle:t(section)}</span><label className="search-field"><Icon name="search" size={14}/><input className="search" aria-label={t('Search')} placeholder={t('Search your notes')} value={search} onChange={e=>setSearch(e.target.value)}/>{search&&<button aria-label={t('Clear search')} onClick={()=>setSearch('')}><Icon name="close" size={12}/></button>}</label><button className="icon-button" title={t('New note')} aria-label={t('New note')} onClick={newNote}><Icon name="plus" size={18}/></button></header>
   {results!==null?<section className="page"><h1>{t('Search')}</h1>{!results.length&&<p>{t('No results')}</p>}{results.map((r,i)=><button key={i} className="search-result" onClick={()=>open(r.meeting_id,r.start)}><Icon name="document"/><div><strong>{r.title}</strong><span className="time">{timestamp(r.start)}</span><p>{r.text}</p></div></button>)}</section>
   :section==='Documents'?<div className="documents-layout">
    <aside className="document-list" aria-label={t('Documents')}><div className="list-heading"><strong>{listTitle}</strong><span className="count">{filtered.length}</span></div><div className="document-list-scroll">
     {filtered.map((m,i)=><div key={m.id}>{(!i||m.createdAt.slice(0,10)!==filtered[i-1].createdAt.slice(0,10))&&<div className="day-heading">{dateLabel(m.createdAt,language,false)}</div>}<button className={selected===m.id?'document-card selected':'document-card'} aria-pressed={selected===m.id} onClick={()=>open(m.id)}><h3>{m.status==='recording'&&<span className="recording-dot"/>}{m.folderId&&<Icon name="folder" size={12} style={{color:'var(--folder)'}}/>}{m.title}</h3><small>{dateLabel(m.createdAt,language,true,true)} · {timestamp(m.duration)}</small><p>{m.summary||statusLabel(m.status,language)}</p>{m.status!=='done'&&<span className="document-status">{statusLabel(m.status,language)}</span>}</button></div>)}
     {!filtered.length&&<div className="empty"><Icon name="document" size={30}/><h3>{t('No meetings yet')}</h3><p>{t('Record a call or import an audio file.')}</p></div>}
    </div></aside>
    {selected?<Document key={selected} id={selected} revision={revision} seek={seek} onOpen={open} onBack={()=>navigate('Home')} onError={setError}/>:<div className="empty"><Icon name="waveform" size={34}/><h3>{t('No document selected')}</h3><p>{t('Record a call or import an audio file.')}</p></div>}
   </div>
   :section==='Home'?<Home meetings={meetings} revision={revision} language={language} onOpen={open} onBrowse={()=>browse('')} onCalendar={()=>navigate('Calendar')} onRecord={toggle} onError={setError}/>
   :section==='Chat'?<Chat onOpen={open} onError={setError}/>
   :section==='Settings'?<Settings onError={setError} onLanguage={onLanguage}/>
   :section==='Calendar'?<Calendar onOpen={open} onError={setError}/>
   :<Organization section={section} revision={revision} onOpen={open} onError={setError}/>}
  </main>
 {editingFolder&&<div className="modal-backdrop"><section className="modal"><h2>{t(editingFolder.id?'Edit folder':'New folder')}</h2><label>{t('Name')}<input value={editingFolder.name} onChange={e=>setEditingFolder({...editingFolder,name:e.target.value})}/></label><label>{t('Parent folder')}<select value={editingFolder.parent_id??''} onChange={e=>setEditingFolder({...editingFolder,parent_id:e.target.value||null})}><option value="">{t('None')}</option>{folders.filter(f=>f.id!==editingFolder.id).map(f=><option key={f.id} value={f.id}>{f.name}</option>)}</select></label><label>{t('Color')}<select value={editingFolder.color} onChange={e=>setEditingFolder({...editingFolder,color:e.target.value})}>{['blue','green','orange','red','purple','pink','teal','gray'].map(c=><option key={c} value={c}>{t(c)}</option>)}</select></label><label>{t('Templates')}<select value={editingFolder.template_id??''} onChange={e=>setEditingFolder({...editingFolder,template_id:e.target.value||null})}><option value="">{t('Default template')}</option>{templates.map(v=><option key={v.id} value={v.id}>{v.name}</option>)}</select></label><label>{t('Shared context')}<textarea value={editingFolder.context} onChange={e=>setEditingFolder({...editingFolder,context:e.target.value})}/></label><div className="button-row"><button onClick={()=>setEditingFolder(null)}>{t('Cancel')}</button>{editingFolder.id&&<button onClick={()=>{if(confirm(t('Delete this folder and its subfolders? Notes will be kept without a folder.')))edit('folder.delete',editingFolder.id).then(()=>{setEditingFolder(null);browse('')}).catch(e=>setError(String(e)))}}>{t('Delete')}</button>}<button className="primary" disabled={!editingFolder.name.trim()} onClick={()=>edit('folder',editingFolder.id,editingFolder).then(()=>setEditingFolder(null)).catch(e=>setError(String(e)))}>{t('Save')}</button></div></section></div>}

 {error&&<div className="error-banner" role="alert"><span>{error}</span><button aria-label={t('Dismiss')} onClick={()=>setError('')}>×</button></div>}
 {callPrompt&&<div className="call-prompt"><strong>{callPrompt.active?'Call detected':'Call ended?'}</strong><p>{callPrompt.apps?.join(', ')}</p><button className="primary" onClick={()=>{setCallPrompt(null);if((callPrompt.active&&!recording)||(!callPrompt.active&&recording))toggle()}}>{t(callPrompt.active?'Record':'Stop')}</button><button onClick={()=>setCallPrompt(null)}>{t('Cancel')}</button></div>}
 </div>
}
