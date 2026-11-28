const el=id=>document.getElementById(id);
let playing=false, start=0, frame, key='', cursor=0, active='', generation=0;
function draw(ms){const t=((ms-start)%4200)/4200;const ease=x=>x*x*(3-2*x);const k=t<.18?0:t<.38?ease((t-.18)/.2):t<.86?1:1-ease((t-.86)/.14);el('switch').setAttribute('transform','rotate('+(-26*(1-k))+' 130 57)');const p=Math.max(0,Math.min(1,(t-.38)/.23));el('pulse').setAttribute('cx',190+96*Math.min(p/0.87,1));el('pulse').setAttribute('cy',57+15*Math.max(0,(p-.87)/.13));el('pulse').setAttribute('opacity',p>0&&p<1?'1':'0');el('bulb').setAttribute('fill',t>=.61&&t<.86?'#ffbd52':'#f5f3df');if(playing)frame=requestAnimationFrame(draw)}
el('motion').onclick=()=>{playing=!playing;cancelAnimationFrame(frame);start=performance.now();el('motion').textContent=playing?'Turn motion off':'Play circuit';el('motion').setAttribute('aria-pressed',String(playing));draw(start)};
async function api(path,body){const r=await fetch(path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:body&&JSON.stringify(body)});const d=await r.json();if(!r.ok)throw Error(d.error||'Request failed');return d}
function button(text,fn){const b=document.createElement('button');b.textContent=text;b.onclick=()=>run(fn);return b}
const run=async fn=>{try{await fn();}catch(e){el('status').textContent=e.message}};
const option=(v,t)=>new Option(t,v);
const money=n=>'$'+Number(n).toFixed(2);
function act(op,args={}){return api('/v1/action',{op,args:{project:el('projects').value,request_id:crypto.randomUUID(),...args}})}
async function settings(){const d=await api('/v1/settings');el('model').replaceChildren(...d.models.map(x=>option(x,x)));el('model').value=d.main;el('accounts').replaceChildren(...d.accounts.map(a=>{const li=document.createElement('li');li.textContent=a.provider+' · '+money(a.spent)+' spent · '+money(a.reserved)+' reserved · '+money(a.remaining)+' remaining';return li}));}
async function grants(){const g=await api('/v1/grants');el('grants').replaceChildren(...g.map(x=>{const d=document.createElement('p');d.append(x.client+' · '+x.project+' ');if(x.revoked)d.append('Revoked');else d.append(button('Revoke',async()=>{await api('/v1/grants',{id:x.id});await grants()}));return d}));}
function renderTasks(tasks,project){
  const rows=tasks.map(task=>{
    const row=document.createElement('p');
    row.append(task.brief+' · '+task.state+' ');
    const control=(label,command)=>button(label,async()=>{
      if(el('projects').value!==project)return;
      await act('control_task',{task:task.id,command});await read();
    });
    if(['paused','awaiting_owner'].includes(task.state))row.append(control(task.state==='awaiting_owner'?'Approve assignment':'Resume','resume'));
    if(task.state==='queued')row.append(control('Pause','pause'));
    if(['paused','awaiting_owner','queued'].includes(task.state))row.append(control('Cancel','cancel'));
    return row;
  });
  el('tasks').replaceChildren(...rows);
}
async function read(){const id=el('projects').value;if(!id)return;const turn=++generation;if(active!==id){active=id;cursor=0;el('messages').replaceChildren()}const d=await act('read_conversation',{after:cursor});if(turn!==generation)return;renderTasks(d.tasks,id);el('projectID').textContent='Project ID · '+id;for(const m of d.messages){cursor=m.seq;const p=document.createElement('p'),b=document.createElement('strong');b.textContent=m.author+' ';p.append(b,m.body);el('messages').append(p)}const s=await act('read_space');if(turn!==generation)return;el('conflicts').replaceChildren(...s.conflicts.map(x=>{const row=document.createElement('div'),a=s.records.find(r=>r.id===x.record);const pre=document.createElement('pre');pre.textContent='Current: '+JSON.stringify(a?.body)+'\nProposed by '+x.actor+': '+JSON.stringify(x.proposed);row.append(pre,...[true,false].map(accept=>button(accept?'Use proposed':'Keep current',async()=>{await act('resolve_conflict',{conflict:x.id,revision:a?.rev,accept});await read()})));return row}));}
el('login').onsubmit=e=>{e.preventDefault();run(async()=>{key=el('owner').value.trim();await settings();el('owner').value='';el('connect').hidden=true;el('workspace').hidden=false;const ps=await api('/v1/projects');el('projects').replaceChildren(...ps.map(p=>option(p.id,p.title)));el('status').textContent='Workspace connected';await grants();await read()})};
el('read').onclick=()=>run(read);el('projects').onchange=()=>run(read);el('logout').onclick=()=>location.reload();
el('save').onclick=()=>run(async()=>{await api('/v1/settings',{main:el('model').value});await settings();el('status').textContent='Main agent saved for future assignments.'});
el('check').onclick=()=>run(async()=>{const d=await api('/v1/providers');el('available').textContent=Object.entries(d).map(([p,c])=>p+' · '+(c.configured?c.models.join(', ')||'No verified model':'Key needed')).join('\n')});
for(const [id,op] of [['post','post_message'],['assign','assign_task']])el(id).onclick=()=>run(async()=>{const text=el('draft').value.trim();if(!text||!el('projects').value)return;await act(op,{text});el('draft').value='';await read()});setInterval(()=>{if(key&&!document.hidden&&active)run(read)},8000);
