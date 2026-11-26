import assert from 'node:assert/strict';
import {randomUUID,randomBytes,createHash} from 'node:crypto';

const base=process.env.PUBLIC_URL,owner=process.env.OWNER_TOKEN;
if(!base||!owner)throw Error('Set PUBLIC_URL and OWNER_TOKEN for the workspace to check.');
const id=process.env.VERIFY_CIRCUIT_PROJECT || randomUUID();
let paper=randomUUID(),page=randomUUID(),revision=1;
const route=(path,key,body)=>fetch(new URL(path,base),{method:body?'POST':'GET',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:body&&JSON.stringify(body)});
async function json(response){const data=await response.json();assert.ok(response.ok,JSON.stringify(data));return data;}
const grants=[];
async function revoke(client,token){
  const r=await fetch(base+'/revoke',{method:'POST',body:new URLSearchParams({client_id:client,token})});assert.equal(r.status,200);
}
async function authorize(client,redirect){
  const metadata=await json(await route('/register',null,{redirect_uris:[redirect],token_endpoint_auth_method:'none'}));
  client=metadata.client_id;
  const verifier=randomBytes(42).toString('base64url'),challenge=createHash('sha256').update(verifier).digest('base64url');
  const auth=new URL('/authorize',base);auth.search=new URLSearchParams({client_id:client,redirect_uri:redirect,response_type:'code',code_challenge:challenge,code_challenge_method:'S256',state:'connection-check',resource:base+'/mcp'});
  const consent=await fetch(auth,{method:'POST',headers:{Origin:base},body:new URLSearchParams({owner,project:id}),redirect:'manual'});
  assert.equal(consent.status,303);const cb=new URL(consent.headers.get('location'));assert.equal(cb.origin,new URL(redirect).origin);assert.equal(cb.searchParams.get('state'),'connection-check');
  const response=await fetch(base+'/token',{method:'POST',body:new URLSearchParams({grant_type:'authorization_code',client_id:client,redirect_uri:redirect,code:cb.searchParams.get('code'),code_verifier:verifier})});
  const token=(await json(response)).access_token;grants.push({client,token});return token;
}
const args=extra=>({project:id,request_id:randomUUID(),...extra});
const call=(token,name,a)=>route('/mcp',token,{id:1,jsonrpc:'2.0',method:'tools/call',params:{name,arguments:a}});
async function result(response){return JSON.parse((await json(response)).result.content[0].text);}
const act=(op,fields)=>route('/v1/action',owner,{op,args:args(fields)}).then(json);
if(process.env.VERIFY_CIRCUIT_PROJECT){
  const before=await act('read_space',{});
  assert.equal(before.project.title,'Circuit · connection check');
  const note=before.records.find(r=>r.kind==='note');page=note.id.slice(5);revision=note.rev;paper=before.records.find(r=>r.kind==='paper').id.slice(6);
}else{
await json(await route('/v1/projects',owner,{id,title:'Circuit · connection check'}));
await act('sync',{changes:[
  {id:'paper:'+paper,kind:'paper',base:0,body:{title:'Circuit check',type:'notebook',pages:[page]}},
  {id:'page:'+page,kind:'page',base:0,body:{id:page,paper,size:[768,1024],typed:'',inkText:'',pdfText:''}},
  {id:'note:'+page,kind:'note',base:0,body:{text:'The switch is open.'}}
]});
}
const anchor='goodestnotes://paper/'+paper+'/page/'+page;
const finalText=process.env.VERIFY_CIRCUIT_PROJECT?'The switch is closed. The filament is lit. Remote revision '+(revision+1)+'.':'The switch is closed. The filament is lit.';
try{
  const g=await authorize('chatgpt','https://chatgpt.com/connector_platform_oauth_redirect'),c=await authorize('claude','https://claude.ai/api/mcp/auth_callback');
  const request=args({text:'Automated MCP check. Close the switch on the linked page.',anchor});
  const post=await result(await call(g,'post_message',request));assert.equal(post.id,(await result(await call(g,'post_message',request))).id);
  await result(await call(c,'edit_note',args({record:'note:'+page,revision,text:finalText})));
  await result(await call(c,'post_message',args({reply:post.id,text:'Automated MCP check. The edit is saved.',anchor})));
  const thread=await result(await call(g,'read_conversation',{project:id})),space=await result(await call(g,'read_space',{project:id}));
  assert.deepEqual(thread.messages.slice(-2).map(m=>m.author),['ChatGPT','Claude']);assert.equal(thread.messages.at(-1).reply,post.id);
  assert.equal(space.records.find(r=>r.kind==='note').rev,revision+1);
  assert.equal((await route('/v1/settings',c,{main:'gpt-6.2-sol'})).status,403);
  const mark=await result(await call(g,'add_canvas_object',args({page,kind:'rectangle',title:'Canvas verification',x:100,y:180})));
  const edit=await result(await call(c,'edit_canvas_object',args({page,object:mark.id.slice(7),revision:mark.rev,kind:'rectangle',title:'Verified shared canvas edit',x:120,y:180})));
  assert.equal(edit.rev,2);
  const updated=await result(await call(g,'read_space',{project:id}));
  assert.equal(updated.records.find(r=>r.id===mark.id).body.item.title,'Verified shared canvas edit');
  await revoke(grants.find(x=>x.token===c).client,c);
  assert.equal((await call(c,'read_space',{project:id})).status,401);assert.equal((await call(g,'read_space',{project:id})).status,200);
  console.log(JSON.stringify({project:id,revision:revision+1,verified:['two OAuth grants','retry-safe page-linked messages','shared page edit','attributed canvas creation and revision','reply and readback','owner boundary','independent revocation']}));
}finally{
  for(const {client,token} of grants)await revoke(client,token);
}
