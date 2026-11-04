export default function Avatar({name,size=18}:{name:string;size?:number}) {
  const colors=['#d88337','#d65e59','#c46594','#986bb4','#5489c4','#4d9fa2','#729b59','#7678b5','#a47e63'];
  const hash=Array.from(name).reduce((n,c)=>((n*33)^c.codePointAt(0)!)>>>0,5381);
  const initials=name.trim().split(/\s+/).slice(0,2).map(s=>s[0]).join('').toUpperCase()||'?';
  return <span className="avatar" aria-hidden="true" style={{width:size,height:size,fontSize:Math.round(size*.4),background:colors[hash%colors.length]}}>{initials}</span>;
}
