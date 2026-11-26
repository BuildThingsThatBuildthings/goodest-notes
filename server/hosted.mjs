// The same API and OAuth boundary can use the owner's Convex deployment.
// This credential belongs only to the API server. Clients never receive it.
export const hosted=()=>Boolean(process.env.CONVEX_STATE_URL);
export async function state(command,args={}){
  const url=process.env.CONVEX_STATE_URL,key=process.env.WORKSPACE_SERVICE_KEY;
  if(!url||!key)throw Object.assign(Error('Workspace storage configuration required'),{status:503});
  const response=await fetch(new URL('/workspace',url),{method:'POST',headers:{Authorization:'Bearer '+key,'Content-Type':'application/json'},body:JSON.stringify({command,args}),signal:AbortSignal.timeout(45000)});
  if(!response.ok){const data=await response.json().catch(()=>({}));throw Object.assign(Error(data.error||'Storage request failed'),{status:response.status});}
  return command==='load_media'?Buffer.from(await response.arrayBuffer()).toString('base64'):response.json();
}
