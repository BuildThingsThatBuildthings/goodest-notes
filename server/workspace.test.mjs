import test from 'node:test';
import assert from 'node:assert/strict';
import {randomBytes,randomUUID} from 'node:crypto';
import pg from 'pg';
import {migrate,database,one,transaction} from './db.mjs';
import {handle} from './api.mjs';
import {digest} from './auth.mjs';
import {reserve,tick} from './worker.mjs';
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
