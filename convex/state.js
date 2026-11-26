import {internalMutation} from "./_generated/server";
import {v} from "convex/values";
import {execute} from "../server/document-engine.mjs";

export const apply=internalMutation({
  args:{command:v.string(),args:v.any()},
  handler:async(ctx,{command,args})=>{
    const byKey=(collection,key)=>ctx.db.query("entries").withIndex("by_key",q=>q.eq("collection",collection).eq("key",key)).unique();
    const repository={
      async get(collection,key){return (await byKey(collection,key))?.value ?? null;},
      async put(collection,key,scope,value){
        const existing=await byKey(collection,key);
        if(existing)await ctx.db.patch(existing._id,{scope,value});
        else await ctx.db.insert("entries",{collection,key,scope,value});
      },
      async remove(collection,key){const row=await byKey(collection,key);if(row)await ctx.db.delete(row._id);},
      async list(collection,scope,after="",limit=200){
        const rows=await ctx.db.query("entries").withIndex("by_scope",q=>q.eq("collection",collection).eq("scope",scope).gt("key",after)).take(limit);
        return rows.map(row=>row.value);
      }
    };
    return await execute(repository,command,args);
  }
});
