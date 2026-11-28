import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import pg from 'pg';
import {migrate,database,one,transaction} from './db.mjs';
import {handle} from './api.mjs';
import {digest} from './auth.mjs';
import {reserve,tick,callModel} from './worker.mjs';
import {team} from './models.mjs';

test('main-agent preferences preserve both providers',()=>{
  for(const model of ['claude-opus-5-5','gpt-6.2-sol']) {
    const roles=team(model);assert.equal(roles[0],model);
    assert.ok(roles.some(x=>x.startsWith('gpt-')));assert.ok(roles.some(x=>x.startsWith('claude-')));
    assert.notEqual(roles[2],roles[3]);
  }
});
test('shared workspace integration', {skip:!process.env.TEST_DATABASE_URL}, async t=>{
  const schema='qa_'+randomBytes(8).toString('hex');
  const admin=new pg.Client({connectionString:process.env.TEST_DATABASE_URL});await admin.connect();
  await admin.query('CREATE SCHEMA '+schema);
  const url=new URL(process.env.TEST_DATABASE_URL);url.searchParams.set('options','-c search_path='+schema);
  process.env.DATABASE_URL=url.href;process.env.OWNER_TOKEN=randomBytes(36).toString('hex');process.env.PUBLIC_URL='https://notebook.example';
  t.after(async()=>{await (await database()).end();await admin.query('DROP SCHEMA '+schema+' CASCADE');await admin.end();});
  await migrate();
  const owner=process.env.OWNER_TOKEN, project=randomUUID(), secondary=randomUUID(), sheet=randomUUID(), record='note:'+sheet;
  const req=(path,token,body)=>handle(new Request(process.env.PUBLIC_URL+path,{method:body?'POST':'GET',headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},body:body&&JSON.stringify(body)}));
  async function run(path,token,d){const r=await req(path,token,d);const j=await r.json();assert.ok(r.ok,JSON.stringify(j));return j;}
  const args=extra=>({project,request_id:randomUUID(),...extra});
  async function act(op,extra={}){return run('/v1/action',owner,{op,args:args(extra)});}
  for(const id of [project,secondary])await run('/v1/projects',owner,{id,title:'Example'});
  await act('sync',{changes:[{id:record,kind:'note',base:0,body:{text:'Open switch'}}]});
  await run('/v1/action',owner,{op:'sync',args:{project:secondary,request_id:randomUUID(),changes:[{id:record,kind:'note',base:0,body:{text:'Open switch'}}]}});
  async function grant(client,redirect){
    const verifier=randomBytes(36).toString('base64url');
    const base=process.env.PUBLIC_URL;
    const auth=new URL('/authorize',base);auth.search=new URLSearchParams({client_id:client,response_type:'code',redirect_uri:redirect,code_challenge_method:'S256',code_challenge:digest(verifier),state:'retain',resource:base+'/mcp'});
    const approved=await handle(new Request(auth,{method:'POST',headers:{Origin:base},body:new URLSearchParams({owner,project})}));
    assert.equal(approved.status,303);const returned=new URL(approved.headers.get('location'));assert.equal(returned.searchParams.get('state'),'retain');
    const exchange=await handle(new Request(base+'/token',{method:'POST',body:new URLSearchParams({client_id:client,code:returned.searchParams.get('code'),code_verifier:verifier,redirect_uri:redirect,grant_type:'authorization_code'})}));
    assert.equal(exchange.status,200);return (await exchange.json()).access_token;
  }
  const chat=await grant('chatgpt','https://chatgpt.com/connector_platform_oauth_redirect'), claude=await grant('claude','https://claude.ai/api/mcp/auth_callback');
  const call=(token,name,fields)=>req('/mcp',token,{id:1,jsonrpc:'2.0',method:'tools/call',params:{name,arguments:fields}});
  const result=async r=>JSON.parse((await r.json()).result.content[0].text);
  await t.test('two isolated clients share page-linked communication while the tablet is offline',async()=>{
    const post=args({text:'Close the switch',anchor:'goodestnotes://paper/'+randomUUID()+'/page/'+sheet});
    const a=await result(await call(chat,'post_message',post));
    const reordered=Object.fromEntries(Object.entries(post).reverse());
    const retry=await result(await call(chat,'post_message',reordered));assert.equal(a.id,retry.id);
    await result(await call(claude,'edit_note',args({record,revision:1,text:'Switch closed'})));
    await result(await call(claude,'post_message',args({reply:a.id,text:'Switch is now closed',anchor:a.anchor})));
    const history=await result(await call(chat,'read_conversation',{project}));
    assert.deepEqual(history.messages.map(m=>m.author),['ChatGPT','Claude']);assert.equal(history.messages[1].reply,a.id);
    assert.equal((await result(await call(chat,'read_space',{project}))).records[0].body.text,'Switch closed');
    assert.equal((await run('/v1/action',owner,{op:'read_space',args:{project:secondary}})).records[0].body.text,'Switch closed');
    assert.equal((await call(chat,'read_space',{project:secondary})).status,403);assert.equal((await req('/v1/settings',chat,{main:'gpt-6.2-sol'})).status,403);
  });
  await t.test('concurrent edits preserve both versions and retries do not duplicate conflicts',async()=>{
    const writes=['Left','Right'].map(text=>args({record,revision:2,text}));
    const results=await Promise.all(writes.map((a,i)=>call(i?claude:chat,'edit_note',a).then(result)));
    assert.equal(results.filter(r=>r.conflict).length,1);
    const i=results.findIndex(r=>r.conflict);await result(await call(i?claude:chat,'edit_note',writes[i]));
    const space=await act('read_space');assert.equal(space.conflicts.length,1);
    assert.deepEqual([space.records[0].body.text,space.conflicts[0].proposed.text].sort(),['Left','Right']);
    await act('resolve_conflict',{conflict:space.conflicts[0].id,accept:true,revision:3});
  });
  await t.test('four agents leave attributed page objects and handoffs and reject unrelated project edits',async()=>{
    await act('sync',{changes:[{id:'page:'+sheet,kind:'page',base:0,body:{id:sheet}}]});
    const all=['gemini-4-neon','grok-4.7','gpt-6.2-sol','claude-opus-5-5'];
    const anchor='goodestnotes://paper/'+randomUUID()+'/page/'+sheet;
    const task=await act('assign_task',{text:'Label the circuit',anchor,agents:all});
    const seen=[];
    for(let phase=0;phase<3;phase++)await tick(async (model,prompt)=>{
      seen.push(model);
      if(phase===0)return JSON.stringify({message:'Check contact',object:{kind:'text',title:'Contact',x:90,y:80}});
      if(phase===1){for(const name of all)assert.ok(!prompt.includes(name));return JSON.stringify({message:'B preserves the pivot.',ranking:['B','A','C','D']});}
      assert.ok(prompt.includes('B preserves the pivot.'));
      return JSON.stringify({choice:'adopt',labels:['B'],message:'Keep the pivot and its label.'});
    });
    assert.equal(seen.length,9);
    const space=await act('read_space'),objects=space.records.filter(r=>r.kind==='object');
    assert.deepEqual(objects.map(r=>r.body.author).sort(),[...all].sort());
    const conversation=await act('read_conversation');
    assert.equal(conversation.tasks.find(t=>t.id===task.id).state,'completed');
    assert.equal(conversation.messages.filter(m=>m.task===task.id&&all.includes(m.author)).length,9);
    const object=objects[0].body.item.id;
    const change=args({object,page:sheet,revision:1,kind:'text',title:'Switch',x:80,y:80});
    assert.equal((await result(await call(chat,'edit_canvas_object',change))).rev,2);
    assert.equal((await result(await call(chat,'edit_canvas_object',change))).rev,2);
    assert.ok((await result(await call(claude,'edit_canvas_object',{...change,title:'Wire',request_id:randomUUID()}))).conflict);
    assert.equal((await call(chat,'edit_canvas_object',{...change,project:secondary})).status,403);
    for(const provider of ['xai','google'])await assert.rejects(transaction(c=>reserve(c,provider,1)),{status:402});
  });
  await t.test('Neon and Grok send a sketch and meter a provider response',async t=>{
    const original={...process.env};
    const sample={png:'sample',rect:[0,0,320,320]};
    try{
      process.env.GOOGLE_MONTHLY_USD='1';process.env.XAI_MONTHLY_USD='1';
      process.env.GEMINI_API_KEY='test-only';process.env.XAI_API_KEY='test-only';
      const stub=t.mock.method(globalThis,'fetch',async(url,options)=>{
        const body=JSON.parse(options.body);
        if(String(url).includes('googleapis.com')){
          assert.equal(body.contents[0].parts[1].inlineData.data,sample.png);
          return Response.json({candidates:[{content:{parts:[{text:'Neon reply'}]}}],usageMetadata:{promptTokenCount:40,totalTokenCount:48}});
        }
        assert.equal(url,'https://api.x.ai/v1/responses');assert.equal(body.model,'grok-4.7');
        assert.equal(body.input[0].content[1].image_url,'data:image/png;base64,sample');
        return Response.json({output:[{content:[{text:'Grok reply'}]}],usage:{input_tokens:40,output_tokens:8}});
      });
      assert.equal(await callModel('gemini-4-neon','Label this',128,sample),'Neon reply');
      assert.equal(await callModel('grok-4.7','Check the label',128,sample),'Grok reply');
      assert.equal(stub.mock.callCount(),2);
      const accounts=(await run('/v1/settings',owner)).accounts;
      for(const provider of ['google','xai']){const a=accounts.find(x=>x.provider===provider);assert.ok(a.spent>0);assert.equal(a.reserved,0);}
    }finally{for(const key of ['GOOGLE_MONTHLY_USD','XAI_MONTHLY_USD','GEMINI_API_KEY','XAI_API_KEY']){if(original[key]===undefined)delete process.env[key];else process.env[key]=original[key];}}
  });
  await t.test('assignments snapshot model choices; only a human starts paid work',async()=>{
    const anchor='goodestnotes://paper/'+randomUUID()+'/page/'+sheet;
    const proposal=await result(await call(chat,'assign_task',args({text:'Explain closure',anchor})));
    assert.equal(proposal.state,'awaiting_owner');assert.equal(await tick(()=>assert.fail('unapproved dispatch')),false);
    await act('control_task',{task:proposal.id,command:'resume'});
    await run('/v1/settings',owner,{main:'gpt-6.2-sol'});
    const seen=[];
    for(let i=0;i<team('claude-opus-5-5').length;i++)await tick(async m=>{seen.push(m);return 'Reviewed circuit '+i});
    assert.deepEqual(seen,team('claude-opus-5-5'));assert.equal((await act('read_space')).records[0].body.text,'Reviewed circuit 4');
    await act('assign_task',{text:'New assignment'});const state=await act('read_conversation');assert.equal(state.tasks[0].models[0],'gpt-6.2-sol');
  });
  await t.test('two concurrent maximum reservations cannot exceed one provider budget',async()=>{
    const pair=await Promise.allSettled([1,2].map(()=>transaction(c=>reserve(c,'openai',50000000))));
    assert.equal(pair.filter(r=>r.status==='fulfilled').length,1);
    await transaction(c=>reserve(c,'anthropic',74000000));
    const d=await run('/v1/settings',owner);
    assert.equal(d.accounts.find(a=>a.provider==='openai').remaining,25);
    assert.equal(d.accounts.find(a=>a.provider==='anthropic').remaining,1);
  });
  await t.test('revocation takes effect on the next call and leaves the other client connected',async()=>{
    const grants=await run('/v1/grants',owner);await run('/v1/grants',owner,{id:grants.find(x=>x.client==='claude').id});
    assert.equal((await call(claude,'read_space',{project})).status,401);assert.equal((await call(chat,'read_space',{project})).status,200);
  });
});
