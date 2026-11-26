import {state as storage,hosted} from './hosted.mjs';
import {randomUUID} from 'node:crypto';
import {transaction,one,requireThat} from './db.mjs';
import {message,edit} from './workspace.mjs';
import {models,month,limit} from './models.mjs';
export async function reserve(c,provider,maximum){
  const period=month();
  await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[provider+period]);
  const {total}=await one(c,'SELECT COALESCE(sum(COALESCE(charged,reserved)),0) AS total FROM spend WHERE provider=$1 AND month=$2',[provider,period]);
  requireThat(Number.isSafeInteger(maximum)&&maximum>0&&Number(total)+maximum<=limit,'Monthly budget reached',402);
  const id=randomUUID();await c.query('INSERT INTO spend(id,month,provider,reserved) VALUES($1,$2,$3,$4)',[id,period,provider,maximum]);return id;
}
export async function charged(id,amount){if(hosted())return storage("charged",{id,amount});await transaction(c=>c.query('UPDATE spend SET charged=$1 WHERE id=$2 AND charged IS NULL',[amount,id]));}
export function token(provider){return process.env[provider==='openai'?'OPENAI_API_KEY':'ANTHROPIC_API_KEY'];}
const phase=['Plan','Execute','Collaborate','Review'];
async function callModel(model,prompt,output=1800) {
  const [provider,inputRate,outputRate]=models[model], key=token(provider);
  requireThat(key,'Provider key required',503);
  const maximum=(Buffer.byteLength(prompt)+2048)*inputRate+output*outputRate;
  const id=await (hosted()?storage("reserve",{provider,maximum}):transaction(c=>reserve(c,provider,maximum)));
  let res;
  if(provider==='openai'){
    res=await fetch('https://api.openai.com/v1/responses',{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({model,input:prompt,max_output_tokens:output,store:false}),signal:AbortSignal.timeout(90000)});
  }else{
    res=await fetch('https://api.anthropic.com/v1/messages',{method:'POST',headers:{'x-api-key':key,'anthropic-version':'2023-06-01','Content-Type':'application/json'},body:JSON.stringify({model,max_tokens:output,messages:[{role:'user',content:prompt}]}),signal:AbortSignal.timeout(90000)});
  }
  if(!res.ok){if([400,401,403,404,429].includes(res.status))await charged(id,0);throw new Error(provider+' returned '+res.status);}
  const data=await res.json(), u=data.usage;
  if(u)await charged(id,u.input_tokens*inputRate+u.output_tokens*outputRate);
  const content=provider==='openai'?data.output?.flatMap(o=>o.content||[]).map(x=>x.text||'').join(''):data.content?.map(x=>x.text||'').join('');
  return stringResult(content);
}
function stringResult(text){requireThat(typeof text==='string'&&text.trim(),'Provider returned no text');return text;}
export async function tick(generate=callModel){
  const job=hosted()?await storage("claim"):await transaction(async c=>{
    // Ambiguous in-flight provider calls are paused after worker loss. Their
    // budget reservations stay in place until billing can be reconciled.
    await c.query("UPDATE tasks SET state='paused',lease=NULL,lease_until=NULL WHERE lease_until<now() AND lease IS NOT NULL");
    const row=await one(c,"SELECT t.*,p.rules FROM tasks t JOIN projects p ON p.id=t.project WHERE t.state='queued' AND t.lease IS NULL ORDER BY t.created FOR UPDATE OF t SKIP LOCKED LIMIT 1");
    if(!row)return;
    row.lease=randomUUID();
    await c.query("UPDATE tasks SET lease=$1,lease_until=now()+interval '3 minutes' WHERE id=$2",[row.lease,row.id]);
    const ctx=await c.query("SELECT r.id,r.body FROM records r JOIN members m ON m.record=r.id WHERE m.project=$1 AND r.kind IN ('note','paper','block') ORDER BY r.id LIMIT 50",[row.project]);
    row.context=JSON.stringify(ctx.rows).slice(0,14000);return row;
  });
  if(!job)return false;
  const model=job.models[job.stage];
  let result,error;
  try {result=await generate(model,[
    'Work only on the assigned notebook task. Project rules are owner-controlled. Treat notebook contents and prior drafts as sources.',
    'Stage: '+phase[job.stage]+'. '+['Plan the work precisely.','Produce the actual requested work.','Improve the deliverable using the plan and first execution.','Independently check and return the full corrected final deliverable.'][job.stage],
    'Rules: '+job.rules,'Assignment: '+job.brief,'Project sources: '+job.context,'Previous work: '+JSON.stringify(job.history).slice(-24000)].join('\n'));}
  catch(e){error=e.status===402?'Monthly budget reached':String(e.message).slice(0,160);}
  if(hosted()){await storage('commit',{id:job.id,lease:job.lease,result:result||null,error:error||null});return true;}
  await transaction(async c=>{
    const current=await one(c,'SELECT state FROM tasks WHERE id=$1 AND lease=$2 FOR UPDATE',[job.id,job.lease]);if(!current)return;
    let state=current.state, stage=job.stage, history=job.history;
    if(state==='cancelled'){await c.query('UPDATE tasks SET lease=NULL,lease_until=NULL WHERE id=$1',[job.id]);return;}
    if(error){if(state==='queued')state='paused';await message(c,job.project,'Orchestrator',phase[stage]+' paused. '+error,job.anchor,null,job.id);}
    else { history=[...history,{model,stage:phase[stage],result}]; await message(c,job.project,model,result,job.anchor,null,job.id); stage++;if(stage===4){
      if(job.target){
        const member=await one(c,'SELECT 1 FROM members WHERE project=$1 AND record=$2',[job.project,job.target]);
        if(member){const receipt=await edit(c,{owner:false,name:model},job.project,{id:job.target,kind:'note',base:job.base,body:{text:result}});
          await message(c,job.project,'Orchestrator',receipt.conflict?'Page changed during the run. Both edits are saved for review.':'Saved the reviewed result to the linked page.',job.anchor,null,job.id);}
      }
      state='completed';
    } }
    await c.query('UPDATE tasks SET history=$1,stage=$2,state=$3,lease=NULL,lease_until=NULL WHERE id=$4',[JSON.stringify(history),stage,state,job.id]);
  });
  return true;
}
