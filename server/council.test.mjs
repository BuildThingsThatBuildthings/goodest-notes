import test from 'node:test';
import assert from 'node:assert/strict';
import {randomUUID} from 'node:crypto';
import {execute} from './document-engine.mjs';
import {runCouncil} from './council.mjs';

async function setup(){
  const rows=new Map(),key=(c,k)=>c+'/'+k;
  const db={get:async(c,k)=>structuredClone(rows.get(key(c,k))?.value),put:async(c,k,scope,v)=>rows.set(key(c,k),{c,k,scope,value:structuredClone(v)}),remove:async(c,k)=>rows.delete(key(c,k)),list:async(c,s,after='',n=200)=>[...rows.values()].filter(r=>r.c===c&&r.scope===s&&r.k>after).sort((a,b)=>a.k.localeCompare(b.k)).slice(0,n).map(r=>structuredClone(r.value))};
  const cmd=(c,a)=>execute(db,c,a),p=randomUUID(),page=randomUUID();
  await cmd('project',{id:p,title:'Test'});
  const act=(op,args)=>cmd('action',{who:{owner:true,name:'Human'},op,args:{project:p,request_id:randomUUID(),...args}});
  await act('sync',{changes:['page','note'].map(kind=>({id:kind+':'+page,kind,base:0,body:kind==='page'?{id:page}:{text:''}}))});
  const team=['gemini-4-neon','grok-4.7'];
  const task=await act('assign_task',{text:'Explain this sketch',agents:team,anchor:'goodestnotes://paper/'+randomUUID()+'/page/'+page});
  let queue=Promise.resolve();
  const save=e=>{queue=queue.then(()=>cmd('council',e));return queue;};
  return {act,id:task.id,read:()=>db.get('task',task.id),run:async generate=>{const j=await cmd('claim',{});assert.ok(j);await runCouncil(j,generate,save,randomUUID)}};
}
const proposal={message:'Label the switch.',object:{kind:'text',title:'Switch',x:10,y:20}};
const review={message:'Keep the contact visible.',ranking:['B','A']};
test('Convex council repeats once and stops unresolved work',async()=>{
  const f=await setup();let calls=0;
  for(let round=0;round<2;round++)for(const value of [proposal,review,{choice:'revise',labels:[],message:'Correct the hinge.'}])await f.run(async()=>{calls++;return JSON.stringify(value)});
  assert.equal(calls,10);assert.equal((await f.read()).state,'needs_review');
  await assert.rejects(f.act('control_task',{task:f.id,command:'resume'}));
});
test('malformed outputs are capped and resume preserves valid contributions',async()=>{
  const f=await setup();let calls=0;
  await f.run(async model=>{calls++;return model==='grok-4.7'?'bad':JSON.stringify(proposal)});
  assert.equal(calls,3);assert.equal((await f.read()).state,'paused');
  await f.act('control_task',{task:f.id,command:'resume'});
  await f.run(async()=>{throw Error('unexpected dispatch')});
  assert.equal((await f.read()).state,'needs_review');
});
test('Convex chair combines two ideas and commits one final mark',async()=>{
  const f=await setup();
  for(const value of [proposal,review,{...proposal,choice:'combine',labels:['A','B']}])await f.run(async()=>JSON.stringify(value));
  assert.equal((await f.read()).state,'completed');
  assert.equal((await f.act('read_space',{})).records.filter(r=>r.kind==='object').length,3);
});
