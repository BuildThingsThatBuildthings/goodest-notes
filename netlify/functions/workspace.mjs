import {handle} from '../../server/api.mjs';
import {tick} from '../../server/worker.mjs';
async function runTeam(){
  for(let turn=0;turn<5;turn++){if(!await tick())break;}
}
export default (request,context)=>handle(request,{onQueued:()=>{
  if(context?.waitUntil)context.waitUntil(runTeam().catch(()=>console.error('Workspace worker interrupted')));
}});
export const config={path:['/health','/mcp','/authorize','/token','/revoke','/register','/.well-known/*','/v1/*']};
