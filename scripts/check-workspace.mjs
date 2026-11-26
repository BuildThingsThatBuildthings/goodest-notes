import assert from 'node:assert/strict';
import {randomUUID,randomBytes,createHash} from 'node:crypto';

const base=process.env.PUBLIC_URL,owner=process.env.OWNER_TOKEN;
if(!base||!owner)throw Error('Set PUBLIC_URL and OWNER_TOKEN for the workspace to check.');
const id=randomUUID(),paper=randomUUID(),page=randomUUID();
const anchor='goodestnotes://paper/'+paper+'/page/'+page;
const route=(path,key,body)=>fetch(new URL(path,base),{method:body?'POST':'GET',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:body&&JSON.stringify(body)});
async function json(response){const data=await response.json();assert.ok(response.ok,JSON.stringify(data));return data;}
const grants=[];
async function authorize(client,redirect){
  const verifier=randomBytes(42).toString('base64url'),challenge=createHash('sha256').update(verifier).digest('base64url');
  const auth=new URL('/authorize',base);auth.search=new URLSearchParams({client_id:client,redirect_uri:redirect,response_type:'code',code_challenge:challenge,code_challenge_method:'S256',state:'connection-check',resource:base+'/mcp'});
  const consent=await fetch(auth,{method:'POST',headers:{Origin:base},body:new URLSearchParams({owner,project:id}),redirect:'manual'});
  assert.equal(consent.status,303);const cb=new URL(consent.headers.get('location'));assert.equal(cb.origin,new URL(redirect).origin);assert.equal(cb.searchParams.get('state'),'connection-check');
  const response=await fetch(base+'/token',{method:'POST',body:new URLSearchParams({grant_type:'authorization_code',client_id:client,redirect_uri:redirect,code:cb.searchParams.get('code'),code_verifier:verifier})});
  const token=(await json(response)).access_token;grants.push(client);return token;
}
const args=extra=>({project:id,request_id:randomUUID(),...extra});
const call=(token,name,a)=>route('/mcp',token,{id:1,jsonrpc:'2.0',method:'tools/call',params:{name,arguments:a}});
async function result(response){return JSON.parse((await json(response)).result.content[0].text);}
const act=(op,fields)=>route('/v1/action',owner,{op,args:args(fields)}).then(json);
await json(await route('/v1/projects',owner,{id,title:'Circuit · connection check'}));
await act('sync',{changes:[
  {id:'paper:'+paper,kind:'paper',base:0,body:{title:'Circuit check',type:'notebook',pages:[page]}},
  {id:'page:'+page,kind:'page',base:0,body:{id:page,paper,size:[768,1024],typed:'',inkText:'',pdfText:''}},
  {id:'note:'+page,kind:'note',base:0,body:{text:'The switch is open.'}}
]});
try{
  const g=await authorize('chatgpt','https://chatgpt.com/connector_platform_oauth_redirect'),c=await authorize('claude','https://claude.ai/api/mcp/auth_callback');
  const request=args({text:'Automated MCP check. Close the switch on the linked page.',anchor});
  const post=await result(await call(g,'post_message',request));assert.equal(post.id,(await result(await call(g,'post_message',request))).id);
  await result(await call(c,'edit_note',args({record:'note:'+page,revision:1,text:'The switch is closed. The filament is lit.'})));
  await result(await call(c,'post_message',args({reply:post.id,text:'Automated MCP check. The edit is saved.',anchor})));
  const thread=await result(await call(g,'read_conversation',{project:id})),space=await result(await call(g,'read_space',{project:id}));
  assert.deepEqual(thread.messages.map(m=>m.author),['ChatGPT','Claude']);assert.equal(thread.messages[1].reply,post.id);
  assert.equal(space.records.find(r=>r.kind==='note').rev,2);
  assert.equal((await route('/v1/settings',c,{main:'gpt-6.2-sol'})).status,403);
  const active=await json(await route('/v1/grants',owner));const grant=active.find(x=>x.project===id&&x.client==='claude');await json(await route('/v1/grants',owner,{id:grant.id}));
  assert.equal((await call(c,'read_space',{project:id})).status,401);assert.equal((await call(g,'read_space',{project:id})).status,200);
  console.log(JSON.stringify({project:id,revision:2,verified:['two OAuth grants','retry-safe page-linked messages','shared page edit','reply and readback','owner boundary','independent revocation']}));
}finally{
  const list=await json(await route('/v1/grants',owner));for(const g of list.filter(x=>x.project===id&&!x.revoked))await json(await route('/v1/grants',owner,{id:g.id}));
}
