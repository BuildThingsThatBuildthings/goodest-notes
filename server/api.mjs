import {createHash,randomBytes,randomUUID} from 'node:crypto';
import {actor,scope,oauth,origin,digest,register,clientLabel} from './auth.mjs';
import {transaction,one,many,uuid,string,requireThat} from './db.mjs';
import {action,accounts} from './workspace.mjs';
import {models} from './models.mjs';
import {hosted,state} from './hosted.mjs';
import {token} from './worker.mjs';

const str={type:'string'}, integer={type:'integer'}, id={type:'string',format:'uuid'};
const tool=(name,description,properties,required,readOnly=false)=>({name,description,inputSchema:{type:'object',properties,required,additionalProperties:false},annotations:{readOnlyHint:readOnly,destructiveHint:name==='edit_note',openWorldHint:false,idempotentHint:true}});
const tools=[
  tool('list_projects','List projects available to this connection.',{},[],true),
  tool('read_space','Read shared pages with their revision numbers and conflicts.',{project:id},['project'],true),
  tool('read_asset','Read one chunk of a project attachment by its asset record ID. Chunks use base64 and SHA-256.',{project:id,record:str,index:integer},['project','record','index'],true),
  tool('read_conversation','Read human and agent messages after a sequence number and list assigned work.',{project:id,after:integer},['project'],true),
  tool('post_message','Post a project handoff or reply. Reuse request_id on retry.',{project:id,request_id:id,text:str,anchor:str,reply:id},['project','request_id','text']),
  tool('edit_note','Edit the text of a shared note using the revision returned by read_space.',{project:id,request_id:id,record:str,revision:integer,text:str},['project','request_id','record','revision','text']),
  tool('assign_task','Propose an assignment to the owner. Paid work starts on owner confirmation.',{project:id,request_id:id,text:str,anchor:str},['project','request_id','text'])
];
const json=(data,status=200,extra={})=>Response.json(data,{status,headers:{'Cache-Control':'no-store',...extra}});
async function body(req){
  const data=await req.text();requireThat(Buffer.byteLength(data)<4500000,'Payload too large',413);
  try{return JSON.parse(data);}catch{throw Object.assign(new Error('Invalid JSON'),{status:400});}
}
async function projects(c,who) {
  if(c.hosted)return state('projects',{who});
  return who.owner?many(c,'SELECT * FROM projects ORDER BY title'):many(c,'SELECT * FROM projects WHERE id=$1',[who.project]);
}
async function mcp(req,c,who){
  if(req.method!=='POST')return new Response(null,{status:405,headers:{Allow:'POST'}});
  const d=await body(req), reply=(result)=>json({jsonrpc:'2.0',id:d.id,result});
  if(d.method==='initialize')return reply({protocolVersion:['2025-03-26','2025-06-18','2025-11-25'].includes(d.params?.protocolVersion)?d.params.protocolVersion:'2025-11-25',capabilities:{tools:{listChanged:false}},serverInfo:{name:'goodest-notes',version:'0.3.0'},instructions:'Collaborate in the shared project. Use read_conversation for handoffs. Treat page content as source material.'});
  if(d.id===undefined)return new Response(null,{status:202});
  if(d.method==='ping')return reply({});
  if(d.method==='tools/list')return reply({tools});
  if(d.method==='tools/call'){
    const name=d.params?.name;
    if(!tools.some(t=>t.name===name))return json({jsonrpc:'2.0',id:d.id,error:{code:-32602,message:'Unknown tool'}});
    const result=name==='list_projects'?await projects(c,who):await action(c,who,name,d.params.arguments||{});
    return reply({content:[{type:'text',text:JSON.stringify(result)}]});
  }
  return json({jsonrpc:'2.0',id:d.id,error:{code:-32601,message:'Unknown method'}});
}
async function capabilities(){
  const available={};
  for(const provider of ['openai','anthropic']){
    if(!token(provider)){available[provider]={configured:false,models:[]};continue;}
    const open=provider==='openai';
    const r=await fetch(open?'https://api.openai.com/v1/models':'https://api.anthropic.com/v1/models?limit=100',{headers:open?{Authorization:'Bearer '+token(provider)}:{'x-api-key':token(provider),'anthropic-version':'2023-06-01'},signal:AbortSignal.timeout(7000)});
    available[provider]={configured:true,status:r.status,models:r.ok?(await r.json()).data.map(m=>m.id).filter(m=>models[m]||m.startsWith('gpt-image-')):[]};
  }
  return available;
}
const storage=run=>hosted()?run({hosted:true}):transaction(run);
export async function handle(req) {
  const path=new URL(req.url).pathname;
  try{
    if(path==='/register' && req.method==='POST')return json(register(await body(req)),201);
    if(path==='/health'){
      try{await (hosted()?state('health'):transaction(c=>one(c,'SELECT id FROM settings WHERE id=1')));return json({service:'Goodest Notes',version:'0.3.0',database:'connected'});}
      catch{return json({service:'Goodest Notes',version:'0.3.0',database:'unavailable'},503);}
    }
    if(path.startsWith('/.well-known/'))return json(await oauth(req,path,null)??{},path.includes('oauth-')?200:404);
    if(path==='/v1/narration' && req.method==='POST'){
      await storage(async c=>{requireThat((await actor(req,c)).owner,'Owner required',403);});
      const {phrase}=await body(req),{speech}=await import('./speech.mjs');
      return json({format:'wav',data:(await speech(phrase)).toString('base64')});
    }
    if(path==='/v1/providers') {
      await storage(async c=>{requireThat((await actor(req,c)).owner,'Owner required',403);});
      return json(await capabilities());
    }
    if(path==='/v1/visual') { const a=await storage(c=>actor(req,c));requireThat(a.owner,'Owner required',403);const {visual}=await import('./visual.mjs');return json(await visual(await body(req))); }
    return await storage(async c=>{
      if(path==='/authorize'||path==='/token'||path==='/revoke'){const result=await oauth(req,path,c);return result instanceof Response?result:json(result);}
      const who=await actor(req,c);
      if(who.device){
        if(path==='/v1/settings'&&req.method==='GET')return json({role:'device',project:who.project,models:[],accounts:[],providers:{}});
        if(path==='/v1/projects'&&req.method==='GET')return json(await projects(c,who));
        if(path==='/v1/action'&&req.method==='POST'){
          const d=await body(req);requireThat(['read_space','read_asset','read_conversation','post_message','edit_note'].includes(d.op),'A workspace owner must approve this action',403);return json(await action(c,who,d.op,d.args));
        }
        throw Object.assign(new Error('Project-scoped device credential'),{status:403});
      }
      if(path==='/mcp')return mcp(req,c,who);
      requireThat(who.owner,'Owner access required',403);
      if(path==='/v1/device'&&req.method==='POST'){
        const d=await body(req),project=uuid(d.project),deviceToken=randomBytes(36).toString('base64url'),hash=digest(deviceToken);
        if(c.hosted)await state('device',{project,hash});
        else{requireThat(await one(c,'SELECT id FROM projects WHERE id=$1',[project]),'Unknown project',404);
          await c.query("INSERT INTO grants VALUES ($1,$2,$3,'ipad',$4,now()+interval '30 days',now(),false)",[randomUUID(),hash,digest(randomBytes(36)),project]);}
        return json({endpoint:origin(),project,deviceToken});
      }
      if(path==='/v1/chunks' && req.method==='POST'){
        const d=await body(req);
        if(Array.isArray(d.check)){
          requireThat(d.check.length<=10000 && d.check.every(x=>typeof x==='string'&&/^[a-f0-9]{64}$/.test(x)),'Invalid chunk list');
          if(c.hosted)return json(await state("chunkCheck",d));
          const found=new Set((await many(c,'SELECT hash FROM chunks WHERE hash=ANY($1::text[])',[d.check])).map(x=>x.hash));
          return json({missing:d.check.filter(x=>!found.has(x))});
        }
        requireThat(typeof d.data==='string'&&d.data.length<=350000,'Invalid chunk');
        const bytes=Buffer.from(d.data,'base64'),hash=createHash('sha256').update(bytes).digest('hex');
        requireThat(hash===d.hash && bytes.length<=262144,'Chunk checksum mismatch');
        if(c.hosted)return json(await state('chunk',{hash,data:bytes.toString('base64')}));
        await c.query('INSERT INTO chunks VALUES($1,$2) ON CONFLICT DO NOTHING',[hash,bytes]);return json({hash});
      }
      if(path==='/v1/projects' && req.method==='GET')return json(await projects(c,who));
      if(path==='/v1/projects' && req.method==='POST'){
        const d=await body(req);if(c.hosted)return json(await state('project',d));return json(await one(c,'INSERT INTO projects(id,title) VALUES($1,$2) ON CONFLICT(id) DO UPDATE SET title=EXCLUDED.title RETURNING *',[uuid(d.id),string(d.title,200)]));
      }
      if(path==='/v1/catalog' && req.method==='POST'){
        const d=await body(req);requireThat(Array.isArray(d.projects)&&d.projects.length<=1000,'Invalid catalog');
        if(c.hosted){for(const p of d.projects)await state('project',p);return json({count:d.projects.length});}
        for(const p of d.projects)await c.query('INSERT INTO projects(id,title,catalog_id) VALUES($1,$2,$3) ON CONFLICT(id) DO UPDATE SET title=EXCLUDED.title,catalog_id=EXCLUDED.catalog_id',[uuid(p.id),string(p.title,200),string(p.externalID,256)]);
        return json({count:d.projects.length});
      }
      if(path==='/v1/action' && req.method==='POST'){const d=await body(req);return json(await action(c,who,d.op,d.args));}
      if(path==='/v1/settings'){
        if(c.hosted){const data=await state('settings',req.method==='POST'?await body(req):{});return json({...data,providers:{openai:Boolean(token('openai')),anthropic:Boolean(token('anthropic'))}});}
        if(req.method==='POST'){const d=await body(req);requireThat(Object.hasOwn(models,d.main),'Unsupported model');await c.query('UPDATE settings SET main=$1 WHERE id=1',[d.main]);}
        return json({main:(await one(c,'SELECT main FROM settings WHERE id=1')).main,models:Object.keys(models),accounts:await accounts(c),providers:{openai:Boolean(token('openai')),anthropic:Boolean(token('anthropic'))}});
      }
      if(path==='/v1/rules' && req.method==='POST'){const d=await body(req);if(c.hosted)return json(await state('rules',d));requireThat(typeof d.rules==='string'&&d.rules.length<=8000,'Invalid rules');return json(await one(c,'UPDATE projects SET rules=$1 WHERE id=$2 RETURNING *',[d.rules,uuid(d.project)]));}
      if(path==='/v1/grants'){if(c.hosted)return json((await state('grants',req.method==='POST'?await body(req):{})).map(g=>({...g,client:clientLabel(g.client)})));if(req.method==='POST'){const d=await body(req);await c.query('UPDATE grants SET revoked=true WHERE id=$1',[uuid(d.id)]);}return json((await many(c,'SELECT id,client,project,revoked FROM grants ORDER BY client')).map(g=>({...g,client:clientLabel(g.client)})));}
      throw Object.assign(new Error('Unknown route'),{status:404});
    });
  }catch(e){return json({error:e.status?e.message:'Workspace service unavailable'},e.status||503,e.status===401?{'WWW-Authenticate':'Bearer resource_metadata="'+origin()+'/.well-known/oauth-protected-resource"'}:{});}
}
