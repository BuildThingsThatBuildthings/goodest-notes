import {councilTeam,transition} from './council.mjs';
import {canvasTeam,canvasMark,canvasReply,canvasSnapshot} from './canvas.mjs';
import {models,team,providers,monthlyLimit,month} from './models.mjs';
import {canonicalJSON as canonical} from './json.mjs';

// Runs inside a single serializable database transaction. All client identities
// have already been authenticated by the HTTP service, and scope is checked here.
const check=(value,message,status=400)=>{if(!value)throw Error('WORKSPACE_'+status+' '+message);};
const identifier=v=>{check(typeof v==='string'&&/^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/i.test(v),'Invalid identifier');return v.toLowerCase()};
const text=(v,max=64000)=>{check(typeof v==='string'&&v.trim()&&v.length<=max,'Invalid text');return v;};
const uid=()=>'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g,ch=>(ch==='x'?Math.floor(Math.random()*16):8+Math.floor(Math.random()*4)).toString(16));
const seqKey=seq=>String(seq).padStart(16,'0');
async function ledger(db,provider,period=month()) {return await db.get('ledger',provider+period)||{provider,period,spent:0,reserved:0};}
async function bill(db,id,amount){
  const row=await db.get('reservation',id);check(row,'Unknown reservation',404);if(row.charged!=null)return;
  check(Number.isSafeInteger(amount)&&amount>=0,'Invalid metered charge');
  const balance=await ledger(db,row.provider,row.period);balance.spent+=amount;balance.reserved-=row.reserved;
  await db.put('ledger',row.provider+row.period,'',balance);await db.put('reservation',id,row.period,{...row,charged:amount});
}
async function reserve(db,provider,max){
  check(providers.includes(provider),'Unknown provider');const balance=await ledger(db,provider);
  check(Number.isSafeInteger(max)&&max>0&&balance.spent+balance.reserved+max<=monthlyLimit(provider),'Monthly budget reached',402);
  const id=uid();balance.reserved+=max;await db.put('ledger',provider+balance.period,'',balance);
  await db.put('reservation',id,balance.period,{id,provider,period:balance.period,reserved:max,charged:null});return id;
}
async function post(db,p,author,body,anchor=null,reply=null,task=null){
  if(reply)check((await db.get('messageID',reply))?.project===p,'Unknown reply');
  if(anchor)text(anchor,320);const counter=(await db.get('counter',p)||0)+1;await db.put('counter',p,'',counter);
  const item={id:uid(),seq:counter,project:p,author,body:text(body),anchor:anchor||null,reply:reply||null,task:task||null,created:new Date().toISOString()};
  await db.put('messageID',item.id,p,{project:p,seq:counter});await db.put('message',p+seqKey(counter),p,item);return item;
}
async function edit(db,who,p,c){
  const key=text(c.id,180),kind=text(c.kind,24),base=c.base,body=c.body;
  check(Number.isSafeInteger(base)&&base>=0&&body&&typeof body==='object'&&JSON.stringify(body).length<=400000,'Invalid record');
  check(['note','paper','page','block','workflow','object','edge','asset'].includes(kind),'Invalid kind');
  if(!who.owner){check(kind==='note'&&typeof body.text==='string'&&body.text.length<=100000&&Object.keys(body).length===1,'Page text edits only',403);check(await db.get('member',p+'/'+key),'Unknown shared page',404);}
  const cur=await db.get('record',key);check(!cur||cur.kind===kind,'Record kind changed',409);
  if(who.owner)await db.put('member',p+'/'+key,p,{id:key});
  if(cur&&canonical(body)===canonical(cur.body))return {id:key,rev:cur.rev};
  if((cur?.rev||0)!==base){
    check(cur,'Record removed',409);const id=uid();await db.put('conflict',id,p,{id,project:p,record:key,actor:who.name,proposed:body,base,created:new Date().toISOString()});
    return {id:key,rev:cur.rev,conflict:id};
  }
  const rev=base+1;await db.put('record',key,'',{id:key,kind,body,rev});return {id:key,rev};
}

async function action(db,who,op,args){
  const p=identifier(args.project);check(who.owner||who.project===p,'Project is outside this connection',403);
  const project=await db.get('project',p);check(project,'Unknown project',404);
  if(op==='read_conversation')return {messages:await db.list('message',p,p+seqKey(Number(args.after)||0),200),tasks:await db.list('taskIndex',p,'',50)};
  if(op==='read_space'){
    const members=await db.list('member',p,args.cursor||'',80);
    return {project,records:await Promise.all(members.map(m=>db.get('record',m.id))),cursor:members.length===80?p+'/'+members.at(-1).id:null,conflicts:await db.list('conflict',p,'',100)};
  }
  if(op==='read_asset'){
    const record=await db.get('record',text(args.record,180));check(record?.kind==='asset'&&await db.get('member',p+'/'+record.id),'Unknown attachment',404);
    const index=args.index;check(Number.isSafeInteger(index)&&index>=0&&index<record.body.chunks.length,'Invalid chunk index');
    const hash=record.body.chunks[index],data=await db.get('chunk',hash);check(data,'Missing attachment',404);return {hash,data};
  }
  const receipt=(who.grant||who.name)+'/'+p+'/'+identifier(args.request_id);
  const prior=await db.get('receipt',receipt);if(prior){check(canonical(prior.args)===canonical(args),'Request ID used for different content',409);return prior.result;}
  let result;
  if(op==='post_message')result=await post(db,p,who.name,args.text,args.anchor,args.reply);
  else if(op==='add_canvas_object'||op==='edit_canvas_object'){
    const page=identifier(args.page);check(await db.get('member',p+'/page:'+page),'Unknown shared page',404);
    const updating=op==='edit_canvas_object',id=updating?identifier(args.object):uid();
    const mark=canvasMark(page,id,who.name,args);
    if(updating){const existing=await db.get('record',mark.id);check(existing?.body.page===page&&await db.get('member',p+'/'+mark.id),'Unknown canvas object',404);mark.base=args.revision;}
    result=await edit(db,{owner:true,name:who.name},p,mark);
    await post(db,p,who.name,(result.conflict?'Preserved conflicting edit':updating?'Updated':'Added')+' '+args.kind+' · '+args.title);
  }
  else if(op==='edit_note')result=await edit(db,who,p,{id:args.record,kind:'note',base:args.revision,body:{text:args.text}});
  else if(op==='sync'){
    check(who.owner&&Array.isArray(args.changes)&&args.changes.length<=1000,'Owner sync required',403);
    const results=[];for(const c of args.changes)results.push(await edit(db,who,p,c));
    for(const key of args.detach||[])await db.remove('member',p+'/'+text(key,180));result={results};
  }else if(op==='resolve_conflict'){
    check(who.owner,'Owner required',403);const conflict=await db.get('conflict',identifier(args.conflict));check(conflict?.project===p,'Unknown conflict',404);
    if(args.accept){const row=await db.get('record',conflict.record);check(row.rev===args.revision,'Refresh edits first',409);await edit(db,who,p,{id:row.id,kind:row.kind,base:row.rev,body:conflict.proposed});}
    await db.remove('conflict',conflict.id);result={resolved:true};
  }else if(op==='assign_task'){
    const id=uid(),main=await db.get('setting','main')||'claude-opus-5-5',state=who.owner?'queued':'awaiting_owner',brief=text(args.text,16000);
    const match=/^goodestnotes:\/\/paper\/[a-f0-9-]{36}\/page\/([a-f0-9-]{36})(?:\?|$)/i.exec(args.anchor||'');
    const key=match?'note:'+match[1].toLowerCase():'',target=key&&await db.get('member',p+'/'+key)?await db.get('record',key):null;
    if(args.agents)check(target&&await db.get('member',p+'/page:'+match[1].toLowerCase()),'Select a shared page');
    const job={id,project:p,brief,models:args.agents?councilTeam(canvasTeam(args.agents),main):team(main),state,anchor:args.anchor||null,stage:0,history:[],lease:null,snapshot:args.agents?canvasSnapshot(args.snapshot):null,target:args.agents?'council:'+match[1].toLowerCase():target?.id||null,base:target?.rev||0,created:Date.now()};
    await saveJob(db,job);await post(db,p,who.name,brief,args.anchor,null,id);result={id,state};
  }else if(op==='control_task'){
    check(who.owner,'Owner required',403);const j=await db.get('task',identifier(args.task));check(j?.project===p,'Unknown task',404);check(!['completed','cancelled','needs_review'].includes(j.state),'Task already closed',409);
    const state={pause:'paused',resume:'queued',cancel:'cancelled'}[args.command];check(state,'Invalid command');j.state=state;await saveJob(db,j);result={id:j.id,state};
  }else check(false,'Unknown operation',404);
  await db.put('receipt',receipt,p,{args,result});return result;
}
async function saveJob(db,j){
  await db.put('task',j.id,j.state,j);
  const {id,brief,anchor,state,stage,models}=j;
  await db.put('taskIndex',j.project+'/'+seqKey(9999999999999999-j.created)+'/'+id,j.project,{id,brief,anchor,state,stage,models});
  if(j.lease)await db.put('leased',j.id,'',{id:j.id,until:j.until});else await db.remove('leased',j.id);
}
export async function execute(db,cmd,a){
  if(cmd==='health')return {connected:true};
  if(cmd==='project'){
    const id=identifier(a.id),p=await db.get('project',id);const row={...p,id,title:text(a.title,200),rules:p?.rules||'',catalog_id:a.externalID||p?.catalog_id||null};
    await db.put('project',id,'',row);return row;
  }
  if(cmd==='projects')return a.who.owner?db.list('project','','',1000):[await db.get('project',a.who.project)];
  if(cmd==='exists')return Boolean(await db.get('project',identifier(a.id)));
  if(cmd==='action')return action(db,a.who,a.op,a.args);
  if(cmd==='settings'){
    if(a.main){check(Object.hasOwn(models,a.main),'Unknown model');await db.put('setting','main','',a.main);}
    const accounts=await Promise.all(providers.map(async provider=>{const b=await ledger(db,provider);return {provider,spent:b.spent/1e6,reserved:b.reserved/1e6,remaining:(monthlyLimit(provider)-b.spent-b.reserved)/1e6}}));
    return {main:await db.get('setting','main')||'claude-opus-5-5',models:Object.keys(models),accounts};
  }
  if(cmd==='rules'){const p=await db.get('project',identifier(a.project));check(p&&typeof a.rules==='string'&&a.rules.length<=8000,'Invalid rules');p.rules=a.rules;await db.put('project',p.id,'',p);return p;}
  if(cmd==='chunkCheck'){check(Array.isArray(a.check)&&a.check.length<=10000,'Invalid chunk manifest');const missing=[];for(const hash of a.check)if(!await db.get('chunkHash',hash))missing.push(hash);return {missing};}
  if(cmd==='chunk'){await db.put('chunk',a.hash,'',a.data);await db.put('chunkHash',a.hash,'',true);return {hash:a.hash};}
  if(cmd==='code'){await db.put('code',a.hash,'',{...a,expires:Date.now()+180000});return true;}
  if(cmd==='exchange'){
    let grant;
    if(a.refresh){const index=await db.get('refresh',a.refresh);grant=index&&await db.get('grant',index);check(grant&&!grant.revoked&&grant.client===a.client&&grant.refresh===a.refresh&&grant.refreshExpires>Date.now(),'Invalid refresh grant',401);
      await db.remove('access',grant.access);await db.remove('refresh',grant.refresh);
    }else{const code=await db.get('code',a.code);check(code&&code.expires>Date.now()&&code.client===a.client&&code.redirect===a.redirect&&code.challenge===a.verifier,'Invalid authorization grant',401);await db.remove('code',a.code);
      grant={id:uid(),client:a.client,project:code.project,revoked:false,refreshExpires:Date.now()+90*86400000};
    }
    Object.assign(grant,{access:a.access,refresh:a.next,expires:Date.now()+3600000});
    await db.put('grant',grant.id,'',grant);await db.put('access',a.access,'',grant.id);await db.put('refresh',a.next,'',grant.id);return true;
  }
  if(cmd==='device'){
    const project=identifier(a.project);check(await db.get('project',project),'Unknown project',404);
    const id=uid(),g={id,access:a.hash,client:'ipad',project,revoked:false,expires:Date.now()+30*86400000};
    await db.put('grant',id,'',g);await db.put('access',a.hash,'',id);return {id};
  }
  if(cmd==='revokeToken'){
    const id=await db.get('access',a.hash)||await db.get('refresh',a.hash),g=id&&await db.get('grant',id);
    if(g&&g.client===a.client)await db.put('grant',id,'',{...g,revoked:true});return true;
  }
  if(cmd==='actor'){const i=await db.get('access',a.hash),g=i&&await db.get('grant',i);check(g&&!g.revoked&&g.expires>Date.now(),'Connect your workspace',401);if(g.client==='ipad')return {name:'iPad',device:true,project:g.project,grant:g.id};return {grant:g.id,project:g.project,client:g.client,name:g.client==='claude'?'Claude':'ChatGPT'};}
  if(cmd==='grants'){if(a.id){const g=await db.get('grant',identifier(a.id));check(g,'Unknown connection',404);await db.put('grant',g.id,'',{...g,revoked:true});}
    return (await db.list('grant','','',400)).map(({id,client,project,revoked})=>({id,client,project,revoked}));}
  if(cmd==='reserve')return reserve(db,a.provider,a.maximum);
  if(cmd==='charged'){await bill(db,a.id,a.amount);return true;}
  if(cmd==='claim'){
    for(const l of await db.list('leased','','',50)){if(l.until<Date.now()){const j=await db.get('task',l.id);j.lease=null;if(j.state==='queued')j.state='paused';await saveJob(db,j);}}
    const j=(await db.list('task','queued','',50)).find(j=>!j.lease);if(!j)return null;
    j.lease=uid();j.until=Date.now()+180000;await saveJob(db,j);
    if(j.target?.startsWith("canvas:"))await post(db,j.project,"Orchestrator",j.models[j.stage]+" started a canvas turn.",j.anchor,null,j.id);
    const p=await db.get('project',j.project),members=await db.list('member',j.project,'',80),context=[];
    for(const m of members.filter(m=>/^(note|paper|block|object|page):/.test(m.id)))context.push(await db.get('record',m.id));
    return {...j,rules:p.rules,context:JSON.stringify(context).slice(0,14000)};
  }
  if(cmd==='council'){
    const j=await db.get('task',a.id);if(!j||!j.target?.startsWith('council:'))return {ok:false};
    const result=transition(j,a),page=j.target.slice(8);
    if(result.object){
      check(await db.get('member',j.project+'/page:'+page),'Shared page removed',409);
      await edit(db,{owner:true},j.project,canvasMark(page,uid(),result.author,result.object));
    }
    if(result.message)await post(db,j.project,result.author||'Orchestrator',result.message,j.anchor,null,j.id);
    await saveJob(db,j);return {ok:result.ok};
  }
  if(cmd==='commit'){
    const j=await db.get('task',a.id);if(!j||j.lease!==a.lease)return false;j.lease=null;
    if(j.state==='cancelled'){await saveJob(db,j);return true;}
    if(a.error){if(j.state==='queued')j.state='paused';await post(db,j.project,'Orchestrator',a.error,j.anchor,null,j.id);}
    else {const model=j.models[j.stage];if(j.target?.startsWith('canvas:')){
      const page=j.target.slice(7);check(await db.get('member',j.project+'/page:'+page),'Shared page removed',409);
      const turn=canvasReply(a.result,page,uid(),model);await edit(db,{owner:true},j.project,turn.mark);a={...a,result:turn.message,object:turn.mark.body.item};
    }j.history.push({model,result:a.result,...(a.object?{object:a.object}:{})});await post(db,j.project,model,a.result,j.anchor,null,j.id);j.stage++;
      if(j.stage===j.models.length){j.state='completed';if(j.target&&!j.target.startsWith('canvas:')&&await db.get('member',j.project+'/'+j.target)){
        const r=await edit(db,{name:model},j.project,{id:j.target,kind:'note',base:j.base,body:{text:a.result}});await post(db,j.project,'Orchestrator',r.conflict?'Concurrent edit preserved for review.':'Saved the reviewed result to the linked page.',j.anchor,null,j.id);}
      }
    }await saveJob(db,j);return true;
  }
  if(cmd==='visualClaim'){
    const old=await db.get('visual',a.id);if(old){check(old.signature===a.signature,'Request ID already used',409);check(old.result,'Visual request pending reconciliation',409);return {result:old.result};}
    const reservation=await reserve(db,'openai',a.maximum);await db.put('visual',a.id,'',{signature:a.signature,reservation});return {reservation};
  }
  if(cmd==='visualDone'){const row=await db.get('visual',a.id);check(row,'Unknown visual',404);await db.put('visual',a.id,'',{...row,result:a.result});return true;}
  if(cmd==='visualReject'){const row=await db.get('visual',a.id);if(row){await bill(db,row.reservation,0);await db.remove('visual',a.id);}return true;}
  check(false,'Unknown storage command',404);
}
