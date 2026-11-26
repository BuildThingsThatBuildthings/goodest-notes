import {canvasTeam,canvasMark,canvasSnapshot} from './canvas.mjs';
import {state} from './hosted.mjs';
import {randomUUID} from 'node:crypto';
import {digest,scope} from './auth.mjs';
import {canonicalJSON} from './json.mjs';
import {one,many,requireThat,string,uuid} from './db.mjs';
import {models,team,month,providers,monthlyLimit} from './models.mjs';

export async function accounts(c) {
  const rows=await many(c,'SELECT provider, COALESCE(sum(charged),0) spent, COALESCE(sum(reserved) FILTER (WHERE charged IS NULL),0) reserved FROM spend WHERE month=$1 GROUP BY provider',[month()]);
  return providers.map(provider=>{
    const row=rows.find(r=>r.provider===provider);
    const spent=Number(row?.spent||0), reserved=Number(row?.reserved||0);
    return {provider,spent:spent/1e6,reserved:reserved/1e6,remaining:(monthlyLimit(provider)-spent-reserved)/1e6};
  });
}

export async function replay(c,who,p,id,body,run) {
  const identity=who.grant||who.name, request=digest(canonicalJSON(body));
  await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[identity+p+id]);
  const previous=await one(c,'SELECT request,response FROM receipts WHERE actor=$1 AND project=$2 AND id=$3',[identity,p,id]);
  if(previous){
    const matches = previous.request === request || previous.request === digest(JSON.stringify(body));
    requireThat(matches,'Request ID used for different content',409);
    return previous.response;
  }
  const result=await run();
  await c.query('INSERT INTO receipts VALUES($1,$2,$3,$4,$5)',[identity,p,id,request,JSON.stringify(result)]);
  return result;
}

export async function edit(c,who,p,change) {
  const key=string(change.id,180), kind=string(change.kind,24), base=change.base;
  requireThat(Number.isSafeInteger(base) && base>=0,'Missing revision');
  requireThat(['note','paper','page','block','workflow','object','edge','asset'].includes(kind),'Unknown record type');
  requireThat(typeof change.body==='object' && change.body!==null && JSON.stringify(change.body).length<=400000,'Invalid record');
  if(!who.owner) {
    requireThat(kind==='note' && typeof change.body.text==='string' && change.body.text.length<=100000 && Object.keys(change.body).every(k=>k==='text'),'Agent can edit the text of a shared page',403);
  }
  await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',['record:'+key]);
  let current=await one(c,'SELECT * FROM records WHERE id=$1',[key]);
  if(!who.owner) requireThat(current && await one(c,'SELECT 1 FROM members WHERE project=$1 AND record=$2',[p,key]),'Unknown shared page',404);
  if(current) requireThat(current.kind===kind,'Record type mismatch',409);
  if(current && (await one(c,'SELECT body=$2::jsonb same FROM records WHERE id=$1',[key,JSON.stringify(change.body)])).same){
    if(who.owner) await c.query('INSERT INTO members VALUES($1,$2) ON CONFLICT DO NOTHING',[p,key]);
    return {id:key,rev:current.rev};
  }
  if((current?.rev||0)!==base){
    requireThat(current,'Record no longer exists',409);
    if(who.owner) await c.query('INSERT INTO members VALUES($1,$2) ON CONFLICT DO NOTHING',[p,key]);
    const conflict=randomUUID();
    await c.query('INSERT INTO conflicts(id,project,record,actor,proposed,base) VALUES($1,$2,$3,$4,$5,$6)',[conflict,p,key,who.name,JSON.stringify(change.body),base]);
    return {id:key,rev:current.rev,conflict};
  }
  const result=await one(c,'INSERT INTO records(id,kind,body) VALUES($1,$2,$3) ON CONFLICT(id) DO UPDATE SET body=EXCLUDED.body,rev=records.rev+1 RETURNING rev',[key,kind,JSON.stringify(change.body)]);
  await c.query('INSERT INTO members VALUES($1,$2) ON CONFLICT DO NOTHING',[p,key]);
  return {id:key,rev:result.rev};
}

export async function message(c,p,author,body,anchor=null,reply=null,task=null) {
  if(reply) requireThat(await one(c,'SELECT 1 FROM messages WHERE project=$1 AND id=$2',[p,uuid(reply)]),'Unknown reply');
  if(anchor) string(anchor,320);
  return one(c,'INSERT INTO messages(id,project,author,body,anchor,reply,task) VALUES($1,$2,$3,$4,$5,$6,$7) RETURNING *',[randomUUID(),p,author,string(body),anchor,reply,task]);
}
export async function action(c,who,op,args) {
  const p=uuid(args.project);scope(who,p);
  if(c.hosted){
    const data=await state('action',{who,op,args});
    if(op==='read_space')while(data.cursor){
      const page=await state('action',{who,op,args:{...args,cursor:data.cursor}});data.records.push(...page.records);data.cursor=page.cursor;
    }
    return data;
  }
  requireThat(await one(c,'SELECT 1 FROM projects WHERE id=$1',[p]),'Unknown project',404);
  if(op==='read_asset'){
    const row=await one(c,"SELECT r.body FROM members m JOIN records r ON r.id=m.record WHERE m.project=$1 AND r.id=$2 AND r.kind='asset'",[p,string(args.record,180)]);
    requireThat(row,'Unknown project attachment',404);const index=args.index;
    requireThat(Number.isSafeInteger(index)&&index>=0&&index<row.body.chunks.length,'Invalid chunk index');
    const hash=row.body.chunks[index],chunk=await one(c,'SELECT bytes FROM chunks WHERE hash=$1',[hash]);
    requireThat(chunk,'Missing attachment data',404);return {hash,data:chunk.bytes.toString('base64')};
  }
  if(op==='read_space') return {project:await one(c,'SELECT * FROM projects WHERE id=$1',[p]),records:await many(c,'SELECT r.* FROM members m JOIN records r ON r.id=m.record WHERE m.project=$1 ORDER BY r.id',[p]),conflicts:await many(c,'SELECT * FROM conflicts WHERE project=$1 ORDER BY created',[p])};
  if(op==='read_conversation') return {messages:await many(c,'SELECT * FROM messages WHERE project=$1 AND seq>$2 ORDER BY seq LIMIT 200',[p,Number(args.after)||0]),tasks:await many(c,'SELECT id,brief,anchor,state,stage,models FROM tasks WHERE project=$1 ORDER BY created DESC LIMIT 50',[p])};
  return replay(c,who,p,uuid(args.request_id),args,async()=>{
    if(op==='post_message') return message(c,p,who.name,args.text,args.anchor,args.reply);
    if(op==='add_canvas_object'||op==='edit_canvas_object'){
      const page=uuid(args.page);
      requireThat(await one(c,'SELECT 1 FROM members WHERE project=$1 AND record=$2',[p,'page:'+page]),'Unknown shared page',404);
      const updating=op==='edit_canvas_object',id=updating?uuid(args.object):randomUUID();
      const mark=canvasMark(page,id,who.name,args);
      if(updating){requireThat(await one(c,"SELECT 1 FROM records r JOIN members m ON m.record=r.id WHERE m.project=$1 AND r.id=$2 AND r.body->>'page'=$3",[p,mark.id,page]),'Unknown canvas object',404);mark.base=args.revision;}
      const result=await edit(c,{owner:true,name:who.name},p,mark);
      await message(c,p,who.name,(result.conflict?'Preserved conflicting edit':updating?'Updated':'Added')+' '+args.kind+' · '+args.title);
      return result;
    }
    if(op==='edit_note') return edit(c,who,p,{id:args.record,kind:'note',body:{text:args.text},base:args.revision});
    if(op==='sync') {
      requireThat(who.owner && Array.isArray(args.changes) && args.changes.length<=10000,'Invalid sync',403);
      const results=[]; for(const change of args.changes)results.push(await edit(c,who,p,change));
      if (Array.isArray(args.detach)) for(const key of args.detach) await c.query('DELETE FROM members WHERE project=$1 AND record=$2',[p,string(key,180)]);
      return {results};
    }
    if(op==='resolve_conflict') {
      requireThat(who.owner,'Owner required',403);
      const row=await one(c,'SELECT * FROM conflicts WHERE id=$1 AND project=$2 FOR UPDATE',[uuid(args.conflict),p]);
      requireThat(row,'Unknown conflict',404);
      if(args.accept){const r=await one(c,'SELECT kind,rev FROM records WHERE id=$1 FOR UPDATE',[row.record]); requireThat(r.rev===args.revision,'Refresh changes first',409); await edit(c,who,p,{id:row.record,kind:r.kind,base:r.rev,body:row.proposed});}
      await c.query('DELETE FROM conflicts WHERE id=$1',[row.id]); return {resolved:true};
    }
    if(op==='assign_task'){
      const id=randomUUID(), brief=string(args.text,16000), main=(await one(c,'SELECT main FROM settings WHERE id=1')).main;
      const state=who.owner?'queued':'awaiting_owner';
      const match=/^goodestnotes:\/\/paper\/[0-9a-f-]{36}\/page\/([0-9a-f-]{36})(?:\?|$)/i.exec(args.anchor || '');
      const target=match && await one(c,"SELECT r.id,r.rev FROM records r JOIN members m ON m.record=r.id WHERE m.project=$1 AND r.id=$2 AND r.kind='note'",[p,'note:'+match[1].toLowerCase()]);
      if(args.agents)requireThat(target&&await one(c,'SELECT 1 FROM members WHERE project=$1 AND record=$2',[p,'page:'+match[1].toLowerCase()]),'Select a shared page',400);
      await c.query('INSERT INTO tasks(id,project,brief,anchor,state,models,target,base,snapshot) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)',[id,p,brief,args.anchor||null,state,JSON.stringify(args.agents?canvasTeam(args.agents):team(main)),args.agents?'canvas:'+match[1].toLowerCase():target?.id,target?.rev,args.agents?canvasSnapshot(args.snapshot):null]);
      await message(c,p,who.name,brief,args.anchor,null,id);return {id,state};
    }
    if(op==='control_task'){
      requireThat(who.owner && ['pause','resume','cancel'].includes(args.command),'Owner task control required',403);
      const state={pause:'paused',resume:'queued',cancel:'cancelled'}[args.command];
      const task=await one(c,"UPDATE tasks SET state=$1 WHERE id=$2 AND project=$3 AND state NOT IN ('completed','cancelled') RETURNING id,state",[state,uuid(args.task),p]);
      requireThat(task,'Task is already closed',409);return task;
    }
    throw Object.assign(new Error('Unknown operation'),{status:404});
  });
}
