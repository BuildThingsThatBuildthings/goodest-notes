import {state,hosted} from './hosted.mjs';
import {createHash} from 'node:crypto';
import {transaction,one,uuid,string,requireThat} from './db.mjs';
import {reserve,charged,token} from './worker.mjs';

const imageModel='gpt-image-2.6-flare';
const analysisModel='gpt-6.2-sol';
const artDirection='Preserve the hand-drawn subject. Keep the page still. Stage a readable initial pose, a clear point of contact, the result, and time to read it. Hold the hinge or planted part steady. Use one accent and a smooth return for a loop.';
export async function visual(input){
  const key=token('openai');
  requireThat(key,'Add your Goodest Notes OpenAI key to the workspace to use image generation or drawing analysis.',503);
  const {mode,reference}=input, request=uuid(input.request_id);
  requireThat(['analyze','image','gif'].includes(mode),'Unknown visual action');
  requireThat(typeof reference==='string' && reference.length<900000,'Reference must be a small PNG');
  const png=Buffer.from(reference,'base64');
  requireThat(png.length>24 && png.subarray(0,8).equals(Buffer.from([137,80,78,71,13,10,26,10])) && png.readUInt32BE(16)<=512 && png.readUInt32BE(20)<=512,'Reference must fit 512 × 512');
  const prompt=string(input.prompt,3000);
  const signature=createHash('sha256').update(mode).update(png).update(prompt).digest('hex');
  const frames=mode==='gif'?8:1;
  const maximum=mode==='analyze'?32768*2+320*10:32768*8 + frames*32768*30;
  const claim=hosted()?await state('visualClaim',{id:request,signature,maximum}):await transaction(async c=>{
    await c.query('SELECT pg_advisory_xact_lock(hashtextextended($1,0))',[request]);
    const old=await one(c,'SELECT * FROM visuals WHERE id=$1',[request]);
    if(old){requireThat(old.signature===signature,'Request ID used for a different visual',409);requireThat(old.result,'Previous request is pending or requires reconciliation',409);return {result:old.result};}
    // One bounded 512px input. Reserve 32k input tokens plus 32k output
    // tokens per requested image frame, above the small fixed canvas limits.
    const reservation=await reserve(c,'openai',maximum);
    await c.query('INSERT INTO visuals(id,signature,reservation) VALUES($1,$2,$3)',[request,signature,reservation]);
    return {reservation};
  });
  if(claim.result){
    if(claim.result.storage)return {format:claim.result.format,data:await state('load_media',{id:claim.result.storage})};
    return claim.result;
  }
  const headers={Authorization:'Bearer '+key};
  let response;
  if(mode==='analyze'){
    response=await fetch('https://api.openai.com/v1/responses',{method:'POST',headers:{...headers,'Content-Type':'application/json'},signal:AbortSignal.timeout(80000),body:JSON.stringify({model:analysisModel,store:false,max_output_tokens:320,input:[{role:'user',content:[{type:'input_text',text:'Interpret the teaching sketch. Return only JSON with text (one editable sentence naming the part, anchor, action and result), moving (array of supplied stroke IDs), motion (hinge or travel), amount (signed rotation degrees or relative horizontal travel in range -75..75), pivotAtEnd (boolean), wire and filament (optional stroke IDs for genuine circuits, otherwise null). Keep stationary parts fixed. '+prompt},{type:'input_image',image_url:'data:image/png;base64,'+reference,detail:'low'}]}]})});
  }else{
    const form=new FormData();
    for(const [name,value] of Object.entries({model:imageModel,prompt:artDirection+' '+prompt,size:'512x512',quality:'low',n:'1',output_format:mode==='gif'?'gif':'png'})) form.set(name,value);
    if(mode==='gif'){form.set('frame_count','8');form.set('frame_duration_ms','200');}
    form.set('image',new Blob([png],{type:'image/png'}),'drawing.png');
    response=await fetch('https://api.openai.com/v1/images/edits',{method:'POST',headers,body:form,signal:AbortSignal.timeout(115000)});
  }
  if(!response.ok){
    if([400,401,403,404,429].includes(response.status)) {
      if(hosted())await state('visualReject',{id:request});else await transaction(async c=>{await c.query('UPDATE spend SET charged=0 WHERE id=$1',[claim.reservation]);await c.query('DELETE FROM visuals WHERE id=$1',[request]);});
    }
    throw Object.assign(new Error('OpenAI '+mode+' returned '+response.status+'. Local ink rendering is available.'),{status:502});
  }
  const out=await response.json();
  let result=mode==='analyze'?{text:out.output?.flatMap(x=>x.content||[]).map(x=>x.text||'').join('').trim()}:{format:mode==='gif'?'gif':'png',data:out.data?.[0]?.b64_json};
  if(mode==='analyze' && result.text){
    try {const obj=JSON.parse(result.text.replace(/^```(?:json)?\s*|\s*```$/g,''));if(typeof obj.text==='string')result={text:obj.text,plan:obj};}catch{}
  }
  requireThat(result.text||result.data,'Provider returned no visual result',502);
  if(hosted()){
    const saved=result.data?{format:result.format,storage:(await state('store_media',{data:result.data})).id}:result;
    await state('visualDone',{id:request,result:saved});
  }else await transaction(c=>c.query('UPDATE visuals SET result=$1 WHERE id=$2',[JSON.stringify(result),request]));
  const u=out.usage;
  if(Number.isInteger(u?.input_tokens)&&Number.isInteger(u?.output_tokens)){
    const t=u.input_tokens_details?.text_tokens;
    const amount=mode==='analyze'?u.input_tokens*2+u.output_tokens*10:(Number.isInteger(t)?t:0)*5+(u.input_tokens-(Number.isInteger(t)?t:0))*8+u.output_tokens*30;
    await charged(claim.reservation,amount);
  }
  return result;
}
