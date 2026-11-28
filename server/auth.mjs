import {readText} from './request.mjs';
import {state as hostedState} from './hosted.mjs';
import { createHmac, createHash, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { one, many, requireThat, uuid } from './db.mjs';

export const digest = s => createHash('sha256').update(s).digest('base64url');
const secret = () => randomBytes(36).toString('base64url');
export function owner(token) {
  const key = process.env.OWNER_TOKEN;
  return typeof key === 'string' && key.length >= 32 && typeof token === 'string' && timingSafeEqual(Buffer.from(digest(token)),Buffer.from(digest(key)));
}
export const html = s => String(s).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
export const page = (title,content) => new Response('<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width, initial-scale=1"><title>'+html(title)+'</title><style>body{font:18px system-ui;color:#19273c;max-width:36rem;margin:12vh auto;padding:1.5rem}label{display:block;margin:1.3rem 0}input,button,select{font:inherit;padding:.6rem;max-width:100%}button{background:#263968;color:white;border:0;border-radius:.4rem}</style><h1>'+html(title)+'</h1>'+content,{headers:{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store','Referrer-Policy':'no-referrer','Content-Security-Policy':"default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'"}});
export function origin() { return new URL(process.env.PUBLIC_URL || 'http://127.0.0.1:8080').origin; }
const clientNames={chatgpt:'ChatGPT',claude:'Claude',gemini:'Gemini',grok:'Grok'};
function redirects(client) {
  if(client==='gemini'||client==='grok'){
    const uri=process.env[client.toUpperCase()+'_REDIRECT_URI'];
    if(!uri)return [];
    try{const u=new URL(uri);return u.protocol==='https:'&&!u.username&&!u.password&&!u.hash?[uri]:[];}catch{return [];}
  }
  if (client==='claude') return ['https://claude.ai/api/mcp/auth_callback','https://claude.com/api/mcp/auth_callback'];
  if (client==='chatgpt') return ['https://chatgpt.com/connector_platform_oauth_redirect',process.env.CHATGPT_REDIRECT_URI].filter(Boolean);
  return [];
}
function registered(client){
  if(Object.hasOwn(clientNames,client))return {family:client,uris:redirects(client)};
  if(typeof client!=='string'||client.length>3000||!process.env.OWNER_TOKEN)return null;
  const [payload,signature]=client.split('.');
  if(!payload||!signature)return null;
  const expected=createHmac('sha256',process.env.OWNER_TOKEN).update(payload).digest('base64url');
  if(signature.length!==expected.length||!timingSafeEqual(Buffer.from(digest(signature)),Buffer.from(digest(expected))))return null;
  try{return JSON.parse(Buffer.from(payload,'base64url').toString())}catch{return null}
}
export function clientLabel(client){return registered(client)?.family||client;}
export function register(metadata){
  const uris=metadata.redirect_uris;
  requireThat(Array.isArray(uris)&&uris.length>0&&uris.length<=4,'Registered callbacks required');
  const family=Object.keys(clientNames).find(client=>uris.every(uri=>typeof uri==='string'&&(redirects(client).includes(uri)||(client==='chatgpt'&&/^https:\/\/chatgpt\.com\/connector\/oauth\/[A-Za-z0-9_-]{1,160}$/.test(uri)))));
  requireThat(family&&(!metadata.token_endpoint_auth_method||metadata.token_endpoint_auth_method==='none'),'Public PKCE client with a supported callback required');
  requireThat(process.env.OWNER_TOKEN?.length>=32,'Workspace credential required',503);
  const details={family,uris,nonce:randomUUID()},payload=Buffer.from(JSON.stringify(details)).toString('base64url');
  const signature=createHmac('sha256',process.env.OWNER_TOKEN).update(payload).digest('base64url');
  return {client_id:payload+'.'+signature,client_id_issued_at:Math.floor(Date.now()/1000),redirect_uris:uris,token_endpoint_auth_method:'none',grant_types:['authorization_code','refresh_token'],response_types:['code']};
}
function authInput(p) {
  const client=p.get('client_id'), redirect=p.get('redirect_uri'), challenge=p.get('code_challenge');
  requireThat(registered(client)?.uris.includes(redirect),'Unregistered callback');
  requireThat(p.get('response_type')==='code' && p.get('code_challenge_method')==='S256' && /^[\w-]{43}$/.test(challenge || ''),'PKCE S256 required');
  requireThat(!p.get('resource') || p.get('resource')===origin()+'/mcp','Invalid resource');
  return {client,redirect,challenge};
}
export async function oauth(req,path,c) {
  const base=origin(), url=new URL(req.url);
  if(path.startsWith('/.well-known/oauth-protected-resource')) return {resource:base+'/mcp',authorization_servers:[base],scopes_supported:['workspace']};
  if(['/.well-known/oauth-authorization-server','/.well-known/oauth-authorization-server/mcp'].includes(path)) return {issuer:base,authorization_response_iss_parameter_supported:true,registration_endpoint:base+'/register',authorization_endpoint:base+'/authorize',token_endpoint:base+'/token',revocation_endpoint:base+'/revoke',response_types_supported:['code'],grant_types_supported:['authorization_code','refresh_token'],code_challenge_methods_supported:['S256'],token_endpoint_auth_methods_supported:['none'],scopes_supported:['workspace']};
  if(path==='/authorize') {
    const p=url.searchParams, {client,redirect,challenge}=authInput(p);
    if(req.method==='GET') return page('Connect Goodest Notes','<p>Give '+html(clientLabel(client))+' access to one project. Find its ID under Project conversation on the iPad.</p><form method="post"><label>Owner key <input name="owner" type="password" required></label><label>Project ID <input name="project" required></label><button>Connect '+html(clientLabel(client))+'</button></form>');
    requireThat(req.method==='POST' && req.headers.get('origin')===base,'Invalid submission',403);
    const form=new URLSearchParams(await readText(req,16384)); requireThat(owner(form.get('owner')),'Invalid owner key',401);
    const project=uuid(form.get('project')); requireThat(c.hosted?await hostedState('exists',{id:project}):await one(c,'SELECT id FROM projects WHERE id=$1',[project]),'Unknown project',404);
    const code=secret();
    if(c.hosted)await hostedState('code',{hash:digest(code),client,redirect,challenge,project});
    else await c.query("INSERT INTO codes VALUES ($1,$2,$3,$4,$5,now()+interval '3 minutes')",[digest(code),client,redirect,challenge,project]);
    const dest=new URL(redirect); dest.searchParams.set('code',code);dest.searchParams.set('iss',base); if(p.has('state')) dest.searchParams.set('state',p.get('state'));
    return new Response(null,{status:303,headers:{Location:dest.href,'Cache-Control':'no-store','Referrer-Policy':'no-referrer'}});
  }
  if(path==='/revoke'){
    requireThat(req.method==='POST','POST required',405);
    const form=new URLSearchParams(await readText(req,16384)),hash=digest(form.get('token')||''),client=form.get('client_id');
    if(c.hosted)await hostedState('revokeToken',{hash,client});
    else await c.query('UPDATE grants SET revoked=true WHERE client=$1 AND (access_hash=$2 OR refresh_hash=$2)',[client,hash]);
    return new Response(null,{status:200,headers:{'Cache-Control':'no-store'}});
  }
  if(path==='/token') {
    requireThat(req.method==='POST','POST required',405);
    const p=new URLSearchParams(await readText(req,16384)), client=p.get('client_id'), a=secret(), r=secret();
    requireThat(!p.get('resource')||p.get('resource')===base+'/mcp','Invalid resource');
    if(c.hosted){
      requireThat(['refresh_token','authorization_code'].includes(p.get('grant_type')),'Unknown grant');
      await hostedState('exchange',{client,access:digest(a),next:digest(r),...(p.get('grant_type')==='refresh_token'?{refresh:digest(p.get('refresh_token')||'')}:{code:digest(p.get('code')||''),verifier:digest(p.get('code_verifier')||''),redirect:p.get('redirect_uri')})});
    }else if(p.get('grant_type')==='refresh_token'){
      const row=await one(c,"UPDATE grants SET access_hash=$1,refresh_hash=$2,expires=now()+interval '1 hour' WHERE client=$3 AND refresh_hash=$4 AND NOT revoked AND refresh_expires>now() RETURNING id",[digest(a),digest(r),client,digest(p.get('refresh_token')||'')]);
      requireThat(row,'Invalid refresh grant',401);
    } else {
      requireThat(p.get('grant_type')==='authorization_code','Unknown grant');
      const code=await one(c,'DELETE FROM codes WHERE hash=$1 AND client=$2 AND redirect=$3 AND expires>now() AND challenge=$4 RETURNING project',[digest(p.get('code')||''),client,p.get('redirect_uri'),digest(p.get('code_verifier')||'')]);
      requireThat(code,'Invalid authorization grant',401);
      await c.query("INSERT INTO grants VALUES ($1,$2,$3,$4,$5,now()+interval '1 hour',now()+interval '90 days',false)",[randomUUID(),digest(a),digest(r),client,code.project]);
    }
    return {token_type:'Bearer',scope:'workspace',expires_in:3600,access_token:a,refresh_token:r};
  }
}
export async function actor(req,c) {
  const token=(req.headers.get('authorization')||'').replace(/^Bearer /i,'');
  if(owner(token)) return {name:'Human',owner:true};
  if(c.hosted){const a=await hostedState('actor',{hash:digest(token)});if(a.client){a.name=clientNames[clientLabel(a.client)]||'Agent';delete a.client;}return a;}
  const g=await one(c,'SELECT id,client,project FROM grants WHERE access_hash=$1 AND NOT revoked AND expires>now()',[digest(token)]);
  requireThat(g,'Connect your workspace',401);
  if(g.client==='ipad')return {name:'iPad',device:true,project:g.project,grant:g.id};
  return {name:clientNames[clientLabel(g.client)]||'Agent', project:g.project,grant:g.id};
}
export function scope(who,id) { requireThat(who.owner||who.project===id,'Project is outside this connection',403); }
