// A canvas turn can write only an attributed object on its assigned page.
export function canvasTeam(selection) {
  const allowed=['claude-opus-5-5','gpt-6.2-sol','gemini-4-neon','grok-4.7'];
  if(!Array.isArray(selection)||!selection.length||selection.length>4||new Set(selection).size!==selection.length||!selection.every(id=>allowed.includes(id))) throw Object.assign(Error('Select one to four canvas agents'),{status:400});
  return selection;
}
export function canvasMark(page,id,author,fields) {
  const {kind,title,x,y}=fields;
  if(!['text','rectangle','ellipse','diamond','note'].includes(kind)||typeof title!=='string'||!title.trim()||title.length>300||![x,y].every(n=>Number.isFinite(n)&&Math.abs(n)<=100000)) throw Object.assign(Error('Invalid canvas object'),{status:400});
  return {id:'object:'+id,kind:'object',base:0,body:{page,author,item:{id,kind,title,markdown:'',frame:[[x,y],[200,76]],agentAuthor:author,tint:({'gemini-4-neon':'blue','grok-4.7':'slate','gpt-6.2-sol':'green','claude-opus-5-5':'orange'})[author]||'indigo'}}};
}
export function canvasReply(text,page,id,author) {
  const data=JSON.parse(text.replace(/^\s*```(?:json)?\s*|\s*```\s*$/g,''));
  if(typeof data.message!=='string'||!data.message.trim()||data.message.length>6000)throw Error('Agent returned an invalid handoff');
  return {message:data.message,mark:canvasMark(page,id,author,data.object||{})};
}

export function canvasSnapshot(value) {
  if(value==null)return null;
  if(typeof value.png!=='string'||value.png.length>350000||!value.png.startsWith('iVBORw0KGgo')||!Array.isArray(value.rect)||value.rect.length!==4||!value.rect.every(Number.isFinite)||value.rect[2]<=0||value.rect[3]<=0)throw Object.assign(Error('Invalid canvas preview'),{status:400});
  // Validate dimensions before sending an image to any model.
  const bytes=atob(value.png.slice(0,32));
  const size=offset=>[0,1,2,3].reduce((n,i)=>n*256+bytes.charCodeAt(offset+i),0);
  if(![size(16),size(20)].every(v=>v>=1&&v<=512))throw Object.assign(Error('Canvas preview must fit 512 pixels'),{status:400});
  return {png:value.png,rect:value.rect};
}
