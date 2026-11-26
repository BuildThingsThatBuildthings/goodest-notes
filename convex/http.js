import {httpRouter} from "convex/server";
import {httpAction} from "./_generated/server";
import {internal} from "./_generated/api";

const http=httpRouter();
http.route({path:"/workspace",method:"POST",handler:httpAction(async(ctx,req)=>{
  const secret=process.env.WORKSPACE_SERVICE_KEY;
  if(!secret||secret.length<32||req.headers.get("authorization")!=="Bearer "+secret)return new Response("Unauthorized",{status:401});
  try{
    const {command,args}=await req.json();
    if(command==="store_media"){const id=await ctx.storage.store(new Blob([Uint8Array.from(atob(args.data),x=>x.charCodeAt(0))]));return Response.json({id});}
    if(command==="load_media"){const blob=await ctx.storage.get(args.id);if(!blob)return new Response("Missing media",{status:404});return new Response(blob);}
    const result=await ctx.runMutation(internal.state.apply,{command,args});
    return Response.json(result);
  }catch(error){
    const known=/WORKSPACE_(\d{3}) (.{1,150})/.exec(String(error));
    return Response.json({error:known?known[2].split("\n")[0]:"Storage request failed"},{status:known?Number(known[1]):503});
  }
})});
export default http;
